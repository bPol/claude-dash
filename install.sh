#!/usr/bin/env bash
# Symlink the scripts into ~/.local/bin and print the config blocks to paste.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=${CLAUDE_DASH_BIN_DIR:-$HOME/.local/bin}

# A producer-only (--remote) install is for a headless machine that only
# contributes its own sessions to some other, controlling machine's board --
# it needs neither sway nor waybar nor foot, just enough to run
# claude-sessions and be reachable over ssh.
producer_only=false
case "${1:-}" in
  --producer-only | --remote) producer_only=true ;;
esac

desktop_deps=(foot swaymsg waybar)
if $producer_only; then
  deps=(bash jq)
else
  deps=(jq flock "${desktop_deps[@]}")
fi

missing=()
for dep in "${deps[@]}"; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if ((${#missing[@]})); then
  printf 'Missing dependencies: %s\n' "${missing[*]}" >&2
  printf 'Install them first, then re-run.\n' >&2
  if ! $producer_only; then
    for dep in "${desktop_deps[@]}"; do
      for m in "${missing[@]}"; do
        if [[ $m == "$dep" ]]; then
          printf '\nIf this machine only contributes sessions and has no desktop, re-run with --producer-only (or --remote) instead -- it only needs bash and jq.\n' >&2
          break 2
        fi
      done
    done
  fi
  exit 1
fi

claude_count=$(type -a -P claude 2>/dev/null | sort -u | wc -l)
if ((claude_count > 1)); then
  # shellcheck disable=SC2016 # single-quoted on purpose: literal backticks, not command substitution
  printf 'Warning: %s different `claude` binaries on PATH:\n' "$claude_count" >&2
  type -a -P claude | sort -u | sed 's/^/  /' >&2
  printf 'The degraded-mode fallback will use the first one.\n\n' >&2
fi

mkdir -p "$BIN_DIR"
if $producer_only; then
  scripts=(claude-sessions)
else
  scripts=(claude-sessions claude-sessions-all claude-dash-fetch
           claude-dash claude-dash-badge claude-dash-toggle)
fi
for script in "${scripts[@]}"; do
  ln -sfn "$HERE/bin/$script" "$BIN_DIR/$script"
  printf 'linked %s -> %s\n' "$BIN_DIR/$script" "$HERE/bin/$script"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\nWarning: %s is not on PATH.\n' "$BIN_DIR" >&2 ;;
esac

if $producer_only; then
  # No hosts file, no sway/waybar/CSS here -- this machine is a producer,
  # not the one doing the aggregating. It just needs to be reachable and
  # named on the CONTROLLING machine's hosts file.
  printf '\nOn the controlling machine, add this line to ~/.config/claude-dash/hosts\n'
  printf 'to pull sessions from this host:\n\n'
  printf '  %s\n' "$(uname -n)"
  printf '\n(see claude-dash-fetch and the README for the "host=remote_cmd" syntax\n'
  printf 'if claude-sessions is not at the default ~/.local/bin/claude-sessions there.)\n'
  exit 0
fi

# The hosts file is how claude-dash-fetch knows what to aggregate. Scaffold
# it with commented examples only -- never guess a real hostname -- so a
# fresh install has somewhere to add remotes without hand-creating the
# directory first, and a re-run never overwrites a file already in use.
HOSTS_FILE=${CLAUDE_DASH_HOSTS:-$HOME/.config/claude-dash/hosts}
if [[ ! -f $HOSTS_FILE ]]; then
  mkdir -p "$(dirname "$HOSTS_FILE")"
  cat >"$HOSTS_FILE" <<'EOF'
# claude-dash remote hosts, one per line: "host" or "user@host", optionally
# with "=<remote_cmd>" appended (see below).
# Lines starting with # and blank lines are ignored.
#
# Each remote needs claude-sessions installed (`./install.sh --producer-only`
# there is enough -- no desktop required) and key-based SSH from this machine
# (no password prompt -- fetches run with BatchMode=yes and will just fail
# otherwise).
#
# claude-dash-fetch runs an explicit remote command, not a bare
# `claude-sessions`, because a non-interactive SSH session's PATH is minimal
# and usually does not include ~/.local/bin. The default it runs is:
#   ~/.local/bin/claude-sessions
# Override it for every host with $CLAUDE_DASH_REMOTE_CMD, or for one host
# only by appending "=<remote_cmd>" to that host's line here, e.g.:
# deploy@10.0.0.5=/opt/claude-dash/bin/claude-sessions
#
# Examples:
# workstation
# deploy@10.0.0.5
EOF
  printf 'created %s\n' "$HOSTS_FILE"
fi

printf '\n--- add to ~/.config/sway/config ---\n\n'
cat "$HERE/config/sway.conf.snippet"

printf '\n--- add to ~/.config/waybar/config.jsonc ---\n'
printf '    (and add "custom/claude" to modules-right)\n\n'
sed "s|__BIN__|$BIN_DIR|g" "$HERE/config/waybar.module.jsonc"

printf '\n--- add to ~/.config/waybar/style.css ---\n\n'
cat "$HERE/config/waybar.style.css"

printf '\nThen: swaymsg reload\n'
