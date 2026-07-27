# claude-dash

A waybar badge and a toggleable sway board showing **every** Claude Code session
you have running — interactive terminal sessions and background agents alike,
across as many machines as you like.

## Why

`claude agents` lists background agents only. Open it while four interactive
sessions are running and it shows an empty board, which reads as *nothing is
happening*. Worse, a background agent that is **blocked waiting for your answer**
has usually already exited its process, so it lives only as a job record — and
sits there, unanswered, for days.

claude-dash reads Claude Code's session registry directly and shows all of it in
one place, with anything waiting on you pushed to the top.

## What it looks like

The badge, in your bar — `working ▸ attention ▸ idle`, amber when something wants you:

```
󰚩 1▸2▸8
```

The board, toggled by clicking it:

```
 claude sessions · thinkpad
   1 working · 2 attention · 8 idle

 INTERACTIVE
  ● busy     api refactor             ~/src/api                        54s
  ○ idle     changelog tidy-up        ~/src/docs                        2d

 BACKGROUND
  ! blocked  migration question       which database, staging or prod?  2d

   … 1 finished (nightly sync)
 workstation
 INTERACTIVE
  ! waiting  resourcing               ~/src/planner                     2d
 BACKGROUND
  ! blocked  deploy script            needs an answer                   6d

 buildbox  (unreachable: connection timed out)
 INTERACTIVE
  ○ idle     integration suite        ~/ci                              3d

   q close
```

A host that can't be reached keeps showing what it last reported, clearly
labelled, instead of silently vanishing.

## Requirements

`bash`, `jq`, `sway`, `waybar`, `foot`, `flock`. A machine that only *contributes*
its sessions to someone else's board needs just `bash` and `jq`.

## Install

```sh
git clone <this repo> ~/projects/claude-dash
cd ~/projects/claude-dash && ./install.sh
```

The board is a floating scratchpad window: **Super+left-drag** moves it,
**Super+right-drag** resizes it, and it keeps wherever you put it across
toggles. It is only re-centred on launch, or if it ends up on no active
output at all. The sway snippet sets `floating_modifier` for that, because a
user config replaces `/etc/sway/config` instead of extending it and a config
that never sets it leaves every floating window undraggable.

`install.sh` symlinks the six scripts into `~/.local/bin`, scaffolds
`~/.config/claude-dash/hosts` (all commented out), and prints the sway, waybar
and CSS blocks to paste. Then `swaymsg reload`.

For a headless machine that only contributes sessions:

```sh
./install.sh --producer-only
```

That needs only `bash` and `jq`, symlinks just `claude-sessions`, and prints the
one line to add to the *controlling* machine's hosts file.

## Aggregating other machines

List remotes in `~/.config/claude-dash/hosts`, one per line — `host` or
`user@host`, `#` comments ignored:

```
workstation
deploy@10.0.0.5
```

Each remote needs `claude-sessions` installed (`--producer-only` is enough) and
key-based SSH from this machine. Fetches use `ssh -o BatchMode=yes`, so anything
that would prompt fails cleanly and is reported as `auth failed`.

Fetching never blocks your bar. `claude-sessions-all` notices when the cache is
older than `CLAUDE_DASH_FETCH_EVERY` seconds, spawns `claude-dash-fetch` fully
detached, and immediately returns whatever is already cached. Run
`claude-dash-fetch` by hand to force a refresh.

`claude-dash-fetch` does not rely on the remote's `PATH` — a non-interactive SSH
session usually has no `~/.local/bin` — so it runs an explicit remote command,
`~/.local/bin/claude-sessions` by default (the tilde expands on the *remote*
side). Override globally with `$CLAUDE_DASH_REMOTE_CMD`, or per host by
appending `=<remote_cmd>`:

```
deploy@10.0.0.5=/opt/claude-dash/bin/claude-sessions
```

Each host is shown as `fresh` (cached within `CLAUDE_DASH_STALE_AFTER`, default
45 s), `stale` (older, rows still shown), or `unreachable` (last fetch failed —
the heading carries the error, the rows are the last good payload).

