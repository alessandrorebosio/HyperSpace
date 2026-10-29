# 9. Settings window and menu bar

Code: `Settings/`, `App/StatusMenu.swift`, `App/MainMenu.swift`.

## Menu bar item

The menu is rebuilt only when it opens (`menuNeedsUpdate`).

**Icon / title**
- Normal: the symbol `square.grid.2x2`. A problem shows `exclamationmark.triangle`; a locked keyboard shows `lock`.
- **With more than one workspace configured**, the icon is replaced by an i3-style title: the workspace shown on each display left to right, separated by ` | ` (e.g. `1 | music`), `–` for a display showing none.
  With several displays, the focused display's name is bold. A lock prefixes it when the keyboard is locked, `⚠︎` when there is a problem.
- **With tiling off the item is hidden**, unless there is a problem to report or the keyboard is locked. Double-click the app to open Settings.

**Menu contents** (top to bottom)
1. **Problem** (if any): `Accessibility not granted to this build` (click: opens the Accessibility pane) or `Config error: …` (click: opens the config file; the tooltip has the message; the last valid config stays active).
2. **Workspaces** — only when more than one workspace is configured and some have windows: one line per workspace with windows, name in bold followed by the icons of its apps (one per app, tiling order), a ✓ on workspaces currently shown,
   a tooltip listing "App — window title". A click shows the workspace (`switchWorkspace`).
3. **Layout** submenu (tiling on): tall, wide, columns, monocle, ✓ on the focused display's layout; a click changes it.
4. **Lock Keyboard** / **Unlock Keyboard** (with the countdown when it unlocks by itself).
5. **Settings…** (⌘,).
6. **Copy Debug Info**: copies the report described in [page 10](10-permissions-troubleshooting-build.md#copy-debug-info).
7. **Quit HyperSpace** (⌘Q).

## The settings window

- Opened from the menu, by double-clicking the app, or automatically at the first config load if tiling is off and the app was opened by hand (not at login).
- Built on demand and **destroyed on close**, so it costs nothing while closed. While open, HyperSpace becomes a regular app (Dock icon, ⌘Tab, its own menu bar: `MainMenu`, ⌘W closes the window); when closed it goes back to being a menu bar-only app.
- Liquid Glass style, resizable (minimum 680×420, default 900×640, frame remembered), sidebar:
  **Input** → Keyboard, Mouse; **Windows** → Tiling, Workspaces, Window Rules, Shortcuts; then **Settings**.
- Switching page stops any key/button capture in progress.
- Pages that need Accessibility (everything except Keyboard and Settings) show a top banner **Accessibility permission needed** with *Open System Settings…* (disappears once granted).
  Window pages show a **Tiling is off** banner with *Turn On* while tiling is disabled (settings are kept).
- Every change is written to `config.json` immediately (see [Configuration](02-configuration.md)); errors appear in the page footer.

### Keyboard
- **Keyboard Lock**: status, picker for the auto-unlock time (1/3/5/10 minutes, Never), *Lock Keyboard* / *Unlock*. ([details](03-keyboard.md#keyboard-lock))
- **Remaps**: a list of rules — source key cap → target key cap, a menu with all keys (grouped as in the key table), the keyboard picker, a duplicate warning, remove button, and *Add Remap*.
  Capture rules: click a field and press keys; the source takes the first key; the target takes a key, a modifier+key combination, or a modifier-only combination. Remaps are suspended during capture. ([details](03-keyboard.md#remapping-from-settings))
  Incomplete rules are not saved.

### Mouse
- **Scrolling**: *Reverse scroll wheel*.
- **Buttons**: rules of mouse button (with modifiers) → action (a key combination, a ready-made action or Disabled); *Add Button*. ([details](04-mouse.md))

### Tiling
- **Tile windows** switch.
- **Layout**: thumbnails of the four layouts (drawn with the current gap and padding), *Gap between windows* and *Margin around the screen* steppers (0–64 pt, step 2).
- **Focus**: *Pointer follows focus*.
- The footer carries a hint, "Next layout in Shortcuts cycles through them on the fly", which is **stale**: the `layout next` action was removed (see [README vs code](11-readme-vs-code.md)).

### Workspaces
- **Workspaces**: name field (renames are saved 0.5 s after typing and update app rules), *Show workspace* and *Move window here* shortcut capture, remove, *Add Workspace*.
- **App Rules**: apps (picked from running apps or *Other App…*) with the workspace they open in. Needs at least one workspace to add a rule.
- Hint: windows of other workspaces are parked out of sight and come back when you switch, quit or turn tiling off; ⌘Tab to a window in another workspace switches to it.

### Window Rules
- **Floating**: apps whose windows never tile (an app with no title) and title rules (app or any + "Title contains…"). ([details](06-tiling.md#floating-windows-and-rules))
- **Scratchpad Apps**: per app, *Show / hide* and *To tiling and back* shortcuts; adding an app starts capturing its first shortcut. ([details](08-scratchpad.md))

### Shortcuts
Shortcut capture (Esc cancels, Delete clears). Groups:
- **Focus & Move**: for left/down/up/right, a focus shortcut and a move-window (`swap`) shortcut.
- **Resize**: Width and Height, smaller/larger (`resize width -50` / `+50` …).
- **Displays**: *Focus other display* (`focus-display`), *Move workspace to other display* (`move-workspace-to-display`).
- **More**: *Previous workspace* (`workspace back-and-forth`), *Toggle floating* (`float`), *Move window to or from the scratchpad* (`move-to-scratchpad`).
These shortcuts are stored as ordinary entries in `keyboard.bindings` (the UI replaces only its own actions and keeps the others). A shortcut used twice shows a warning (only the last one would work).
During capture key bindings are suspended (so existing shortcuts reach the window) but remaps stay active (so caps lock → ⌃⌥⇧ can be part of a shortcut).

### Settings
App icon, version (`CFBundleShortVersionString`), *Quit HyperSpace*; **Startup** → *Launch at Login* (`SMAppService`); **Configuration** → file path, *Edit Config…*, *Show in Finder*, status line with the current problem (if any);
**Permission** → Accessibility state (*Granted* or *Open System Settings…*; re-checked when the app becomes active).

## Names and icons caching

`TilingModel` caches app names and icons by bundle id (`appInfo`), because rows ask on every redraw and LaunchServices is slow.
