# claude-dash

A waybar badge and a toggleable board showing every Claude Code session on this
machine — interactive terminal sessions as well as background agents.

`claude agents` shows background agents only. This shows both.

## Install

```sh
git clone <this repo> ~/projects/claude-dash
cd ~/projects/claude-dash && ./install.sh
```

`install.sh` symlinks the four scripts into `~/.local/bin` and prints the sway,
waybar and CSS blocks to paste. Then `swaymsg reload`.

## The four scripts

| Script | Job |
|---|---|
| `claude-sessions` | Reads the registry, filters to live processes, prints normalized JSON. The only component that knows Claude Code's on-disk layout. |
| `claude-dash-badge` | waybar `exec`: counts, tooltip, alert class. |
| `claude-dash` | The board. `--once` prints one frame and exits. |
| `claude-dash-toggle` | waybar `on-click`: show or hide the scratchpad window. |

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_DASH_ROOT` | `~/.claude` | Registry root. Point it at a fixture tree to test. |
| `CLAUDE_DASH_PRODUCER` | sibling `claude-sessions` | Data source for the badge and board. |
| `CLAUDE_DASH_INTERVAL` | `2` | Board refresh seconds while visible. |
| `CLAUDE_DASH_IDLE_INTERVAL` | `60` | Board refresh seconds while hidden in the scratchpad. |
| `CLAUDE_DASH_CLI` | `claude` | Binary used for the degraded-mode fallback. |
| `CLAUDE_DASH_ARBITRATE_EVERY` | `60` | Minimum seconds between fallback cross-checks. |
| `CLAUDE_DASH_PIDFILE` | `$XDG_RUNTIME_DIR/claude-dash.pid` | How the toggle finds the running board to signal it. The board and the toggle must agree on this, or hiding the board stops slowing it down. |
| `CLAUDE_DASH_STAMP` | `$XDG_RUNTIME_DIR/claude-dash-arbitrated` | Rate-limit stamp for the fallback cross-check. |
| `CLAUDE_DASH_BOARD` | `claude-dash` | Board command the toggle launches. |
| `CLAUDE_DASH_HOST` | `uname -n` | Overrides the hostname shown in the header and tooltip. |
| `CLAUDE_DASH_BIN_DIR` | `~/.local/bin` | Where `install.sh` symlinks the scripts. |

## Tests

```sh
./tests/run.sh          # 74 checks, no sway or Claude Code session required
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
