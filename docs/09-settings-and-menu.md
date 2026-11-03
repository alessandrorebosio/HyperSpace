# 9. Settings window and menu bar

Code: `Settings/`, `App/StatusMenu.swift`, `App/MainMenu.swift`. To see the pages as images (light and dark, two sizes), run the app with `--render-settings` ([page 10](10-permissions-troubleshooting-build.md#screenshots-of-the-settings-window)).

## Menu bar item

The menu is rebuilt only when it opens (`menuNeedsUpdate`).

**Icon / title**
- Normal: the symbol `square.grid.2x2`. A problem shows `exclamationmark.triangle`; a locked keyboard shows `lock`.
- **With more than one workspace configured**, the icon is replaced by an i3bar-style title: the workspace shown on each display left to right (e.g. `1 2 music`), `–` for a display showing none.
  The focused display's workspace sits in a filled rounded box with its name cut out, like i3bar's focused workspace button (also with a single display). A lock prefixes it when the keyboard is locked, `⚠︎` when there is a problem.
  It is drawn as one template image (`StatusMenu.workspacesImage`), so it follows the menu bar's light/dark color like the system items.
- **With tiling off** the icon is drawn dimmed (tooltip "tiling is off"); the item is always there.

**Menu contents** (top to bottom)
1. **Problem** (if any): `Accessibility permission needed` (click: opens the Accessibility pane) or `Config error: …` (click: opens the config file; the title keeps the first line of the message cut at about 48 characters, the tooltip has all of it; the last valid config stays active).
2. **Tiling** (✓ when on): turns the tiling engine on or off. Written to `tiling.enabled` in the config (Settings follows). Off: parked windows come back, apps are no longer observed, windows stay wherever you move them.
3. **Workspaces** — only when more than one workspace is configured and some have windows: one line per workspace with windows, name in bold followed by the icons of its apps (one per app, tiling order), a ✓ on workspaces currently shown,
   a tooltip listing "App — window title". A click shows the workspace (`switchWorkspace`).
4. **Devices** (only when some report a battery): wireless keyboards, mice and trackpads with their battery level (`Peripherals`, from the IOKit registry: `BatteryPercent` on `AppleDeviceManagementHIDEventService` or `IOHIDDevice`), ⚡︎ when charging, orange at 15% or less while not charging. Read when the menu opens; a click opens the Bluetooth settings.
5. **Lock Keyboard** / **Unlock Keyboard** (with the countdown when it unlocks by itself).
6. **Settings…** (⌘,).
7. **Copy Debug Info**: copies the report described in [page 10](10-permissions-troubleshooting-build.md#copy-debug-info) (now with display UUIDs and visible frames, displays left out, device batteries).
8. **Quit HyperSpace** (⌘Q).

## The settings window

- Opened from the menu (**Settings…**, ⌘,) or by double-clicking the app.
- Built on demand and **destroyed on close**, so it costs nothing while closed. While open, HyperSpace becomes a regular app (Dock icon, ⌘Tab, its own menu bar: `MainMenu`, ⌘W closes the window); when closed it goes back to being a menu bar-only app.
- Resizable (minimum 720×460, default 900×640, frame remembered), Liquid Glass sidebar and toolbar on macOS 26.
- Every change is written to `config.json` at once (see [Configuration](02-configuration.md)); a save error replaces the footer of the section it came from. The pages never mention the file, except General.
- Switching page stops any key or button recording in progress.

### Layout

**Sidebar**: **Input** → Keyboard, Mouse; **Windows** → Tiling, Workspaces, Window Rules, Shortcuts; **HyperSpace** → General. There is no search: seven pages.
At the bottom of the sidebar a **status bar** is always in sight: app icon, name and a colored dot with *Running* (green), *Accessibility needed* (orange) or *Needs attention* (red, a config error). A click opens General, where every problem has its fix. The state comes from `GeneralModel.health`, shared with the General page.

**Every page** is a grouped `Form` with the same structure, top to bottom:
1. **Hero** (`PageHero`): the page's icon (44 pt), its name and one line saying what it is for. Tiling puts its on/off switch on the right of the hero, like Wi-Fi in System Settings.
2. **Notices** (`NoticeRow`), only when something stops the page from working: *Accessibility permission needed* (pages that need it: all but Keyboard and General) with *Open System Settings…*, and on the window pages *Tiling is off* with *Turn On*.
3. **Sections**. A list puts its add button in its header, on the right (`SectionHeader` + `AddButton`, or `AddMenu` when the item is picked from a menu, such as an app). An empty list says so with a centered line (`EmptyRow`) instead of showing nothing. The section footer holds one hint (`SectionFooter`), or the last save error (`SettingsFooter`).

### Components (`Settings/Components.swift`)

| Component | What it is |
|---|---|
| `PageIcon` | A white SF Symbol on a colored rounded square with a soft gradient, as in System Settings: 20 pt in the sidebar, 28 pt in notices, 44 pt in heroes. Always a vector in an explicit color, so it is sharp at every size and the sidebar selection does not tint it; every symbol gets the same square, so wide and narrow symbols look the same size. Icons and colors live in `SettingsNavigation.Page`. |
| `KeyCap` | A key or shortcut drawn as a Magic Keyboard key (light face, darker lower edge). Click to record: it gets an accent ring and a red dot until the keys are pressed. |
| `ChoiceMenu` | The small ▾ button next to a key cap, to pick from a list instead of pressing (all keys, mouse actions). |
| `AddButton` / `AddMenu` | Small bordered *+ Add…* button / menu in a section header. |
| `BorderedMenu` | How every menu button is styled. On macOS 14+ the SwiftUI button style: the label is drawn as a vector in its own colors (the older menu styles turn it into a gray, blurry template bitmap). |
| `RemoveButton` | ⊖ at the end of a row, red under the pointer. |
| `WarningBadge` | ⚠︎ with the explanation in its tooltip (a duplicate remap, button or shortcut). |
| `SliderRow` | A value in points: title, slider, value. Shows the value while dragging and saves on release (each save reloads the config and retiles). |
| `AppLabel` | An app's icon (22 pt, high-quality scaling) and name; the bundle id in the tooltip. |
| `RowLabel` | A setting's name with an optional line of explanation under it. |
| `ShortcutGrid` / `ShortcutCap` (`ShortcutsView.swift`) | Shortcuts in aligned columns (a SwiftUI `Grid`) with a caption over each column. A shortcut cap keeps a slot for its warning even when there is none, so the columns stay aligned. |

**Fitting the minimum size**: at 720 pt the detail column is about 500 pt wide. Shortcut caps are 112 pt; remap and mouse rows are a `ViewThatFits` of one line and a two-line version (keys on the first line, the keyboard or the action under them); the layout chooser shrinks its thumbnails and finally wraps.

### Keyboard
- **Keyboard Lock**: the state (*Keyboard active* / *Keyboard locked*, with the countdown) and *Lock Keyboard* / *Unlock*; under it *Unlock automatically* (1/3/5/10 minutes, Never), disabled while locked. ([details](03-keyboard.md#keyboard-lock))
- **Remaps** (*+ Add Remap*): source key cap → target key cap, the ▾ menu with all keys (grouped as in the key table), the keyboard picker (All keyboards, Built-in, All external, or a connected keyboard by name), a duplicate warning, remove.
  Recording: the source takes the first key; the target takes a key, a modifier+key combination, or modifiers alone (hold them together, release). Remaps are suspended while recording. Incomplete rules are not saved. ([details](03-keyboard.md#remapping-from-settings))

### Mouse
- **Scrolling**: *Reverse scroll wheel* (mice with a wheel only).
- **Buttons** (*+ Add Button*): mouse button (with modifiers, recorded by clicking it over the window) → action (keys to send, a ready-made action from ▾, or *Disable Button*). A new mapping goes straight from the button to its action. ([details](04-mouse.md))

### Tiling
- **Hero switch**: tiling on or off (`tiling.enabled`). Off: the other sections are dimmed and kept.
- **Layout**: the five layouts as thumbnails, drawn with the current gap, margin and accordion edges; the chosen one is ringed in the accent color.
- **Spacing**: *Gap between windows* and *Margin around the screen* (0–64 pt, step 2).
- **Accordion**: *Visible edges* (`accordionPadding`, 0–120 pt, step 5) with a to-scale preview; used by the Accordion layout and by workspaces stacked with the `accordion` shortcut.
- **Focus**: *Pointer follows focus*.

### Workspaces
- **Workspaces** (*+ Add Workspace*): a grid with **Name** (renames are saved 0.5 s after typing and carry the app rules along), **Show workspace** and **Move window here** shortcuts, remove.
- **App Rules** (*+ Add App*: running apps, or *Other App…*; needs a workspace first): app → the workspace its new windows open in.

### Window Rules
- **Floating**: apps whose windows are never tiled (*All windows*) and title rules (an app, or *Any app*, + *Title contains “…”*). The last row writes a new rule: app picker, optional title, *+ Add*. ([details](06-tiling.md#floating-windows-and-rules))
- **Scratchpad Apps** (*+ Add App*): a grid with **App**, **Show / hide** and **To tiling and back** shortcuts, remove. Adding an app starts recording its first shortcut. ([details](08-scratchpad.md))

### Shortcuts
Click a cap and press the keys; Esc cancels, Delete clears.
- **Focus & Move**: Left, Down, Up, Right × *Focus* / *Move window* (`focus …` / `swap …`).
- **Resize**: Width, Height × *Smaller* / *Larger* (`resize width -50` / `+50` …).
- **Displays**: *Focus other display* (`focus-display`), *Move workspace to other display* (`move-workspace-to-display`).
- **More**: *Previous workspace* (`workspace back-and-forth`), *Toggle floating* (`float`), *Stack windows as an accordion* (`accordion`), *Move window to or from the scratchpad* (`move-to-scratchpad`).

These shortcuts are ordinary entries of `keyboard.bindings`. The rows come from `TilingModel.pairedShortcuts` / `singleShortcuts`, the single source for titles and actions. Saving edits only the **last** binding of each action (the one the page shows) in place, and adds one if there is none; other bindings, even more for the same action, stay as they are. Clearing a shortcut removes that last binding only. A shortcut used twice gets a warning (only the last one works).
While recording, key bindings are suspended (so an existing shortcut reaches the window) but remaps stay on (so caps lock → ⌃⌥⇧ can be part of a shortcut).

### General
- **App card**: icon, name, version (`CFBundleShortVersionString`) and the state as a colored pill.
- **Accessibility permission needed** notice while it is missing.
- **Startup**: *Launch at login* (`SMAppService`).
- **Configuration**: the file path (selectable), the current problem if any, *Edit Config…*, *Show in Finder*.
- **Permission**: Accessibility, *Allowed* or *Open System Settings…* (checked again whenever the app becomes active).
- **Quit HyperSpace**.

### Files

| File | Contents |
|---|---|
| `SettingsWindowController.swift` | `SettingsNavigation` (pages: names, icons, colors, summaries), `SettingsRoot` (sidebar and status bar), the window controller |
| `Components.swift` | The shared components above |
| `RemapView.swift`, `MouseView.swift` | Keyboard and Mouse pages |
| `TilingView.swift` | Tiling page, layout thumbnails, accordion preview, `TilingOffNotice` |
| `WorkspacesView.swift`, `WindowRulesView.swift`, `ShortcutsView.swift` | The other window pages |
| `GeneralView.swift` | `GeneralModel` and the General page |
| `RemapModel.swift`, `MouseModel.swift`, `TilingModel.swift` | State, key/button recording and saving; the views only call them |
| `SettingsSnapshot.swift` | `--render-settings` |

## Names and icons caching

`TilingModel` caches app names and icons by bundle id (`appInfo`), because rows ask on every redraw and LaunchServices is slow. The list of running apps (`runningApps`) is kept until an app launches or quits, and `MouseModel` builds its preset-name lookup once. The menu bar icon is redrawn only when what it shows changes.
