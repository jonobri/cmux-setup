# Notification hook

cmux lets you register a hook that sees every notification before it is shown. `hooks/enrich-notification.py` uses it to make agent banners useful.

## Before and after

cmux's default banner for an agent that has finished:

```
Claude Code
Claude is waiting for your input
```

With a dozen workspaces, that does not say which one is asking or what it wants. The hook rewrites it to:

```
api-server — turn complete
Claude Code
A flaky test is one that gives different results (pass or fail) on the same code…
```

- **Title:** the workspace, then the action you need to take: `turn complete`, `permission needed`, `needs a decision`, `waiting for you`, `done, background tasks running` or `error`.
- **Subtitle:** the tab name when the workspace has more than one tab, otherwise the original title.
- **Body:** the agent's own message, with markdown stripped (macOS banners show `**bold**` literally).

## How the action is chosen

cmux sends an `agent` block with notifications from agent hooks: `category` (`turn-complete`, `needs-permission` or `idle-reminder`), `pending` (the turn ended with background work still running), and `isSubagent`. The hook trusts that first, because it comes from the agent's own hooks and not from the message text. A finished turn is never labelled "permission needed", whatever the text says. Questions ("should I…?") and errors in a finished turn are still named, because they need a different kind of attention.

For notifications with no agent block (plain `cmux notify`, terminal escape sequences) it falls back to text rules that match the exact shape Claude Code uses for permission prompts and API errors, not loose keywords. Loose matching once labelled ordinary replies "permission needed".

## Restoring the detail

cmux keeps only the newest notification per tab. About 60 seconds after a turn ends, the idle reminder replaces "Delete 12, keep 6?" with "Claude is waiting for your input". The hook saves the last informative body per tab in `~/.cache/cmux-notify/` and puts it back into the reminder. Entries older than an hour are ignored.

## Install

1. Copy the script and make it executable:
   ```sh
   mkdir -p ~/.config/cmux/hooks
   cp hooks/enrich-notification.py ~/.config/cmux/hooks/ && chmod +x ~/.config/cmux/hooks/enrich-notification.py
   ```
2. Add the hook to `~/.config/cmux/cmux.json`, with an absolute path:
   ```jsonc
   "notifications": {
     "suppressOnlyFocusedSurface": true,
     "agentIdleReminder": false,
     "hooks": [
       { "id": "workspace-and-action", "command": "/Users/YOU/.config/cmux/hooks/enrich-notification.py", "timeoutSeconds": 5 }
     ]
   }
   ```
3. Check and apply: `cmux config doctor && cmux reload-config`.

The two settings beside it are worth having:

- `suppressOnlyFocusedSurface` withdraws a banner only when its exact tab is focused. By default it is withdrawn when its whole workspace becomes visible, so with two agents in a workspace the banner for the tab you are not looking at vanishes unseen.
- `agentIdleReminder: false` turns off the idle nudge, which duplicates the turn-end banner. With it on, the "restore the detail" step above keeps the reminder informative.

## Failure contract

cmux falls back to the default banner and posts a hook-failure alert on any error, timeout or invalid JSON. So every path in the script ends by writing the untouched input back, and nothing is allowed to raise. The worst case is the old behaviour.

The script reads cmux's session file (`~/Library/Application Support/cmux/session-com.cmuxterm.app.json`) for workspace and tab names, not the `cmux` CLI. The hook runs inside cmux's notification path, and calling back into the control socket risks re-entrancy and the hook timeout.

## Tests

```sh
python3 hooks/test_enrich_notification.py
```

13 tests cover the category rules, markdown stripping (it must leave `__init__.py`, `PR #138` and `rm -rf build/*` alone), pass-through on bad input, and the restore step. The script uses only the Python standard library.

## Tested with

cmux 0.65.2 and Claude Code. The categories come from cmux's agent hooks, so other agents cmux integrates with may work. That is untested.
