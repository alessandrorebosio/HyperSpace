# 1. Overview and architecture

## Source layout

```
Sources/HyperSpace/
├── main.swift          entry point: NSApplication + AppDelegate (or the `--render-settings` screenshots, no AppDelegate)
├── App/                AppDelegate, StatusMenu (menu bar), MainMenu (app menu), WorkspaceOverview
├── Core/               config, actions, event tap, key codes, permissions
├── Keyboard/           HID remaps, keyboard lock, caps lock, synthetic keys, layout
├── Mouse/              DragController (bridge between tap and window manager), EdgeSliders + EdgeSliderTracker (trackpad edges)
├── Settings/           SwiftUI settings window (models + views)
└── Tiling/             WindowManager, layouts, workspaces, AX, scratchpad
Tests/HyperSpaceTests/  Swift Testing tests, one file per area
Resources/              Info.plist, AppIcon.icns (drawn by scripts/make-icon.py)
.github/                CI: build, test and settings screenshots on macOS
```

### `App/`
- **`AppDelegate`** wires everything: owns `ConfigStore`, `KeyboardRemapper`, `WindowManager`, `ActionRunner`, `EventTap`,
  `SettingsWindowController`, `StatusMenu`. Requests Accessibility at launch, applies configs, builds the *Copy Debug Info* report, and on quit
  resets the keyboards, saves state and brings parked windows back. It detects a login launch (`launchedAtLogin`) so apps macOS reopens by itself
  do not make you jump between workspaces.
- **`StatusMenu`**: menu bar icon and menu (rebuilt only when opened).
- **`MainMenu`**: the app's menu bar while the Settings window is open (⌘W, ⌘Q, ⌘, copy/paste).
- **`WorkspaceOverview`**: the panel of every workspace with its apps and shortcut, shown while `workspace-overview` is held.

### `Core/`
- **`Config.swift`**: `RawConfig` (the JSON as written) → `Config` (validated and compiled: `remaps`, `TapConfig`, `TilingConfig`). `TapConfig` holds the lookup tables used by the event tap.
- **`DefaultConfig.swift`**, **`ConfigStore.swift`** (load, watch, reload), **`ConfigWriter.swift`** (rewrites the file for the settings UI).
- **`Action.swift`** (text → `Action`), **`ActionRunner.swift`** (runs on the main thread), **`SystemActions.swift`** (`Navigation`, `SystemAction`, `MediaKey`), **`Pointer.swift`** (pointer location, warp, synthetic clicks), **`AppLauncher.swift`**, **`Peripherals.swift`** (battery of wireless keyboards, mice, trackpads).
- **`Log.swift`** (`log`, `AppInfo`), **`Extensions.swift`** (`nilIfEmpty`, `clamped`), **`Scheduling.swift`** (`asyncAfter(delays:)`, `Debouncer` for "last one wins after a pause", `Coalescer` for "one run per burst").
- **`EventTap.swift`**: the single active `CGEventTap`, shared by keyboard and mouse.
- **`KeyCodes.swift`**: key table (name ↔ virtual keycode ↔ HID usage; the modifier key codes come from it). **`Modifiers.swift`**: `Modifiers` and `KeyCombo` with the one parser for modifier lists (also used by `RemapTarget`), and the conversions from `CGEventFlags` and `NSEvent.ModifierFlags`.
- **`RemapTarget.swift`**: remap destination (single key or combination) and `CarrierPool`.
- **`Permissions.swift`**: Accessibility check, opening the settings pane, and the words for a missing permission.
- **`DeviceWatcher.swift`**: IOKit match notifications for keyboards and trackpads plugged in.

### `Keyboard/`
`KeyboardRemapper` (writes `UserKeyMapping` per keyboard via IOKit), `KeyEmitter` (synthetic key events), `KeyboardLayout` (maps symbols to the active layout),
`CapsLock` (turns caps lock off), `KeyboardLock` (lock duration, stored in `UserDefaults`).

### `Mouse/`
`DragController`: carries modifier+drag from the tap thread to the main thread, keeping only the latest position.
`EdgeSliders`: the trackpad edge sliders, from MultitouchSupport's frames (on its own thread) through `EdgeSliderTracker` to volume and brightness keys posted on the main thread ([details](04-mouse.md#trackpad-edge-sliders-trackpad)).