With no hosts configured this degrades to plain local output. A single-machine
setup is unchanged.

## How sessions are classified

Every session lands in exactly one group, decided once in `claude-sessions` and
stamped on the record as `working` / `attention`. Nothing downstream recomputes it.

| Group | Meaning | Membership |
|---|---|---|
| **working** | The machine is busy; you need not act. | `status` is `busy`, `shell` or `active` |
| **idle** | Nothing pending. | `status` is `idle` |
| **attention** | You need to act. | `state` is `blocked`, **or** any status not listed above |

Attention is a deliberate catch-all rather than a second list. A status this tool
doesn't recognise — `waiting`, a typo, whatever a future release invents — counts
as wanting your attention instead of quietly sorting into idle. That exact bug
was real: an interactive session on another machine reporting `waiting` was
indistinguishable from "nothing running" in every count and every alert. An
unknown state is far likelier to want you than to be safely idle, so that is the
side it defaults to.

The board and tooltip always print the literal status word, so an unfamiliar
value stays identifiable rather than being flattened to a generic label.

`claude-sessions-all` re-derives this for every row, local and remote, instead of
trusting what a producer attached. Remotes run their own build, possibly older
than yours, and trusting a remote's self-report would just move the
"unrecognised status is invisible" hole to whichever machine has the stalest
install.

## The six scripts

| Script | Job |
|---|---|
| `claude-sessions` | Reads the local registry, filters to live processes, prints normalized JSON. The only component that knows Claude Code's on-disk layout. |
| `claude-sessions-all` | Merged producer: local rows plus each remote's cached rows, every row labelled with `host`. What the badge and board read. |
| `claude-dash-fetch` | Refreshes the remote cache: one `ssh … claude-sessions` per host, in parallel, written atomically. Never on the fast path. |
| `claude-dash-badge` | waybar `exec`: counts and alert class across every host, tooltip grouped by host. |
| `claude-dash` | The board. `--once` prints one frame and exits. |
| `claude-dash-toggle` | waybar `on-click`: show or hide the scratchpad window. |

## Design notes

**The fast path never spawns a process per session.** It reads
`~/.claude/sessions/*.json` and `~/.claude/jobs/*/state.json` directly, because
`claude agents --json` costs ~0.5 s and ~300 MB per call — not something to run
every 2 seconds. That is an internal layout with no compatibility promise, so if
it ever changes the tools fall back to `claude agents --json` and the board
header shows `⚠ degraded (CLI fallback)` to explain why it got slower.

**A remote is a trust boundary.** Its payload is validated, size-capped,
type-coerced and re-sanitised locally before rendering, because remote text lands
in a Pango tooltip where markup and line separators would otherwise let a remote
forge rows. The merge is total: no input, however malformed, can make it emit
nothing — a property asserted directly by a fuzz test, because "one bad host
blanks the whole dashboard" was a real defect twice over.

**Nothing is written to `~/.claude`.** It belongs to Claude Code; this reads it.

## Tests

```sh
./tests/run.sh          # 380 checks; no sway, network or Claude Code session needed
shellcheck -x bin/* install.sh tests/*.sh
```

The suite is hermetic: stubs for `ssh` and `swaymsg`, fixture registries, and no
path to the real `claude` binary or your real cache.

## Colour

The board colours each session row by its group, using the same kanagawa
palette `config/waybar.style.css` uses, so the bar and the board agree:
attention rows are surimiOrange, working rows crystalBlue, idle rows fujiGray.
A remote host heading is bold (default foreground) when reachable, or
samuraiRed when `unreachable`; the same red marks the board's own `⚠ degraded`
/ `⚠ N unreadable` warnings and any "could not parse"/"no data" error text. The
`… N finished` collapse line and the `q close` footer are dim.

Colour is applied only after `jq` finishes all width/truncation math on plain
text — a rendered line's visible content is identical whether colour is on or
off, so colour can never corrupt the layout.

