# The Inbox sidebar

A custom cmux sidebar that answers "which terminal do I need to go to?" without clicking through them. It replaces the stock workspace list in the left sidebar, so it has two halves.

## The Inbox (top)

Every live agent session is sorted into one of these.

| Section | What is in it |
| --- | --- |
| **Next** | The session that has waited longest for you, excluding the terminal you are already looking at. Click to jump to it. |
| **Your turn** | The other sessions waiting for you, longest wait first. Capped at six, with "+N more". |
| **Running** | Sessions currently working, with elapsed time and a count of running subagents. |
| **Parked 24h+** | Sessions untouched for 24 hours or more, so abandoned tabs do not bury live ones. Click the header to show or hide them. A session that needs your input is never parked. |
| **Priority** | Tabs you pinned. Right-click any session row and choose "Pin to Priority". This uses cmux's own tab pin, so pins persist across restarts and you can pin from the tab bar too. |

Each row has three lines: the tab title, then a workspace tag (in the workspace's colour) with the time waiting or running, then what you last asked, dimmed. The time turns amber after an hour waiting or 15 minutes running.

## Workspaces (below)

The usual workspace list. Each row has a colour bar, a dot for agent state (blue running, green waiting, amber waiting too long), the branch with `*` if dirty, the open PR, and task progress. Drag to reorder. The row text always starts at the same x, so the list stays aligned whatever the colours.

## Install

```sh
cp sidebars/inbox.js ~/.config/cmux/sidebars/inbox.js
cmux sidebar validate        # checks every sidebar file
cmux sidebar select inbox
```

`cmux sidebar open inbox` previews it as a pane first. To go back to the stock list, remove the file and run `cmux sidebar reload`, or pick the stock sidebar in cmux's settings. To keep the file in your dotfiles, symlink it instead of copying.

Workspace colours come from cmux (`cmux workspace-action --action set-color --workspace <id> --color '#0A84FF'`, or the workspace's context menu). Without a colour, the tag is neutral grey.

## Tuning

The constants at the top of `inbox.js` set the thresholds:

| Constant | Default | Meaning |
| --- | --- | --- |
| `PARK_AFTER_SECS` | 24 hours | Idle time before a session moves to Parked |
| `STALE_WAIT_SECS` | 1 hour | Wait before a time tag turns amber |
| `LONG_RUN_SECS` | 15 minutes | Run time before a time tag turns amber |
| `MAX_PER_PILE` | 6 | Rows shown per section before "+N more" |

The defaults came from one person's agent journal over 19 days (656 replies, 1,298 turns): the median wait before a reply was 4 minutes, but 8% sat over an hour; 28% of turns ran over 5 minutes and 7% over 15. Tune them to your own habits.

## Things to know if you edit it

- cmux sidebars are JavaScript run by cmux, with `data.workspaces()`, `signal`, `computed`, layout primitives such as `VStack`, `HStack`, `ForEach` and `Reorderable`, and `cmux(method, params)` to call the control API. The file has no build step.
- An agent's `panelId` is its terminal tab's `id`. The agent's own `surfaceId` is not the tab's `surfaceId`, so match on `panelId`. Jumping needs the tab's `surfaceId`, never the agent's.
- Text colour on a workspace tag is chosen by luminance (`inkOn`), so pale colours such as yellow get dark text.
- Run `cmux sidebar validate` after every edit.
