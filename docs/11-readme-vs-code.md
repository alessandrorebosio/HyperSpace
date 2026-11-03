# 11. README vs code

The repository README and these pages were compared with the code (a second, full pass after the commits from `6dabf49` on: config in `~/.hyperspace` with migration, accordion layout, display standby, focus anchor, device batteries, drag writes through `AXWriter`, empty workspaces on another display, the settings redesign). The code wins; this page keeps what is left to know.

## Fixed in the README

- Per-app workspace rules (**App Rules**) are on the **Workspaces** page, not on Tiling.
- **Caps+N** and **Caps+⌘+Tab** are not in the default config (it defines no workspaces and no display shortcuts): they exist only if you create them (Settings → Workspaces / Shortcuts → Displays).
- Modifier-drag resize of a tiled window moves the master/stack split only in `tall`/`wide`; in `columns`, `monocle` and `accordion` the delta is 0 and the window returns to its tile.
- The menu lists the workspaces only when **more than one workspace is configured**; it has no Layout submenu; the icon is always there (dimmed with tiling off).
- `move-to-scratchpad <App>` is documented.
- The architecture tree lists every folder's files.
- The hint in Settings → Tiling about layout shortcuts was removed from the page (layout actions are bound in `config.json`: [page 5](05-actions.md)).

## Fixed in the second pass

- Settings window: minimum size is **720×460** (the README said 680×420); the last sidebar page is **General** (the README and architecture tree said Settings); the sidebar has no search; each page has one title and a one-line summary, no large header; rows carry no colored icons ([page 9](09-settings-and-menu.md)).
- The default config includes `hyper+a` → `accordion`; page 2 listed it without.
- **Shortcuts** page: the *More* group also has *Stack windows as an accordion*.
- Menu problem line: `Accessibility permission needed` (was `… not granted to this build`); a config error is cut to its first line (~48 characters) in the menu, the tooltip has all of it.
- Device batteries are orange at 15% or less **only while not charging**.
- *Copy Debug Info* also reports the devices, each display's UUID and visible frame, and displays left out.
- The README mentions the migration of the config from `~/.config/hyperspace/`, and the `--render-settings` option (page 10).

## Fixed in the cleanup pass

- The README now says renaming a workspace happens on the **Workspaces** page (it said Tiling), and its architecture tree lists the files split out of `WindowManager.swift` (`WindowManager+*.swift`, `ManagedWindow.swift`, `ScreenInfo.swift`, `Modifiers.swift`).
- Re-checked against the code, all the points above hold: App Rules on Workspaces; Caps+N and Caps+⌘+Tab only if created; resize moves the split only in `tall`/`wide`; the menu lists workspaces only with more than one configured; no `scripts/bundle.sh`; no stale layout hint on the Tiling page.

## Still only in the code / these pages

- With more than one workspace configured, the menu bar icon is replaced by the workspace shown on each display (`1 2`, the focused display's workspace in a filled box).
- Mouse buttons must be in 2…31; 0/1 produce a config error.
- Unknown JSON keys are silently ignored; values are clamped (`gap`/`padding` 0…64, `masterRatio` 0.1…0.9, `scratchpad` sizes 0.2…1).
- The `tiling` action and layout changes are runtime-only: they are not written to the file, and a reload restores the file's values.
- While the keyboard is locked the tap also listens to every key event and `NX_SYSDEFINED`.
- `print_screen`/`scroll_lock`/`pause` share key codes with F13/F14/F15 (see [Keyboard](03-keyboard.md#combinations-and-carriers)).
- There is no `scripts/bundle.sh`; `make app` builds the bundle.
