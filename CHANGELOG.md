# Changelog

## 0.1.0, 2026-11-23

First public release, tested on cmux 0.65.2 with Claude Code.

- **Switcher:** Cmd+G shows the last eight tabs you used, with a coloured bar and workspace tag for each. Hold Cmd and tap G to cycle, release to switch. Switches take about 5–40 ms with the saved socket password and about 150 ms without it.
- **Demo mode:** `CmuxSwitcher --demo` steps down the list over invented tabs and reads none of yours. The README GIF is a recording of it.
- **Sidebar:** the Inbox sidebar (Next, Your turn, Running, Parked 24h+, Priority, then the workspace list with colour bars).
- **Notification hook:** rewrites banners to lead with the workspace and the action, using cmux's own agent categories. 13 tests.
- **Example config:** a small `cmux.json` with the settings that helped.
