# The Cmd+G switcher

A small macOS helper that gives cmux an Arc/Dia-style recent-tab switcher. Hold Cmd, tap G, and a list shows your last eight tabs. Keep tapping G to move down the list. Release Cmd to switch.

It lists **tabs**, not workspaces. A tab is a cmux surface, so two terminals in the same workspace are two rows. Each row shows the tab title, a coloured bar and a tag in its workspace's colour (set with cmux's workspace colours), and "current" on the tab you are on.

## Keys

These work only while cmux is the frontmost app.

| Key | Does |
| --- | --- |
| Cmd+G | Opens the list with the previous tab selected |
| G (Cmd held) | Moves down; wraps at the end |
| Shift+G | Moves up |
| Up, Down | Move up and down |
| 1–8 | Select that row |
| Release Cmd, or Return | Switch to the selected tab and its workspace |
| Esc | Cancel |

Every other key passes through untouched. The list closes itself if Cmd is no longer held or cmux loses focus, so a missed key-up cannot leave the keyboard stuck.

## Install

You need Xcode's command-line tools (`xcode-select --install`) for `swiftc`.

1. **Set cmux's socket mode to Password.** In cmux, Settings → Automation, choose Password and set one. cmux only accepts outside programs in password mode; the default (`cmuxOnly`) refuses them with "Access denied - only processes started inside cmux can connect". cmux keeps the password in its own secure store. Do not put it in `cmux.json`.
2. **Optional: create a signing identity (once).** `switcher/build.sh --setup-signing` makes a self-signed code-signing certificate, "CmuxSwitcher Local Signing", and trusts it for code signing. macOS asks for your login password once. Without it the app is signed ad hoc, which changes its signature on every rebuild, so macOS asks for the Accessibility permission again each time.
3. **Build and start it.** `switcher/build.sh --install` builds `~/Applications/CmuxSwitcher.app` and runs it as a login LaunchAgent.
4. **Allow Accessibility.** System Settings → Privacy & Security → Accessibility → switch on CmuxSwitcher. The helper's log says "waiting for the Accessibility permission" until you do, then "key tap installed".
5. **Optional, recommended: make it fast.** `switcher/build.sh --set-password` asks for the same socket password and stores it in a Keychain item the helper can read. With it a switch goes straight to cmux's socket and takes about 5–40 ms. Without it each switch runs the `cmux` CLI, which takes about 150 ms. Everything still works either way.

The tab history starts short: cmux keeps only a few recent events, so a fresh install knows only a handful of tabs. It fills as you use cmux, and it is saved between restarts.

## Commands

```sh
switcher/build.sh                  # build only
switcher/build.sh --install        # build, then (re)start the LaunchAgent
switcher/build.sh --uninstall      # stop it and remove the LaunchAgent
switcher/build.sh --setup-signing  # create the local signing identity
switcher/build.sh --set-password   # give the helper the socket password
~/Applications/CmuxSwitcher.app/Contents/MacOS/CmuxSwitcher --demo   # draw the list with invented tabs
```

`SIGN_ID="Developer ID Application: …" switcher/build.sh` signs with an identity of your choice instead.

## Logs and troubleshooting

The log is `~/Library/Logs/CmuxSwitcher.log`.

| You see | Cause and fix |
| --- | --- |
| Cmd+G opens cmux's own list, or Find Next | The helper is not running or lacks Accessibility. Check the log for "key tap installed". If you rebuilt with ad hoc signing, run `tccutil reset Accessibility com.jonobri.cmux-switcher`, restart it with `switcher/build.sh --install`, and allow it again. Use `--setup-signing` to stop this recurring. |
| "Can't reach cmux" in the list | The socket is not in password mode, or the password changed. Check Settings → Automation. |
| `refresh failed … Access denied - only processes started inside cmux can connect` | Socket mode is `cmuxOnly`. Switch to Password. |
| `refresh failed … auth_required` | Password mode is on but the CLI has no password. Open cmux Settings → Automation and set one. |
| "Not enough history yet" | Fewer than two tabs known. Use cmux for a minute. |
| `saved socket password not used` / `socket auth not accepted` | The saved password is missing or wrong. Run `--set-password` again with the password from cmux's Settings. Switching still works through the CLI. |
| `signing identity is not usable` | Re-run `--setup-signing` and enter your login password when macOS asks. |

## Security

- The helper watches keyboard events only while cmux is frontmost, and acts only on the keys in the table.
- The socket password is held in a Keychain item named `com.jonobri.cmux-switcher` that only the helper's binary is trusted to read. It is never written to a file, a log or the repo.
- The helper talks only to cmux's local Unix socket. It makes no network requests.
- Read `switcher/CmuxSwitcher.swift`: it is one file.

## Limits

- Tested on cmux 0.65.2. It depends on cmux's undocumented socket and event stream; see [cmux-internals.md](cmux-internals.md).
- It claims Cmd+G whenever cmux is frontmost. To use a different chord, change `keyG` in the Swift file and rebuild.
- Browser tabs are listed too. Filtering them out is a one-line change in `Model.ordered()`.
