# 1. Overview and architecture

## Source layout

```
Sources/HyperSpace/
├── main.swift          entry point: NSApplication + AppDelegate
├── App/                AppDelegate, StatusMenu (menu bar), MainMenu (app menu)
├── Core/               config, actions, event tap, key codes, permissions
├── Keyboard/           HID remaps, keyboard lock, caps lock, synthetic keys, layout
├── Mouse/              DragController (bridge between tap and window manager)
├── Settings/           SwiftUI settings window (models + views)
└── Tiling/             WindowManager, layouts, workspaces, AX, scratchpad
Tests/HyperSpaceTests/  Swift Testing tests (one file)
Resources/              Info.plist, AppIcon.icns
```

### `App/`
- **`AppDelegate`** wires everything: owns `ConfigStore`, `KeyboardRemapper`, `WindowManager`, `ActionRunner`, `EventTap`,
  `SettingsWindowController`, `StatusMenu`. Requests Accessibility at launch, applies configs, builds the *Copy Debug Info* report, and on quit
  resets the keyboards, saves state and brings parked windows back. It detects a login launch (`launchedAtLogin`) so apps macOS reopens by itself
  do not make you jump between workspaces.
- **`StatusMenu`**: menu bar icon and menu (rebuilt only when opened).
- **`MainMenu`**: the app's menu bar while the Settings window is open (⌘W, ⌘Q, ⌘, copy/paste).

### `Core/`
- **`Config.swift`**: `RawConfig` (the JSON as written) → `Config` (validated and compiled: `remaps`, `TapConfig`, `TilingConfig`). `TapConfig` holds the lookup tables used by the event tap.
- **`DefaultConfig.swift`**, **`ConfigStore.swift`** (load, watch, reload), **`ConfigWriter.swift`** (rewrites the file for the settings UI).
- **`Action.swift`** (text → `Action`), **`ActionRunner.swift`** (runs on the main thread), **`SystemActions.swift`** (`Navigation`, `SystemAction`, `MediaKey`, `Pointer`), **`AppLauncher.swift`**.
- **`EventTap.swift`**: the single active `CGEventTap`, shared by keyboard and mouse.
- **`KeyCodes.swift`**: key table (name ↔ virtual keycode ↔ HID usage), `Modifiers`, `KeyCombo`.
- **`RemapTarget.swift`**: remap destination (single key or combination) and `CarrierPool`.
- **`Permissions.swift`**: Accessibility check and opening the settings pane.

### `Keyboard/`
`KeyboardRemapper` (writes `UserKeyMapping` per keyboard via IOKit), `KeyEmitter` (synthetic key events), `KeyboardLayout` (maps symbols to the active layout),
`CapsLock` (turns caps lock off), `KeyboardLock` (lock duration, stored in `UserDefaults`).

### `Mouse/`
`DragController`: carries modifier+drag from the tap thread to the main thread, keeping only the latest position.

### `Tiling/`
- **`WindowManager`** (~1400 lines): state of windows, workspaces, displays, scratchpad; commands; save/restore.
- **`Layout`** (layout math for `tall`/`wide`/`columns`/`monocle`, neighbour search, `ScreenInfo`), **`ColumnLayout`** (i3-style columns).
- **`AppWatcher`** (one `AXObserver` per app), **`AXWriter`** (per-app serial queues), **`AX`** (Accessibility API helpers).
- **`WorkspaceState`** (saved state and `WorkspaceRestorer`), **`LaunchTracker`** (which workspace an app was opened from).

### `Settings/`
SwiftUI window with a sidebar: `SettingsWindowController`, one model per area (`RemapModel`, `MouseModel`, `TilingModel`, `GeneralModel`), the matching views, and `Components.swift`. See [page 9](09-settings-and-menu.md).

## Threads and queues

| Thread / queue | What it does |
|---|---|
| **Event tap thread** (`HyperSpace.EventTap`, QoS `userInteractive`) | Runs the single `CGEventTap`. Owns all tap state. No allocation and no locks on the hot path. |
| **Main thread** | Everything else: window state, actions, AX reads, `NSWorkspace`/AX notifications, UI. |
| **`AXWriter` queues** (one per app, `HyperSpace.AX.<pid>`, QoS `userInteractive`) | AX writes (move, resize, park, focus). A slow app only makes itself wait. |
| **`HyperSpace.state` queue** (QoS `utility`) | Reads titles and writes `workspaces.json` off the main thread. |

Communication rules:

- **Config → tap**: `EventTap.apply(_:)` hands the new `TapConfig` to the tap thread with `CFRunLoopPerformBlock`.
- **Tap → actions**: an action triggered by the tap runs with `DispatchQueue.main.async`.
- **Tap → drag**: `DragController` keeps only the latest point behind an `OSAllocatedUnfairLock` and schedules at most one pending main-thread update: no backlog even with a 1000 Hz mouse.
- **Main → apps**: AX writes go through `AXWriter.perform(pid)`. Reads and state stay on the main thread.
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
        ├─ EventTap.apply(config.tap)            binding/button tables, carriers, scroll, drag
        └─ WindowManager.apply(config.tiling)    layout, gaps, rules, workspaces, scratchpad
```

- **Shortcuts** (`keyboard.bindings`, workspace `switch`/`move`, mouse buttons) are compiled into `[Int16]` tables indexed by `keyCode << 4 | modifiers` (and `button << 4 | modifiers`); each entry is an index into `TapConfig.actions`.
- A **combination** as a remap target (`caps_lock → hyper`) becomes a *carrier* (see [Keyboard](03-keyboard.md)).
- The tap **subscribes only to the events in use** (`TapConfig.eventMask`): with an empty config no tap is installed at all.
- Without Accessibility `applyTrusted` is not called: only HID remaps are active. A 1 s timer polls until the permission arrives, then applies the already-loaded config.
- A tap disabled by the system (`tapDisabledByTimeout`/`ByUserInput`) is re-enabled in the callback.
- Events HyperSpace generates are stamped with `EventTap.syntheticMarker` (`0x48595045`) in `eventSourceUserData`; the tap lets them through untouched.

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

Mouse movement is never intercepted.

## Window manager: how it reacts

- **Event-driven**: one `AXObserver` per app (`windowCreated`, `windowMiniaturized`/`Deminiaturized`, `focusedWindowChanged`, and per window `UIElementDestroyed`, `moved`, `resized`, `titleChanged`) plus `NSWorkspace` notifications (launch, terminate, activate, hide/unhide, Space change) and screen-parameter changes. No polling.
- Bursts of events are coalesced into one retile (30 ms delay).
- Visibility and position of windows come from a single `CGWindowListCopyWindowInfo` per retile, without titles (so no Screen Recording).
- A window is moved only if its position really differs from the target (2 pt tolerance).
- See [Tiling](06-tiling.md), [Workspaces and displays](07-workspaces-and-displays.md) and [Scratchpad](08-scratchpad.md).

## Startup and quit

1. `applicationWillFinishLaunching`: reads from the Apple Event whether the app was launched at login.
2. `applicationDidFinishLaunching`: menus, status item, observers; requests Accessibility (with prompt); `ConfigStore.start()` (writes the default config if missing, loads it, watches it).
3. After a login launch, `revealAfter` (90 s) stops apps with a rule from taking you to their workspace.
4. On quit (`applicationWillTerminate`): `remapper.reset()` (removes HID remaps), `windowManager.saveState()`, `restoreHiddenWindows()`.

Double-clicking the already-running app opens the settings (`applicationShouldHandleReopen`).
