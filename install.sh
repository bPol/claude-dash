#!/usr/bin/env bash
# Symlink the scripts into ~/.local/bin and print the config blocks to paste.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=${CLAUDE_DASH_BIN_DIR:-$HOME/.local/bin}

missing=()
for dep in jq foot swaymsg waybar flock; do
  command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if ((${#missing[@]})); then
  printf 'Missing dependencies: %s\n' "${missing[*]}" >&2
  printf 'Install them first, then re-run.\n' >&2
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
for script in claude-sessions claude-dash claude-dash-badge claude-dash-toggle; do
  ln -sfn "$HERE/bin/$script" "$BIN_DIR/$script"
  printf 'linked %s -> %s\n' "$BIN_DIR/$script" "$HERE/bin/$script"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\nWarning: %s is not on PATH.\n' "$BIN_DIR" >&2 ;;
esac

printf '\n--- add to ~/.config/sway/config ---\n\n'
cat "$HERE/config/sway.conf.snippet"

printf '\n--- add to ~/.config/waybar/config.jsonc ---\n'
printf '    (and add "custom/claude" to modules-right)\n\n'
sed "s|__BIN__|$BIN_DIR|g" "$HERE/config/waybar.module.jsonc"

printf '\n--- add to ~/.config/waybar/style.css ---\n\n'
cat "$HERE/config/waybar.style.css"

printf '\nThen: swaymsg reload\n'
