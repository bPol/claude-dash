# claude-dash

A waybar badge and a toggleable board showing every Claude Code session on this
machine — interactive terminal sessions as well as background agents. It can
also aggregate sessions from other machines over SSH, grouped and labelled by
host, without ever blocking the badge's 2-second poll on the network.

`claude agents` shows background agents only. This shows both.

## Install

```sh
git clone <this repo> ~/projects/claude-dash
cd ~/projects/claude-dash && ./install.sh
```

`install.sh` symlinks the six scripts into `~/.local/bin`, creates
`~/.config/claude-dash/hosts` (commented examples only, nothing enabled) if it
does not already exist, and prints the sway, waybar and CSS blocks to paste.
Then `swaymsg reload`.

## The six scripts

| Script | Job |
|---|---|
| `claude-sessions` | Reads the local registry, filters to live processes, prints normalized JSON. The only component that knows Claude Code's on-disk layout. |
| `claude-sessions-all` | The merged producer: local rows plus every remote host's cached rows, each labelled with `host`. What the badge and board read by default. |
| `claude-dash-fetch` | Refreshes the remote cache: one `ssh ... claude-sessions` per configured host, in parallel, written atomically. Never on the fast poll path. |
| `claude-dash-badge` | waybar `exec`: counts and alert class across every host; tooltip grouped by host. |
| `claude-dash` | The board. `--once` prints one frame and exits. Grouped by host, local block first. |
| `claude-dash-toggle` | waybar `on-click`: show or hide the scratchpad window. |

## Aggregating other machines

List remote hosts, one per line, in `~/.config/claude-dash/hosts`
(`host` or `user@host`; `#` comments and blank lines ignored):

```
# workstation
# deploy@10.0.0.5
```

Each listed remote needs:

- **claude-dash installed** there too, so `claude-sessions` is on its `PATH`
  (run `install.sh` there as well, or symlink just that one script).
- **key-based SSH** from this machine, with no passphrase prompt — fetches run
  with `ssh -o BatchMode=yes`, so anything that would prompt just fails and is
  reported as `auth failed` instead.

With hosts configured, `claude-sessions-all` notices when its cache is older
than `CLAUDE_DASH_FETCH_EVERY` seconds and spawns `claude-dash-fetch` fully
detached to refresh it, then immediately returns whatever is already cached —
the 2-second poll never waits on SSH. Run `claude-dash-fetch` by hand (or
`claude-dash-fetch --host <entry>` for just one) to force an immediate
refresh, e.g. right after editing the hosts file.

Each host in the board/badge output carries a status:

| Status | Meaning |
|---|---|
| `fresh` | Cached within `CLAUDE_DASH_STALE_AFTER` seconds (default 45s). Local is always `fresh`. |
| `stale` | The cache is older than that, but its rows still show — the last thing that host reported. |
| `unreachable` | The last fetch failed (unreachable, `auth failed`, `timeout`, or `remote command missing`). Its heading shows the error; its rows still show the last successful payload, if there ever was one. |

With no hosts file and no remote cache, `claude-sessions-all` degrades
transparently to plain `claude-sessions` output plus a `host` field and a
one-entry `hosts` array — a single-machine setup is unchanged.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_DASH_ROOT` | `~/.claude` | Registry root. Point it at a fixture tree to test. |
| `CLAUDE_DASH_PRODUCER` | sibling `claude-sessions-all` | Data source for the badge and board. |
| `CLAUDE_DASH_LOCAL_PRODUCER` | sibling `claude-sessions` | Local data source used by `claude-sessions-all`. |
| `CLAUDE_DASH_INTERVAL` | `2` | Board refresh seconds while visible. |
| `CLAUDE_DASH_IDLE_INTERVAL` | `60` | Board refresh seconds while hidden in the scratchpad. |
| `CLAUDE_DASH_CLI` | `claude` | Binary used for the degraded-mode fallback. |
| `CLAUDE_DASH_ARBITRATE_EVERY` | `60` | Minimum seconds between fallback cross-checks. |
| `CLAUDE_DASH_PIDFILE` | `$XDG_RUNTIME_DIR/claude-dash.pid` | How the toggle finds the running board to signal it. The board and the toggle must agree on this, or hiding the board stops slowing it down. |
| `CLAUDE_DASH_STAMP` | `$XDG_RUNTIME_DIR/claude-dash-arbitrated` | Rate-limit stamp for the fallback cross-check. |
| `CLAUDE_DASH_BOARD` | `claude-dash` | Board command the toggle launches. |
| `CLAUDE_DASH_HOST` | `uname -n` | Overrides the hostname shown in the header and tooltip. |
| `CLAUDE_DASH_BIN_DIR` | `~/.local/bin` | Where `install.sh` symlinks the scripts. |
| `CLAUDE_DASH_HOSTS` | `~/.config/claude-dash/hosts` | The remote host list `claude-dash-fetch` reads. |
| `CLAUDE_DASH_CACHE` | `${XDG_CACHE_HOME:-~/.cache}/claude-dash` | Where `claude-dash-fetch` writes one `<host>.json` per remote, and where `claude-sessions-all` reads them from. |
| `CLAUDE_DASH_STALE_AFTER` | `45` | Seconds before a fresh remote cache is shown as stale. |
| `CLAUDE_DASH_FETCH_EVERY` | `20` | Minimum seconds between `claude-sessions-all` spawning a background refresh. |
| `CLAUDE_DASH_FETCH` | sibling `claude-dash-fetch` | Fetch binary `claude-sessions-all` spawns. |
| `CLAUDE_DASH_FETCH_STAMP` | `$CLAUDE_DASH_CACHE/.fetch-trigger-stamp` | Rate-limit stamp for the background fetch spawn. |
| `CLAUDE_DASH_FETCH_CONNECT_TIMEOUT` | `5` | ssh `ConnectTimeout` per host. |
| `CLAUDE_DASH_FETCH_TIMEOUT` | `10` | Overall wall-clock timeout per host fetch (connect + remote command). |
| `CLAUDE_DASH_SSH` | `ssh` | ssh binary `claude-dash-fetch` calls. Override with a stub to test. |

## Tests

```sh
./tests/run.sh          # 183 checks, no sway, network or Claude Code session required
shellcheck -x bin/* install.sh tests/*.sh
```

## A caveat worth knowing

The fast path reads `~/.claude/sessions/*.json` and `~/.claude/jobs/*/state.json`
directly. That is Claude Code's internal layout with no compatibility promise,
chosen because `claude agents --json` costs ~0.5 s and ~300 MB per call, which is
not something to run every 2 seconds. If the layout ever changes, the tools fall
back to `claude agents --json` and the board header shows
`⚠ degraded (CLI fallback)` so you know why it got slower.

## Known follow-ups

Small things the final review flagged and we chose not to block on:

- The board's truncation ellipsis covers session rows but not the header or the
  collapsed "N finished" footer, which are still hard-cut at very narrow widths.
- The toggle closes fd 9 so the launch lock is not held for the board's lifetime,
  but there is no test that would catch it if that were removed.