### `Tiling/`
- **`WindowManager`** (class, stored state, command scope, lifecycle, layout) with its extensions in separate files: **`WindowManager+Workspaces`** (displays, switching, focus following, menu summaries), **`+Commands`** (focus, swap, resize, float, accordion, displays), **`+Tracking`** (finding, adopting and forgetting windows), **`+MouseDrag`** (modifier-drag to move and resize), **`+Scratchpad`**, **`+SavedState`**, **`+Debug`** (the report). **`ManagedWindow`** holds `ManagedWindow`; **`WorkspaceSummary`** holds `WorkspaceSummary` (with its per-app list) and `WorkspaceBar`.
- **`Layout`** (layout math for `tall`/`wide`/`columns`/`monocle`/`accordion`, neighbour search, `CGRect.centered`), **`ScreenInfo`** (a display's frames, UUID, relocating and centering), **`ColumnLayout`** (i3-style columns).
- **`AppWatcher`** (one `AXObserver` per app), **`AXQueues`** (per-app serial queues), **`AX`** (Accessibility API helpers; `AX.probe` and `AX.frame` read their attributes in one round trip).
- **`DisplayMonitor`** (displays asleep / on another input left out after 60 s), **`FocusAnchor`** (clicks the desktop of an empty workspace's display, so the Finder becomes the active app there and that display the active one).
- **`WorkspaceState`** (saved state and `WorkspaceRestorer`), **`LaunchTracker`** (which workspace an app was opened from).

### `Settings/`
SwiftUI window with a sidebar: `SettingsWindowController`, one model per area (`KeyboardModel`, `MouseModel`, `TrackpadModel`, `TilingModel`, `GeneralModel`, each in its own file), one view file per page (`KeyboardView`, `MouseView`, `TrackpadView`, `TilingView`, `WorkspacesView`, `WindowRulesView`, `ShortcutsView`, `GeneralView`), and the shared components in `Components.swift`. The models hold the state, record keys and buttons and save; the views only call them. The config file is read once for all of them when the window opens; after that each model follows it (`ConfigStore.didLoad`, `SyncedSlice` in `FileSync.swift`): when its part of the file changed elsewhere it reloads, and it writes only the keys that changed. A `@Published` assignment redraws every view observing the model, equal value or not, so setters assign only changes, and state that changes often (the unlock countdown, the floating rule being typed) lives in its own small `ObservableObject`; shortcut caps take values and are `Equatable`. `SettingsSnapshot` draws the pages to PNG files for `--render-settings`, without starting anything else. See [page 9](09-settings-and-menu.md).

## Threads and queues

| Thread / queue | What it does |
|---|---|
| **Event tap thread** (`HyperSpace.EventTap`, QoS `userInteractive`) | Runs the single `CGEventTap`. Owns all tap state. The hot path reads plain arrays and takes no locks of its own; the only allocation is the `CGEvent` a carrier posts (`DragController` does take a short lock to hand over the drag point). |
| **MultitouchSupport thread** (only with the edge sliders on) | Trackpad frames: `EdgeSliderTracker` runs there behind a lock; only notches and the start or end of a hold go to the main thread. |
| **Main thread** | Everything else: window state, actions, AX reads, `NSWorkspace`/AX notifications, UI. |
| **`AXQueues` queues** (one per app, `HyperSpace.AX.<pid>`, QoS `userInteractive`) | AX writes (move, resize, park, focus) and the batched reads that tracking windows needs (`AX.probe` of every window of an app). A slow app only makes itself wait. |
| **`HyperSpace.state` queue** (QoS `utility`) | Writes `workspaces.json` off the main thread (the state, titles included, is built on the main thread from the titles cached on the windows). |

Communication rules:

- **Config → tap**: `EventTap.apply(_:)` hands the new `TapConfig` to the tap thread with `CFRunLoopPerformBlock`, unless it equals the one the tap already has. On the way, on the main thread, the keys of combinations are translated to the active keyboard layout (`TapConfig.translated`, see [Keyboard](03-keyboard.md#keyboard-layouts-and-symbols)); the tap thread never asks the input sources.
- **Tap → actions**: an action triggered by the tap runs with `DispatchQueue.main.async`.
- **Tap → drag**: `DragController` keeps only the latest point behind an `OSAllocatedUnfairLock` and schedules at most one pending main-thread update: no backlog even with a 1000 Hz mouse.
- **Main → apps**: AX writes go through `AXQueues.perform(pid)`; window discovery reads through `AXQueues.read(pid, …)`, whose result comes back to the main thread. State stays on the main thread, as do the few reads a command needs at once. Modifier + drag writes (focus, move, resize) go through the same queues, one write in flight with only the newest point waiting.
- AX timeout is 0.5 s (on the system-wide element and on every `AppWatcher`) instead of the 6 s default.

## Data flow: from config to features

```
config.json ──(ConfigStore: kqueue, 0.15 s debounce)──▶ Config.load
      │                                                   │ error → StatusMenu.problem (previous config stays)
      ▼ success
AppDelegate.apply
  ├─ KeyboardRemapper.apply(config.remaps)      always (no permission needed)
  ├─ CapsLock.turnOff()                          if caps lock is remapped
  └─ if Accessibility granted → applyTrusted:
        ├─ EventTap.apply(config.tap)            binding/button tables, carriers, scroll, drag (skipped when unchanged)
        └─ WindowManager.apply(config.tiling)    layout, gaps, rules, workspaces, scratchpad (floating rules re-checked against the titles kept from title notifications)
```

- **Shortcuts** (`keyboard.bindings`, workspace `switch`/`move`, mouse buttons) are compiled into `[Int16]` tables indexed by `keyCode << 4 | modifiers` (and `button << 4 | modifiers`); each entry is an index into `TapConfig.actions`.
- `ConfigWriter` writes the file only when the text really changes, so a no-op edit in Settings does not reload the config.
- A **combination** as a remap target (`caps_lock → hyper`) becomes a *carrier* (see [Keyboard](03-keyboard.md)).
- The tap **subscribes only to the events in use** (`TapConfig.eventMask`): with an empty config no tap is installed at all.
- Without Accessibility `applyTrusted` is not called: only HID remaps are active. A 1 s timer polls until the permission arrives, then applies the already-loaded config.
- A tap disabled by the system (`tapDisabledByTimeout`/`ByUserInput`) is re-enabled in the callback.
- Events HyperSpace generates (synthetic keys, the `click` and `navigate` actions, the click on an empty display's desktop) are stamped with `EventTap.syntheticMarker` (`0x48595045`) in `eventSourceUserData`; the tap lets them through untouched.

## Events the tap subscribes to

| Event | When |
|---|---|
| `keyDown`/`keyUp` | there are carriers, caps lock is remapped, or at least one key binding exists |
| `flagsChanged` | caps lock is remapped |
| left/right/other mouse clicks | a modifier-only carrier exists (held modifiers also apply to clicks) |
| `otherMouseDown/Up` | at least one button is mapped |
| `scrollWheel` | `reverseScroll` is on |
| `left/rightMouseDown/Dragged/Up` | `dragModifier` is set |
| all keys + `NX_SYSDEFINED` | only while the keyboard is locked |

Mouse movement is intercepted only with the trackpad edge sliders on: every move is let through untouched except while a slider holds the pointer.

## Window manager: how it reacts

- **Event-driven**: one `AXObserver` per app (`windowCreated`, `windowMiniaturized`/`Deminiaturized`, `focusedWindowChanged`, and per window `UIElementDestroyed`, `moved`, `resized`, `titleChanged`) plus `NSWorkspace` notifications (launch, terminate, activate, hide/unhide, Space change) and screen-parameter changes. The only polling is `DisplayMonitor` (every 5 s while tiling runs; with one display each poll is a single cheap call).
- Bursts of events are coalesced into one retile (30 ms delay).
- Visibility and position of windows come from `CGWindowListCopyWindowInfo` without titles (so no Screen Recording). **A command reads the window list, the displays (`NSScreen`) and the focused window (a synchronous AX call) once**: the first read is kept for the whole command (`WindowManager.enterScope`/`leaveScope`, nested commands share it) and every function it calls reuses it, so a workspace switch costs one `CGWindowList` call, one display read and one AX read. Outside a command every read is fresh; a newly tracked window drops the cached window list.
- A window is moved only if its position really differs from the target (1 pt tolerance).
- See [Tiling](06-tiling.md), [Workspaces and displays](07-workspaces-and-displays.md) and [Scratchpad](08-scratchpad.md).

## Startup and quit

1. `applicationWillFinishLaunching`: reads from the Apple Event whether the app was launched at login.
2. `applicationDidFinishLaunching`: menus, status item, observers; requests Accessibility (with prompt); `ConfigStore.start()` (writes the default config if missing, loads it, watches it).
3. After a login launch, `revealAfter` (90 s) stops apps with a rule from taking you to their workspace.
4. On quit (`applicationWillTerminate`): `remapper.reset()` (removes HID remaps), `windowManager.saveState()`, `restoreHiddenWindows()`.

Double-clicking the already-running app opens the settings (`applicationShouldHandleReopen`).
