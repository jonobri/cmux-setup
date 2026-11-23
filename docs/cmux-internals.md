# What this repo relies on in cmux

Most of this is not documented by cmux. It was observed on **cmux 0.65.2 (113)** and may change. If something here stops working after a cmux update, start here.

## Socket modes and access

`~/.config/cmux/cmux.json` (and Settings → Automation) sets `automation.socketControlMode`. The modes seen: `off`, `cmuxOnly` (the default), `automation`, `password`, `allowAll`.

- `cmuxOnly` refuses any process not started inside cmux: `Access denied - only processes started inside cmux can connect`. A helper outside cmux cannot read tabs or switch.
- `password` accepts outside processes that authenticate. The password lives in cmux's own secure store, not in the macOS Keychain items other tools can read, and not in `cmux.json`. Never commit it.
- The CLI outside cmux authenticates by itself, by reading the saved password. That Keychain read is most of a CLI call: about 130–160 ms, against about 10 ms when the password is supplied.
- The CLI takes the password from `--password`, then the `CMUX_SOCKET_PASSWORD` environment variable, then the saved one. A wrong value in the environment fails at once with `Invalid password`; it does not fall back.
- Inside cmux, every terminal has `CMUX_SOCKET_PATH` and `CMUX_SOCKET_CAPABILITY` set. In password mode the capability alone is not accepted from a plain script; the server answers `auth_required`.

## Socket wire format

The socket is a Unix socket, by default `~/.local/state/cmux/cmux.sock` (see `CMUX_SOCKET_PATH`). One request per line.

1. In password mode send `auth <password>\n`. The reply starts with `OK`.
2. Then send JSON-RPC lines: `{"jsonrpc":"2.0","id":1,"method":"surface.focus","params":{...}}\n`.
3. The reply is one line: `{"id":1,"ok":true,...}` or `{"id":1,"ok":false,"error":{"message":"…","code":"…"}}`.

`switcher/CmuxSwitcher.swift` (`CmuxSocket`) is a working client. Doing this directly instead of running `cmux rpc …` removes the CLI's start-up cost: a switch drops from about 150 ms to a few.

`cmux rpc <method> '<json>'` calls the same methods from a shell. Useful ones:

| Method | Params | Notes |
| --- | --- | --- |
| `workspace.list` | `{}` | Each workspace has `id`, `title`, `custom_title`, `custom_color`, `selected` |
| `surface.focus` | `{surface_id, workspace_id}` | Selects the workspace **and** the tab in one call. Do not follow it with `workspace.select`. |
| `workspace.select` | `{workspace_id}` | |
| `workspace.reorder` | `{workspace_id, index}` | |
| `tab.action` | `{action: "pin"\|"unpin", surface_id, workspace_id}` | cmux's native tab pin |

`cmux --id-format uuids --json tree` returns windows → workspaces → panes → surfaces, each surface with `id`, `title`, `type`, `here` (the terminal running the command) and `focused`. Without `--id-format uuids` the ids are short refs, not UUIDs.

## Events

`cmux events --name surface.focused --name workspace.selected --after 0 --no-ack --no-heartbeat` streams newline-delimited JSON.

- `surface.focused` and `surface.selected`: payload `surface_id`, top-level `workspace_id`.
- `workspace.selected`: payload `workspace_id` and `previous_workspace_id`. It carries no tab, so it only says the tab list changed.
- `window.focused`, `workspace.prompt.submitted` also exist.
- `--after 0` replays the events cmux still retains, oldest first. The retained history is short (about nine `surface.focused` events were seen), so a recency list rebuilt from it starts thin. The switcher saves its own order between runs for this reason.

## Agent sessions in sidebars

In a sidebar's `data.workspaces()`, each workspace has `agents[]` and `tabs[]`. An agent has `status` (`working`, `needs_input`, `ended`, or idle), `panelId`, `surfaceId`, `sinceEpoch` or `lastActivityAt`, and `children[]` (subagents). **An agent's `panelId` is its terminal tab's `id`. Its `surfaceId` is not the tab's `surfaceId`.** Match on `panelId`, and focus the tab using the tab's own `surfaceId`.

## Notification hook contract

A hook receives JSON on stdin and must print JSON on stdout: a `notification` block (`title`, `subtitle`, `body`, `surfaceId`), an `agent` block for notifications from agent hooks (`kind`, `category`, `pending`, `isSubagent`), `context` (for example `cwd`) and `effects`. On any error, timeout or invalid JSON cmux falls back to the default banner and posts a failure alert, so a hook must always echo its input on failure.

- Setting `effects.record = false` stops cmux withdrawing the banner when you focus the tab, because cmux can only withdraw notifications it recorded.
- The body's newlines are flattened before the hook sees it.
- cmux keeps only the newest notification per tab, which is why the idle reminder overwrites a detailed turn-end message.
- The session file `~/Library/Application Support/cmux/session-com.cmuxterm.app.json` lists windows, workspaces and panels, but it is written periodically and lags real delivery. It is fine for names, not for recent events.

## Config

- `cmux config doctor` validates `cmux.json`. `cmux reload-config` applies it. `cmux sidebar validate` and `cmux sidebar reload` do the same for sidebars.
- `app.goToWorkspaceOrder: "recent"` makes cmux's own Go to Workspace list recency-ordered.
- `notifications.suppressOnlyFocusedSurface` and `notifications.agentIdleReminder` are described in [notifications.md](notifications.md).

## macOS pieces (the switcher)

- A CGEventTap that swallows keys needs the Accessibility permission, granted to a code signature. An ad hoc signature changes on every build, so the grant stops matching. A self-signed identity keeps the same designated requirement across rebuilds.
- `security find-generic-password -w` can hang on a hidden Keychain prompt. Do not call it from automation. The switcher reads its Keychain item through `SecItemCopyMatching` with `kSecUseAuthenticationUIFail`, so it never prompts.
- macOS has no `timeout` command.
