# AGENTS.md

Instructions for coding agents installing, verifying or changing this repo. Humans: start at [README.md](README.md).

## What this is

Three independent add-ons for [cmux](https://github.com/manaflow-ai/cmux) on macOS, tested on cmux 0.65.2 with Claude Code.

| Path | Is | Language | Runs where |
| --- | --- | --- | --- |
| `switcher/` | Cmd+G recent-tab switcher helper | Swift, one file, built with `swiftc` | A macOS LaunchAgent |
| `sidebars/inbox.js` | Inbox sidebar | JavaScript run by cmux | Inside cmux |
| `hooks/enrich-notification.py` | Notification rewrite hook | Python 3, standard library only | Spawned by cmux per notification |
| `examples/cmux.json` | Example config | JSONC | Read by cmux |

Background on cmux behaviour is in [docs/cmux-internals.md](docs/cmux-internals.md). Read it before changing anything that talks to cmux.

## Install, with checks

Do the steps the user asked for, in this order. Run each check and report its result; do not assume success.

### Sidebar

```sh
cp sidebars/inbox.js ~/.config/cmux/sidebars/inbox.js
cmux sidebar validate inbox        # must exit 0
cmux sidebar select inbox
```

Check: `cmux sidebar validate` prints no errors. If the user already has a sidebar of that name, ask before overwriting.

### Notification hook

```sh
mkdir -p ~/.config/cmux/hooks
cp hooks/enrich-notification.py ~/.config/cmux/hooks/ && chmod +x ~/.config/cmux/hooks/enrich-notification.py
python3 hooks/test_enrich_notification.py    # must print OK
```

Then add the `notifications` block from `examples/cmux.json` to `~/.config/cmux/cmux.json`, merging with what is there. Use an **absolute** path for the hook (replace `/Users/YOU`). `cmux.json` is JSONC and may be a symlink into the user's dotfiles; edit the real file and keep their comments. Then:

```sh
cmux config doctor       # no errors for this block
cmux reload-config
```

Check: trigger a notification with `cmux notify` or let an agent finish a turn, and confirm the title reads `<workspace> — <action>`.

### Switcher

Needs `swiftc` (`xcode-select -p` must succeed; if not, tell the user to run `xcode-select --install`).

```sh
switcher/build.sh --install
```

Steps only the user can do. Stop and ask for them; do not try to automate them:

1. **Socket mode.** In cmux, Settings → Automation, set the mode to Password and choose a password. Verify with `cmux ping` run **outside** cmux (for example `env -i HOME=$HOME /Applications/cmux.app/Contents/Resources/bin/cmux ping`): `PONG` means outside access works.
2. **Accessibility.** System Settings → Privacy & Security → Accessibility → switch on CmuxSwitcher.
3. **Signing, optional.** `switcher/build.sh --setup-signing` makes a self-signed identity. macOS shows a login-password dialog that only the user can answer. Do not run it unattended; it waits indefinitely.
4. **Saved password, optional.** `switcher/build.sh --set-password` prompts for the socket password. The user must type it. Never read it, log it or pass it on a command line.

Checks, from `~/Library/Logs/CmuxSwitcher.log`:

- `key tap installed` means Accessibility is granted and the tap is live.
- `saved socket password loaded` means the fast path is available.
- After the user presses Cmd+G and releases: `switched in N ms (direct socket)`.

## Rules

- **Never write the socket password anywhere**: not `cmux.json`, not a file in this repo, not a log, not a command line. `cmux.json` is often tracked in dotfiles.
- **Do not edit the user's other cmux or Claude settings** to make a check pass. If a prompt appears in an agent terminal you started for testing, cancel it rather than accepting it.
- Do not run `tccutil reset`, `--setup-signing` or `--uninstall` unless the user asked. Say what they do first.
- When driving cmux from a script, use a separate cmux window with invented workspace names for any screenshot, and capture one window by id (`screencapture -l <id>`), never the full screen.

## Changing the code

- **Tests.** `python3 hooks/test_enrich_notification.py` for the hook. The sidebar has no test harness: run `cmux sidebar validate` and look at it in cmux. The switcher: `swiftc -O -swift-version 5 -typecheck switcher/CmuxSwitcher.swift`, then `switcher/build.sh --install` and press the keys; `CmuxSwitcher --demo` draws the list with invented tabs and reads nothing from cmux.
- **The hook must never raise.** Every path ends by writing a valid payload, ideally the untouched input. Keep it to the standard library.
- **Switcher failures degrade, they do not break.** Anything that goes wrong on the fast path falls back to the CLI. Keep that property.
- **A switch is one call.** `surface.focus {surface_id, workspace_id}` selects the workspace and the tab. Two calls double the latency.
- **Match agents to tabs on `panelId`**, not `surfaceId` (see [docs/cmux-internals.md](docs/cmux-internals.md)).
- **Do not claim cmux behaviour you have not observed.** If you learn something new, add it to `docs/cmux-internals.md` with the cmux version.
- Update the docs in the same change. A doc says what is true now; what changed goes in [CHANGELOG.md](CHANGELOG.md), not in the doc or the code comments.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| Cmd+G does the native thing | Switcher log for `key tap installed`; Accessibility; see [docs/switcher.md](docs/switcher.md) |
| "Can't reach cmux" | Socket mode is not Password, or the password changed |
| Hook fails with a "hook failure" alert | Run it by hand: `echo '{"notification":{"title":"t","body":"b"}}' \| ~/.config/cmux/hooks/enrich-notification.py`; it should print JSON |
| Sidebar blank or wrong | `cmux sidebar validate inbox`; check `data.workspaces()` shape against your cmux version |
| Row jumps to the wrong tab | Using the agent's `surfaceId` instead of the tab's |
