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
- **VoiceOver** reads what the icon shows, then the lock and the problem: "HyperSpace, keyboard locked, needs attention", "Workspace web, needs attention" (`StatusMenu.accessibilityDescription`).
- **Two problems, tracked apart** (`AppDelegate` sets `StatusMenu.permissionMissing` and `configError`; `StatusMenu.problems` derives the rest): the missing permission lasts until it is granted, a config error until the file loads again. Fixing one never hides the other. The icon, the menu rows and the config error on Settings' General page all come from these two.

**Menu contents** (top to bottom)
1. **Problems** (if any), one row each: `Accessibility permission needed` (click: opens the Accessibility pane) and/or `Config error: …` (click: opens the config file; the title keeps the first line of the message cut at about 48 characters, the tooltip has all of it; the last valid config stays active). When *Tiling* cannot be saved because the file has a syntax error, the parse error already shown (with its line and column) stays.
2. **Tiling** (✓ when on): turns the tiling engine on or off. Written to `tiling.enabled` in the config (Settings follows). Off: parked windows come back, apps are no longer observed, windows stay wherever you move them.
3. **Workspaces** — only when more than one workspace is configured and some have windows: one line per workspace with windows, name in bold followed by the icons of its apps (one per app, tiling order), a ✓ on workspaces currently shown,
   a tooltip listing "App — window title". A click shows the workspace (`switchWorkspace`).