`CLAUDE_DASH_COLOR` controls *when*: `auto` (default) colours only when stdout
is a terminal, `always` forces it on, `never` forces it off. `NO_COLOR`
(<https://no-color.org>; any non-empty value counts) always wins, even over an
explicit `CLAUDE_DASH_COLOR=always` — it is a blanket opt-out, not one this
tool's own switch gets to override.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_DASH_ROOT` | `~/.claude` | Registry root. Point at a fixture tree to test. |
| `CLAUDE_DASH_PRODUCER` | sibling `claude-sessions-all` | Data source for badge and board. |
| `CLAUDE_DASH_LOCAL_PRODUCER` | sibling `claude-sessions` | Local source used by `claude-sessions-all`. |
| `CLAUDE_DASH_INTERVAL` | `2` | Board refresh seconds while visible. |
| `CLAUDE_DASH_IDLE_INTERVAL` | `60` | Board refresh seconds while hidden. |
| `CLAUDE_DASH_CLI` | `claude` | Binary used for the degraded-mode fallback. |
| `CLAUDE_DASH_ARBITRATE_EVERY` | `60` | Minimum seconds between fallback cross-checks. |
| `CLAUDE_DASH_PIDFILE` | `$XDG_RUNTIME_DIR/claude-dash.pid` | How the toggle finds the board to signal it. Board and toggle must agree. |
| `CLAUDE_DASH_STAMP` | `$XDG_RUNTIME_DIR/claude-dash-arbitrated` | Rate-limit stamp for the fallback cross-check. |
| `CLAUDE_DASH_BOARD` | `claude-dash` | Board command the toggle launches. |
| `CLAUDE_DASH_WIDTH` | `900` | Board window width, applied each time it is shown. |
| `CLAUDE_DASH_HEIGHT` | `520` | Board window height, applied each time it is shown. |
| `CLAUDE_DASH_HOST` | `uname -n` | Overrides the hostname shown in header and tooltip. |
| `CLAUDE_DASH_COLOR` | `auto` | `auto`\|`always`\|`never` — when the board colours its output. `auto` colours only when stdout is a terminal. |
| `NO_COLOR` | unset | Any non-empty value forces colour off, overriding `CLAUDE_DASH_COLOR=always`. See <https://no-color.org>. |
| `CLAUDE_DASH_BIN_DIR` | `~/.local/bin` | Where `install.sh` symlinks scripts. |
| `CLAUDE_DASH_HOSTS` | `~/.config/claude-dash/hosts` | Remote host list. |
| `CLAUDE_DASH_CACHE` | `${XDG_CACHE_HOME:-~/.cache}/claude-dash` | One `<host>.json` per remote. |
| `CLAUDE_DASH_STALE_AFTER` | `45` | Seconds before a cache is shown as stale. |
| `CLAUDE_DASH_FETCH_EVERY` | `20` | Minimum seconds between background refreshes. |
| `CLAUDE_DASH_FETCH` | sibling `claude-dash-fetch` | Fetch binary to spawn. |
| `CLAUDE_DASH_FETCH_STAMP` | `$CLAUDE_DASH_CACHE/.fetch-trigger-stamp` | Rate-limit stamp for the background fetch. |
| `CLAUDE_DASH_FETCH_CONNECT_TIMEOUT` | `5` | ssh `ConnectTimeout` per host. |
| `CLAUDE_DASH_FETCH_TIMEOUT` | `10` | Wall-clock timeout per host fetch. |
| `CLAUDE_DASH_SSH` | `ssh` | ssh binary to call. Override with a stub to test. |
| `CLAUDE_DASH_REMOTE_CMD` | `~/.local/bin/claude-sessions` | Remote command run over ssh. |

## Known follow-ups

- The board's truncation ellipsis covers session rows but not the header or the
  collapsed "N finished" footer, which are still hard-cut at very narrow widths.
- The toggle closes fd 9 so the launch lock isn't held for the board's lifetime,
  but no test would catch it if that were removed.

## Licence

MIT — see [LICENSE](LICENSE).
