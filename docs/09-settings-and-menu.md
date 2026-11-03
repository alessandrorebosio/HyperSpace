# 9. Settings window and menu bar

Code: `Settings/`, `App/StatusMenu.swift`, `App/MainMenu.swift`.

## Menu bar item

The menu is rebuilt only when it opens (`menuNeedsUpdate`).

**Icon / title**
- Normal: the symbol `square.grid.2x2`. A problem shows `exclamationmark.triangle`; a locked keyboard shows `lock`.
- **With more than one workspace configured**, the icon is replaced by an i3bar-style title: the workspace shown on each display left to right (e.g. `1 2 music`), `–` for a display showing none.
  The focused display's workspace sits in a filled rounded box with its name cut out, like i3bar's focused workspace button (also with a single display). A lock prefixes it when the keyboard is locked, `⚠︎` when there is a problem.
  It is drawn as one template image (`StatusMenu.workspacesImage`), so it follows the menu bar's light/dark color like the system items.
- **With tiling off** the icon is drawn dimmed (tooltip "tiling is off"); the item is always there.

**Menu contents** (top to bottom)
1. **Problem** (if any): `Accessibility not granted to this build` (click: opens the Accessibility pane) or `Config error: …` (click: opens the config file; the tooltip has the message; the last valid config stays active).
2. **Tiling** (✓ when on): turns the tiling engine on or off. Written to `tiling.enabled` in the config (Settings follows). Off: parked windows come back, apps are no longer observed, windows stay wherever you move them.
3. **Workspaces** — only when more than one workspace is configured and some have windows: one line per workspace with windows, name in bold followed by the icons of its apps (one per app, tiling order), a ✓ on workspaces currently shown,
   a tooltip listing "App — window title". A click shows the workspace (`switchWorkspace`).
4. **Devices** (only when some report a battery): wireless keyboards, mice and trackpads with their battery level (`Peripherals`, from the IOKit registry: `BatteryPercent` on `AppleDeviceManagementHIDEventService` or `IOHIDDevice`), ⚡︎ when charging, orange at 15% or less. Read when the menu opens; a click opens the Bluetooth settings.
5. **Lock Keyboard** / **Unlock Keyboard** (with the countdown when it unlocks by itself).
6. **Settings…** (⌘,).
7. **Copy Debug Info**: copies the report described in [page 10](10-permissions-troubleshooting-build.md#copy-debug-info) (now with display UUIDs and visible frames, displays left out, device batteries).
8. **Quit HyperSpace** (⌘Q).

## The settings window

- Opened from the menu or by double-clicking the app.
- Built on demand and **destroyed on close**, so it costs nothing while closed. While open, HyperSpace becomes a regular app (Dock icon, ⌘Tab, its own menu bar: `MainMenu`, ⌘W closes the window); when closed it goes back to being a menu bar-only app.
- Styled after macOS System Settings (Liquid Glass), resizable (minimum 720×460, default 900×640, frame remembered):
  - **Sidebar**: a search field (filters pages by name and keywords), then **Input** → Keyboard, Mouse; **Windows** → Tiling, Workspaces, Window Rules, Shortcuts; then **General**.
    Each page has a System Settings–like icon (`SidebarIcon`: white symbol on a rounded square with a soft gradient; the symbol is cropped to its drawn pixels (`SymbolInk`, rendered at 300 pt) and fitted to the same box for every page, so it is optically centered and the same size, and the sidebar does not tint it). Page names, icons, colors and summaries live in `SettingsNavigation.Page`.
  - **Every page starts with a header** (`PageHeader`): the page's icon large, its name and a one-line summary, centered.
  - Main rows carry a small colored icon on the left (`IconLabel`); point values use a slider with the value beside it (`SliderRow`), saved when the slider is released (each save reloads the config and retiles).
- Switching page stops any key/button capture in progress.
- Pages that need Accessibility (everything except Keyboard and General) show a top banner **Accessibility permission needed** with *Open System Settings…* (disappears once granted).
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
- **Layout**: thumbnails of the five layouts (drawn with the current gap, padding and accordion edges), *Gap between windows* and *Margin around the screen* sliders (0–64 pt, step 2).
- **Focus**: *Pointer follows focus*.
- **Accordion**: *Visible edges* slider (`accordionPadding`, 0–120 pt, step 5), always editable, with a to-scale preview; it applies to the Accordion layout and to workspaces stacked with the `accordion` shortcut.

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
These shortcuts are stored as ordinary entries in `keyboard.bindings`. The rows are generated from `TilingModel.pairedShortcuts`/`singleShortcuts`, the single source for titles and actions. Saving edits only the **last** binding of each action (the one the page shows) in place and adds one if there is none; other bindings, including further ones for the same action, stay as they are. Clearing a shortcut removes that last binding only. A shortcut used twice shows a warning (only the last one would work).
During capture key bindings are suspended (so existing shortcuts reach the window) but remaps stay active (so caps lock → ⌃⌥⇧ can be part of a shortcut).

### General
Version (`CFBundleShortVersionString`); **Startup** → *Launch at Login* (`SMAppService`); **Configuration** → file path, *Edit Config…*, *Show in Finder*, status line with the current problem (if any);
**Permission** → Accessibility state (*Granted* or *Open System Settings…*; re-checked when the app becomes active); *Quit HyperSpace* at the bottom.

## Names and icons caching

`TilingModel` caches app names and icons by bundle id (`appInfo`), because rows ask on every redraw and LaunchServices is slow. The list of running apps (`runningApps`) is kept until an app launches or quits, and `MouseModel` builds its preset-name lookup once. The menu bar icon is redrawn only when what it shows changes.