4. **Devices** (only when some report a battery): wireless keyboards, mice and trackpads with their battery level (`Peripherals`, from the IOKit registry: `BatteryPercent` on `AppleDeviceManagementHIDEventService` or `IOHIDDevice`), ⚡︎ when charging, orange at 15% or less while not charging. Read when the menu opens; a click opens the Bluetooth settings.
5. **Lock Keyboard** / **Unlock Keyboard** (with the countdown when it unlocks by itself). *Lock Keyboard* is disabled while the Accessibility permission is missing, as in Settings: without the event tap a lock would only claim to be on.
6. **Settings…** (⌘,).
7. **Copy Debug Info**: copies the report described in [page 10](10-permissions-troubleshooting-build.md#copy-debug-info) (now with display UUIDs and visible frames, displays left out, device batteries).
8. **Quit HyperSpace** (⌘Q).

## The settings window

- Opened from the menu (**Settings…**, ⌘,) or by double-clicking the app.
- Built on demand and **destroyed on close**, so it costs nothing while closed. While open, HyperSpace becomes a regular app (Dock icon, ⌘Tab, its own menu bar: `MainMenu`, ⌘W closes the window); when closed it goes back to being a menu bar-only app.
- Resizable (minimum 720×460, default 900×640: `SettingsWindowController.minimumSize` / `defaultSize`, also the snapshot sizes; frame remembered), Liquid Glass sidebar and toolbar on macOS 26.
- Every change is written to `config.json` at once (see [Configuration](02-configuration.md)). Only the keys a change touches are written: an option never set stays out of the file, and a value the page rounds or cannot show stays as written until it is changed here. Empty lists are left out of the file.
- **Save errors**: a change that cannot be saved shows a red *Changes not saved* notice at the top of the page, under the permission notice, with *Edit Config…* (`SaveErrorNotice`, observing the model's `SaveStatus` alone). It stays until a save succeeds, or, for a syntax error, until the file parses again. A file with a syntax error is never written. Settings opened on such a file shows every page empty with that notice; fixing the file loads the pages.
- **Following the file**: while the window is open, a change made elsewhere (an editor, the menu bar's *Tiling* item, the `tiling` action) shows on the page it belongs to. While a shortcut is recorded, a name typed or a slider moved there, the reload waits (`FileSync.reloadDeferred`) and is done when that edit ends, and always before the next save, so a save never writes back a list the file has changed since. Rows keep their identity across reloads while they mean the same (`reusedIDs`): the rows that did not change are not rebuilt, and a focused name field keeps its focus. Gap and padding read from the file are clamped to 0–64 like the sliders; a title rule listed twice shows once; a workspace with no (or an empty) name shows its position, as the config reads it.
- **Incomplete rows**, one rule on every page: a new row records its parts one after the other (a remap's key then its target, a mouse button then its action, a scratchpad app's show/hide shortcut). If the recording ends with the row still incomplete (Esc where it cancels, the cap clicked again, another page, the window closed, or a scratchpad app whose shortcuts are all cleared), the row goes: it was never saved. On the Keyboard page Esc is a key like any other (it can be remapped), so there only clicking the cap again cancels.
- Switching page stops any key or button recording in progress.
- The pages never mention the file, except General and the save error notice.

### Layout

**Sidebar**: **Input** → Keyboard, Mouse, Trackpad; **Windows** → Tiling, Workspaces, Window Rules, Shortcuts; **HyperSpace** → General. There is no search: eight pages.
At the bottom of the sidebar a **status bar** is always in sight: app icon, name and a colored dot with *Running* (green), *Accessibility needed* (orange) or *Needs attention* (red, a config error). It only shows the state: a click does nothing (every problem has its fix on General). The state comes from `GeneralModel.health`, shared with the General page. A *Launch at login* failure is not part of it: it shows under that switch only.
The login item and the permission are checked when the window opens and whenever the app becomes active; a config load only refreshes the config error (`GeneralModel.refreshConfigProblem`), so the app's own saves cost no system call.

**Every page** is a grouped `Form` with the same structure, top to bottom:
1. **Hero** (`PageHero`): the page's icon (44 pt), its name and one line saying what it is for. Tiling puts its on/off switch on the right of the hero, like Wi-Fi in System Settings.
2. **Notices** (`NoticeRow`), only when something stops the page from working: *Accessibility permission needed* (every page but General, which has its own; on Keyboard it says that 1:1 remaps already work) with *Open System Settings…*, *Changes not saved* (`SaveErrorNotice`) with *Edit Config…*, and on the window pages *Tiling is off* with *Turn On*.
3. **Sections**. A list puts its add button in its header, on the right (`SectionHeader` + `AddButton`, or `AddAppMenu` when the item is an app picked from a menu). An empty list says so with a centered line (`EmptyRow`) instead of showing nothing, always in the form "No X: what happens without any". The section footer holds one hint (`SectionFooter`); the lists of shortcut caps end it with the same recording hint, `ShortcutRecorder.hint`.

### Components (`Settings/Components.swift`)

| Component | What it is |
|---|---|
| `PageIcon` | A white SF Symbol on a colored rounded square with a soft gradient, as in System Settings: 20 pt in the sidebar, 28 pt in notices, 44 pt in heroes. Always a vector in an explicit color, so it is sharp at every size and the sidebar selection does not tint it; every symbol gets the same square, so wide and narrow symbols look the same size. Icons and colors live in `SettingsNavigation.Page`. |
| `KeyCap` | A key or shortcut drawn as a Magic Keyboard key (light face, darker lower edge). Click to record: it gets an accent ring and a red dot until the keys are pressed. |
| `ChoiceMenu` / `GroupedChoiceMenu` | The small ▾ button next to a key cap, to pick from a list instead of pressing. `GroupedChoiceMenu` holds a fixed list in submenus (all keys on Keyboard, the ready-made actions on Mouse) and is rebuilt only for another rule. |
| `AddButton` / `AddAppMenu` | Small bordered *+ Add…* button / *+ Add App* menu (running apps, then *Other App…*) in a section header. |
| `AppRuleRow` | A rule about an app: icon and name (or *Any app*), what the rule does, remove (App Rules, Floating). |
| `SaveErrorNotice` | The *Changes not saved* notice, observing the model's `SaveStatus` alone. |
| `BorderedMenu` | How every menu button is styled. On macOS 14+ the SwiftUI button style: the label is drawn as a vector in its own colors (the older menu styles turn it into a gray, blurry template bitmap). |
| `RemoveButton` | ⊖ at the end of a row. |
| `WarningBadge` | ⚠︎ with the explanation in its tooltip (a duplicate remap, button or shortcut). |
| `SliderRow` | A value in points: title, slider, value. Shows the value while dragging and saves on release (each save reloads the config and retiles); a change made without dragging (arrow keys, VoiceOver) is saved 0.6 s after the last one. |
| `AppLabel` | An app's icon (22 pt, high-quality scaling) and name; the bundle id in the tooltip. |
| `RowLabel` | A setting's name with an optional line of explanation under it. |
| `ShortcutGrid` / `ShortcutCap` (`ShortcutsView.swift`) | Shortcuts in aligned columns (a SwiftUI `Grid`) with a caption over each column. A shortcut cap keeps a slot for its warning even when there is none, so the columns stay aligned. |

**Fitting the minimum size**: at 720 pt the detail column is about 500 pt wide. Shortcut caps are 112 pt; remap and mouse rows are a `ViewThatFits` of one line and a two-line version (keys on the first line, the keyboard or the action under them); the layout chooser shrinks its thumbnails and finally wraps.

### Keyboard
- **Keyboard Lock**: the state (*Keyboard active* / *Keyboard locked*, with the countdown) and *Lock Keyboard* / *Unlock Keyboard* (the menu bar's words); under it *Unlock automatically* (1/3/5/10 minutes, Never), disabled while locked. ([details](03-keyboard.md#keyboard-lock))
- **Remaps** (*+ Add Remap*): source key cap → target key cap, the ▾ menu with all keys (grouped as in the key table), the keyboard picker (All keyboards, Built-in, All external, or a connected keyboard by name), a duplicate warning, remove.
  Recording: the source takes the first key; the target takes a key, a modifier+key combination, or modifiers alone (hold them together, release). A new remap goes straight from its key to its target. Every key is recorded, Esc included: click the cap again to cancel (a new remap left incomplete then goes). Remaps and key bindings are suspended while recording. Picking a target from ▾ ends the recording of the target. *Lock Keyboard* is disabled while the Accessibility permission is missing. ([details](03-keyboard.md#remapping-from-settings))

### Mouse
- **Scrolling**: *Reverse scroll wheel* (mice with a wheel only).
- **Buttons** (*+ Add Button*): mouse button (with modifiers, recorded by clicking it over the window) → action (keys to send, a ready-made action from ▾, or *Disable Button*). A new mapping goes straight from the button to its action. Recording the action: Esc cancels (a new mapping without an action then goes), Delete disables the button; key bindings are suspended meanwhile. A rule whose modifiers do not parse is only a duplicate of one with the same unparsed text. ([details](04-mouse.md))

### Trackpad
- **Edges**: the *Edge sliders* switch and, for each edge (left, right, top, bottom), a `SettingRow` with Volume, Display brightness, Seek or Nothing (dimmed while the switch is off). The sliders start without waiting for the permission, but holding the pointer still needs the event tap: an Accessibility notice says so while it is missing. ([details](04-mouse.md#trackpad-edge-sliders-trackpad))
- **Corners**: per corner, the action of a double tap there: a ready-made action (the Mouse page's list) or Nothing. ([details](04-mouse.md#trackpad-corners))

### Tiling
- **Hero switch**: tiling on or off (`tiling.enabled`). Off: the other sections are dimmed and kept.
- **Layout**: the five layouts as thumbnails, drawn with the current gap, margin and accordion edges; the chosen one is ringed in the accent color.
- **Spacing**: *Gap between windows* and *Margin around the screen* (0–64 pt, step 2).
- **Accordion**: *Visible edges* (`accordionPadding`, 0–200 pt, step 5) with a to-scale preview; used by the Accordion layout and by workspaces stacked with the `accordion` shortcut.
- **Focus**: *Pointer follows focus* (to the display that gets the focus, and to its middle on a workspace switch).

### Workspaces
- **Workspaces** (*+ Add Workspace*): a grid with **Name** (renames are saved 0.5 s after typing; an empty name or one another workspace has gets a warning and is not saved, the last valid one is kept; app rules follow their workspace whatever its name), **Show workspace** and **Move window here** shortcuts, **Display** (*Any display*; by position *Main display*, *Second display*, *Third display* (one more per display beyond three), written as `main`, `2`, `3`: whichever monitor is there; then, after a separator, a connected monitor by name; pins the workspace there), remove.
  When the window is too narrow for the grid (`ViewThatFits`), each workspace takes two lines: name, display and remove, then its two shortcuts. The display menu is at most 160 points wide and truncates a long name (a display not connected) instead of widening the page.
  What is typed in a name lives in that row's own `NameDraft`, so a keystroke redraws the field and its warning, not the page.
  Removing a workspace that has shortcuts, app rules or a display pin asks first, listing what goes with it (`TilingModel.removalLosses`); an empty one goes at once. Its app rules leave the page with it, not only the file.
- **App Rules** (*+ Add App*: running apps, or *Other App…*; needs a workspace first): app → the workspace its new windows open in. The app menus follow apps launching and quitting while the window is open (`AppLauncher.runningAppsDidChange`, published as `TilingModel.runningApps`).

### Window Rules
- **Floating**: apps whose windows are never tiled (*All windows*) and title rules (an app, or *Any app*, + *Title contains “…”*). The last row writes a new rule: app picker, optional title, *+ Add*; a rule already in the list cannot be added again (⚠︎ and *Add* disabled). ([details](06-tiling.md#floating-windows-and-rules))
- **Scratchpad Apps** (*+ Add App*): a grid with **App**, **Show / hide** and **To tiling and back** shortcuts, remove. Adding an app starts recording its first shortcut; if that recording ends any other way than with keys, or both shortcuts are cleared, the app goes off the list again (an app without shortcuts is not saved). ([details](08-scratchpad.md))

### Shortcuts
Click a cap and press the keys; Esc cancels, Delete clears.
- **Focus & Move**: Left, Down, Up, Right × *Focus* / *Move window* (`focus …` / `swap …`).
- **Resize**: Width, Height × *Smaller* / *Larger* (`resize width -50` / `+50` …).
- **Displays**: *Focus other display* (`focus-display`), *Move workspace to other display* (`move-workspace-to-display`).
- **More**: *Previous workspace* (`workspace back-and-forth`), *Show workspaces while held* (`workspace-overview`), *Toggle floating* (`float`), *Stack windows as an accordion* (`accordion`), *Move window to or from the scratchpad* (`move-to-scratchpad`).

These shortcuts are ordinary entries of `keyboard.bindings`. The rows come from `TilingModel.pairedShortcuts` / `singleShortcuts`, the single source for titles and actions. Saving edits only the **last** binding of each action (the one the page shows) in place, and adds one if there is none; other bindings, even more for the same action, stay as they are. Clearing a shortcut removes that last binding only. A shortcut used twice gets a warning (only the last one works), counting every binding of `keyboard.bindings`, also those no page shows (`launch …`, an earlier binding of the same action: `TilingModel.otherBindingKeys`).
While recording, key bindings are suspended (so an existing shortcut reaches the window) but remaps stay on (so caps lock → ⌃⌥⇧ can be part of a shortcut).

### General
- **App card**: icon, name, version (`CFBundleShortVersionString`) and the state as a colored pill.
- **Accessibility permission needed** notice while it is missing.
- **Startup**: *Launch at login* (`SMAppService`); a failure to change it shows in red under the switch.
- **Configuration**: the file path (selectable), the config error if any (in red, like every error), *Edit Config…*, *Show in Finder*, *Move…* (a save panel: the file goes there and is read from there from now on) and *Use Another File…* (an open panel: an existing file is read as it is). The pages, the menu bar and the watcher follow the new file at once (`ConfigStore.relocate`); a failure shows in red under the path. See [Configuration](02-configuration.md).
- **Permission**: Accessibility, *Allowed* or *Open System Settings…* (checked again whenever the app becomes active).
- **Quit HyperSpace**.

### Files

| File | Contents |
|---|---|
| `SettingsWindowController.swift` | `SettingsNavigation` (pages: names, icons, colors, summaries), `SettingsRoot` (sidebar and status bar), the window controller |
| `Components.swift` | The shared components above |
| `ShortcutRecorder.swift` | `ShortcutRecorder`: the capture of the Keyboard, Mouse and window pages (local event monitor, key bindings / mouse buttons / remaps suspended meanwhile, Esc alone cancels and Delete alone clears a shortcut); `LocalEventMonitor`; `CaptureModel` (the key-cap click shared by the three models: `toggleCapture`; each model declares its conformance in its own file) |
| `FileSync.swift` | How the models follow the file: `SyncedSlice` (the part of the file a model shows), `FileSync` (that slice, the values as loaded, the deferred reload, the `SaveStatus`), `FileBackedModel` (what `SettingsModels` calls on every model: reload, stop capture, close), `assignIfChanged`, `reusedIDs` |
| `KeyboardView.swift`, `MouseView.swift`, `TrackpadView.swift` | Keyboard, Mouse and Trackpad pages |
| `TilingView.swift` | Tiling page, layout thumbnails, accordion preview, `TilingOffNotice` |
| `WorkspacesView.swift`, `WindowRulesView.swift`, `ShortcutsView.swift` | The other window pages |
| `GeneralView.swift` | The General page |
| `KeyboardModel.swift`, `MouseModel.swift`, `TrackpadModel.swift`, `TilingModel.swift`, `GeneralModel.swift` | State, key/button recording and saving; the views only call them (`UnlockCountdown`, `FloatingRuleDraft` and `NameDraft` are in their model's file) |
| `SettingsSnapshot.swift` | `--render-settings` |

## Names and icons caching

`AppLauncher` caches app names and icons by bundle id (`appInfo`), because rows ask on every redraw and LaunchServices is slow. The list of running apps (`runningApps`) is kept until an app launches or quits (then `runningAppsDidChange` is posted), and `MouseModel` builds its preset-name lookup once. The menu bar icon is redrawn only when what it shows changes.
