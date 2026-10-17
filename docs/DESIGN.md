# HyperSpace — Design

> One macOS app, lightweight and with the fewest possible permissions, that combines:
> - **keyboard remapping** (like Karabiner-Elements)
> - **mouse button and scroll remapping**, including Logitech mice (like LinearMouse)
> - **tiling window manager** (like AeroSpace, but more optimized)

Status: design approved in principle, spike phase next.

---

## 1. Goals and non-goals

**Goals**
- A single process, a single menu bar app (`LSUIElement`), no Dock icon.
- **A single TCC permission: Accessibility.** No driver, no root daemon, no admin password.
- Added latency per input event < 1 ms, ~0% CPU when idle, < 30 MB RAM.
- Text configuration (TOML) with hot reload, easy to keep in dotfiles.
- Launch at login via `SMAppService.mainApp` (no hand-written LaunchAgent).

**Non-goals (at least for v1)**
- No virtual HID driver (DriverKit) like Karabiner: it is the main source of permissions and complexity.
- No complex editing GUI: minimal UI (status, permissions, reload, config errors).
- No device *settings* (DPI, SmartShift, lighting): HyperSpace remaps inputs, it doesn't configure hardware.
- No SIP changes, no scripting additions (AeroSpace doesn't need them, neither do we).

---

## 2. How the reference projects work (and what we take)

| Project | Technique | Permissions | What we take |
|---|---|---|---|
| **Karabiner-Elements** | Root daemon that *seizes* HID devices through IOKit + DriverKit driver emulating a virtual keyboard | Input Monitoring, system extension, admin | The **rule model** (from → to, to_if_alone, simultaneous keys, per-app conditions). **Not** the architecture. |
| **LinearMouse** | `CGEventTap` on mouse/scroll events + IOHIDManager to tell which device an event came from | Accessibility | Mouse event pipeline, **per-device** settings, linear/reversed scrolling. |
| **AeroSpace** | Accessibility API (`AXUIElement`) + "virtual" workspaces (windows hidden by moving them off-screen), i3-like tiling tree, TOML config, CLI | Accessibility | Most of the WM model: tree, virtual workspaces, commands, config format. |

Licenses: check before copying any code (AeroSpace and LinearMouse are MIT, Karabiner-Elements is Unlicense). Keep attributions in `THIRD_PARTY.md`.

---

## 3. Fewest-permissions strategy (the key idea)

Remapping is split into **three levels**; we always pick the lowest level that is enough:

| Level | Mechanism | Permissions | Use |
|---|---|---|---|
| **L0 — HID key mapping** | `IOHIDEventSystemClient` property `UserKeyMapping` (what `hidutil` does) | **None** | Static 1:1 remaps (e.g. swap ⌘/⌥ on an external keyboard) and turning Caps Lock into a free key for L1 (see §5.1). Runs in the kernel, zero cost, works in password fields too. Can be filtered per device (VendorID/ProductID). |
| **L1 — Event tap** | Active `CGEventTap` (`kCGSessionEventTap`, head insert) | **Accessibility** | Complex remaps: Caps Lock layer, dual-role keys, per-app rules, mouse buttons, scrolling, WM hotkeys. |
| **L2 — Accessibility API** | `AXUIElement` + `AXObserver` | **Accessibility** (same permission) | Window manager. |

Result: **one permission (Accessibility)**. If only key -> key remaps are used, **no permissions at all**.

Mouse inputs that the event tap can't see are read through raw HID (§5.2, sources S2/S3). Whether that needs Input Monitoring for pointer devices is verified in the spike; if it does, the permission is requested only when the config actually maps such an input.

WM hotkeys go through the same L1 event tap (one tap for the keyboard, no duplicate Carbon `RegisterEventHotKey`).

### Known limits of this choice (accepted on purpose)
- **Secure Input** (password fields, Terminal with "Secure Keyboard Entry"): the L1 tap doesn't see key events. L0 remaps keep working; the Caps Lock layer does not.
- A `CGEventTap` sees events already processed by macOS: some special keys (fn/Globe, media keys) are more limited than in Karabiner.
- If the tap callback is slow, macOS disables it (`kCGEventTapDisabledByTimeout`): it must be re-enabled and the callback must stay minimal.

---

## 4. Architecture

```
┌──────────────────────── HyperSpace.app (one process) ──────────────────────────────┐
│                                                                              │
│  Main thread (UI)            Input thread (QoS userInteractive)              │
│  ┌──────────────┐            ┌─────────────────────────────────────────┐     │
│  │ MenuBar/UI   │            │ CGEventTap ──► EventPipeline             │     │
│  │ Permissions  │            │   ├─ KeyEngine   (compiled rules)        │     │
│  │ ConfigLoader │──snapshot─►│   ├─ MouseEngine (per device, scroll)    │     │
│  │ (FSEvents)   │ immutable  │   └─ HotkeyRouter ──► WM command queue ──┼──┐  │
│  └──────────────┘            └─────────────────────────────────────────┘  │  │
│         │                                                                  │  │
│         ▼                    WM actor (dedicated thread)                   │  │
│  ┌──────────────┐            ┌─────────────────────────────────────────┐  │  │
│  │ HIDMapper L0 │            │ WindowManager: tree, workspaces,         │◄─┘  │
│  │ (no perms)   │            │ layout, per-app AXObserver               │     │
│  └──────────────┘            └─────────────────────────────────────────┘     │
│                                         ▲                                    │
│                         Unix socket ────┘  (`hsctl` CLI, optional)         │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Modules (Swift Package, separate targets)

| Target | Responsibility | Depends on |
|---|---|---|
| `HyperSpaceCore` | Config models, TOML parsing, validation, logging (`os.Logger`), permissions | — |
| `KeyEngine` | Compiles rules into lookup tables; state machine for layers and dual-role keys | Core |
| `MouseEngine` | Normalizes every source into `MouseInput`; button/scroll rules per device | Core |
| `HIDInput` | Raw HID reading (S2) and vendor protocols (S3, Logitech HID++ first); starts only when needed | Core, IOKit |
| `HIDMapper` | Applies/removes L0 `UserKeyMapping` per device, restores it on quit | Core, IOKit |
| `InputTap` | `CGEventTap` lifecycle, dedicated thread, re-enable on timeout | Key/MouseEngine |
| `WindowManager` | Tiling tree, virtual workspaces, commands, AX window observation | Core |
| `HyperSpaceApp` | Menu bar app, permission onboarding, login item | all |
| `HyperSpaceIPC` | `hsctl` ↔ app protocol (JSON lines over a Unix socket); no dependencies | — |
| `hsctl` | Socket client for WM commands and `reload`; links only `HyperSpaceIPC` (~150 KB) | HyperSpaceIPC |

The CLI is called `hsctl`: a `hyperspace` binary next to `HyperSpace` in `Contents/MacOS` would clash on macOS's case-insensitive file system.

### Performance principles
- **Compiled config**: the tap callback never touches TOML or dictionaries; it uses fixed arrays indexed by keycode (256 slots).
- **Immutable snapshots**: config is swapped atomically (reference swap), no locks on the hot path.
- **Zero allocations** in the callback where possible; no synchronous logging on the hot path.
- **The WM never runs inside the callback**: a hotkey enqueues a command and the tap returns immediately. AX calls (slow, can block) live on their own thread.
- No polling: everything is event-driven (event tap, `AXObserver`, `NSWorkspace` notifications, FSEvents).

---

## 5. Features per module

### 5.1 Keyboard (v1)

**General rule: a remapped key loses its original function.**
Any key (Caps Lock included) that appears in the config does *only* what it is mapped to. Keys that are not in the config are never touched.

**Caps Lock layer (main requirement)**
- Once Caps Lock is configured, it **no longer toggles caps lock**: it only does what the config says.
- While Caps Lock is held, every key can be mapped to an action (key, key combo, shell command, WM command). Each key is configured on its own.
- **Unmapped keys keep their normal behavior**: if `Caps + Q` has no mapping, the event passes through untouched (as plain `Q`, with any real modifiers kept).
- Tapping Caps Lock alone does nothing by default; it can be given its own action (`alone = "escape"`, etc.).
- `hold = "meh"` (or `"hyper"`, or any list like `"shift-ctrl-opt"`): while Caps Lock is held, every *unmapped* key gets these modifiers, so Caps works as a Meh/Hyper key. Keys listed in the layer map keep their own action.
- Implementation:
  1. L0 remaps Caps Lock to an unused key (e.g. F18). This kills the caps lock toggle and the built-in Caps Lock delay at kernel level, and gives L1 a normal key down/up pair to track.
  2. L1 tracks the F18 down/up state and looks up `layer[keycode]` for each key while it's held. A hit emits the mapped action and swallows the original event; a miss passes the event through.
  3. Tap alone (down → up with no other key in between, within `tap_timeout`) emits the `alone` action, if any.
- The same layer mechanism works for any other key used as a layer trigger.
- Caps Lock → F18 is applied at L0 **only while the event tap is running**: without Accessibility the layer can't work, and Caps Lock would otherwise go dead.
- L0 mappings replace any `hidutil` mapping on the same keyboard while HyperSpace runs; the previous mapping is restored on quit (also on `SIGTERM`/`SIGINT`) and re-applied when a keyboard is plugged in or the Mac wakes.
- Only one HyperSpace instance can run at a time (bundle id check + live socket check).
- Mappings can be overridden per app (bundle id).

**Other keyboard features**
- Simple 1:1 remaps (pushed to L0 when possible)
- Dual-role keys (`to_if_alone`) with a configurable timeout
- Conditions: frontmost app (bundle id), device (vendor/product id)
- Simultaneous keys (e.g. `j+k` → Esc): v1.1

### 5.2 Mouse (v1): generic remapping of any input

**Requirement:** HyperSpace must read and remap **any input coming from any mouse**, regardless of how the device delivers it. No model-specific features: the reference device (Logitech Lift) is just the test case.

**One abstraction: `MouseInput`.** Every source below is normalized into the same event type, so the rule engine doesn't care where an input came from:

```
MouseInput = button(n) | scroll(axis, delta) | move(dx, dy) | vendor(usagePage, usage)
             + device id (vendor, product, serial) + down/up + timestamp
```

**Input sources, from cheapest to most invasive:**

| Source | What it sees | How | Permissions |
|---|---|---|---|
| **S1 — Event tap** | Standard buttons 1–32, vertical/horizontal scroll, movement | `CGEventTap` (same tap as the keyboard) | Accessibility (already granted) |
| **S2 — Raw HID** | Inputs macOS does not turn into events: vendor-specific usages, extra buttons not mapped by the system driver | `IOHIDManager` input value callbacks on pointer devices, no seize | To verify in the spike (expected: none for mice, Input Monitoring only for keyboards) |
| **S3 — Vendor protocol** | Buttons the firmware handles on its own and never sends to the host (e.g. Logitech buttons that switch DPI/SmartShift). They must be *diverted* to the host first | Logitech **HID++ 2.0**: "Reprogrammable Keys" feature (0x1b04) on the vendor collection (usage page 0xFF00), over Bolt receiver or Bluetooth | Same as S2 |

- S1 is always on. S2/S3 start only if the config maps an input that S1 can't see, so with a plain mouse the cost is zero.
- S3 is a plugin per vendor (`VendorProtocol`); Logitech HID++ is the first one. HID++ is the same protocol across all modern Logitech mice, so it isn't model-specific.
- Outputs are generic too: any input can become a key/combo, a mouse button, scroll, a shell command or a WM command.

**Generic rule (same as the keyboard):** a remapped input loses its original function; unmapped inputs pass through untouched.

**Side buttons → back/forward in every app (main requirement)** ✅
- Side buttons arrive through S1 as `otherMouseDown` with button number 3 (back) and 4 (forward).
- `navigate.back` / `navigate.forward` work like LinearMouse's "universal back/forward": apps that support trackpad navigation (Apple apps, Firefox, Opera, ForkLift) get a synthesized **navigation swipe**; every other app gets mouse button 4/5, which browsers and editors handle natively.
- Rejected approaches (tested on an Italian keyboard):
  - sending ⌘[ / ⌘] by key code: on non-US layouts those keys are other characters (Italian: `è` / `+`, so Safari zoomed);
  - pressing the app's Back/Forward menu item via AX: AppKit localizes the shortcut per layout (Safari's Back is ⌘ò on Italian) and Forward failed right after Back.
- Per-app overrides still work (`[[mouse.app]]`, e.g. `passthrough`).

**Scroll and pointer**
- Separate reverse setting for mouse/trackpad, linear scrolling, speed/acceleration per device.
- Device identification: S2/S3 know the device directly; for S1 events, match on the last active device from IOHIDManager (as LinearMouse does).

### 5.3 Reference device: Logitech Lift
Used to validate the generic design, not hard-coded anywhere.
- Spike: list every input the Lift produces and record which source (S1/S2/S3) sees it, over both Bluetooth and the Bolt receiver.
- Buttons that only S3 can see get diverted via HID++ when the config maps them, and released (firmware default restored) when HyperSpace quits or the mapping is removed.
- DPI and other device *settings* (not inputs) are out of scope for v1.

### 5.4 Window manager (v1): AeroSpace model, optimized

Same concepts and command names as AeroSpace, so moving an existing config over is easy:
- Tiling tree (h/v tiles, accordion), focus/move/resize/join, floating per app
- Virtual workspaces (not macOS Spaces, no SIP changes), workspace-to-monitor assignment
- App rules (e.g. Finder floating, Slack → workspace 9)
- Commands from hotkeys and from `hsctl`
- HyperSpace's own: displays left out as if disconnected, by `ignore-monitor` or, with
  `detect-monitor-input`, when their input (DDC VCP 0x60, read every 2 s off the main
  thread through `IOAVService`) isn't the one first read on them: a display switched to
  another computer often stays connected to macOS
- HyperSpace's own: an external display's brightness, volume and input over DDC
  (`monitor-*` commands), and the brightness/volume keys for them (`display_keys`): the tap
  then sees media keys (`systemDefined`), takes the ones for an external display and
  hands them to the DDC queue, where key repeats add up into one write

Implementation: `WMModel` (HyperSpaceCore) is the pure state and every command over ids and
rectangles, unit tested; `WindowManager` (HyperSpaceWM) feeds it AX events and applies its
`layout()`. Hotkeys from `[bindings]` are compiled into the keyboard's hotkey table
(⌘⇧⌥⌃ × key code, a flat array), matched in the event tap after remapping, so a Caps Lock
`hold = "meh"` can drive `meh-h` bindings.

Optimizations over AeroSpace:
- **Window state cache**: frames, app and window ids live in memory and are updated from `AXObserver` notifications. The WM doesn't query AX on every command (AX calls are slow, and some apps take tens of ms to answer). AeroSpace runs a full refresh (every app's window list) after each AX notification.
- **Attribute-level diffs**: a window that only moves gets a position call, one that only resizes a size call; frames are diffed against the last requested frame, so a window refusing a size (minimum size) isn't asked again on every change.
- **Coalescing**: per window, a queued frame superseded by a newer command is skipped.
- **Native tabs**: with macOS tabs (Finder, Safari, Terminal) every tab is a window; a window with a tab bar on the exact frame of a managed window of the same app joins that window's tile instead of splitting the screen. Closing the shown tab promotes another; dragging a tab out makes it a window again.
- **Windows set aside**: a minimized window, a window in macOS full screen (its own Space) and the windows of a hidden app leave the layout; their tile closes and nothing moves or parks them. Each keeps its spot (workspace, sibling window, weight, `fullscreen`) and comes back there, even after a restart (`set-aside.json`). While a full screen Space is shown, focus there doesn't switch workspaces.
- **Window index**: the model keeps window → workspace in a dictionary instead of searching every tree.
- **Diff-based layout**: after each command only the windows whose frame actually changed get an AX `setFrame`. Unchanged windows aren't touched.
- **Batched workspace switch**: all hide/show moves are computed first, then sent as one batch per app, each on the app's own queue, so apps move concurrently and a slow one holds up only its own windows.
- **Fewer calls per frame**: a window that both moves and resizes gets two AX calls, in the order that keeps it on screen (shrinking: size then position; growing: position then size), three only when one side grows and the other shrinks.
- **Per-app timeouts** (`AXUIElementSetMessagingTimeout`): a frozen app can't block the whole WM.
- **WM actor off the input thread**: hotkeys never wait for the WM.

---

## 6. Configuration

Three optional files in `$XDG_CONFIG_HOME/hyperspace/` (default `~/.config/hyperspace/`): `keyboard.toml`, `mouse.toml`, `wm.toml`, reloaded automatically on save. Section names are relative to the file (`[capslock]` in keyboard.toml, `[buttons]` in mouse.toml). Unknown keys are errors, so typos don't fail silently. Errors are reported per file, and a broken file keeps its last good settings while the others still apply.

The files created on first launch document every option in comments. In short:

```toml
# ── keyboard.toml ────────────────────────────────────────
# Always active. key -> key is applied at HID level (works in password fields);
# combos and actions go through the event tap.
[map]
"command.right" = "option.right"
f1 = "cmd-space"
f5 = { shell = "open -a Safari" }

# [map] overrides while one app is in front. Overridden keys are handled by the tap.
[[app]]
bundle_id = "com.apple.Terminal"
map = { f1 = "passthrough" }

# key -> key for one keyboard only. Comes before [map] for the same key.
[[device]]
vendor = 0x05ac
map = { "option.left" = "command.left" }

# Once configured, Caps Lock no longer toggles caps lock.
[capslock]
hold = "shift-ctrl-opt"      # modifiers added to unmapped keys while held ("meh", "hyper")
alone = "escape"             # action when tapped alone
led = "held"                 # "off" (default) or "held"
tap_timeout_ms = 200

[capslock.map]               # Caps + key, in every app
h = "arrow.left"
t = { shell = "open -a Terminal" }
"1" = { wm = "workspace 1" }

[[capslock.app]]             # Caps + key, one app
bundle_id = "com.microsoft.VSCode"
map = { d = "cmd-shift-k" }

# Any other key as a layer or dual-role key. Typing keys decide tap vs hold when the
# next key is released ("permissive hold"), so fast typing isn't affected.
[layer.space]
alone = "space"
map = { j = "arrow.down", k = "arrow.up" }

[layer.return]               # Return tapped, Control held
alone = "return"
hold = "ctrl"

[double]                     # double taps; modifiers work too (watched via flagsChanged)
"shift.left" = "cmd-space"

# ── mouse.toml ───────────────────────────────────────────
[buttons]                    # button1...button31, middle, back, forward
back = "navigate.back"
forward = "navigate.forward"
middle = "media.play"        # named actions: volume.*, brightness.*, media.*, mission.*, space.*,
button5 = "mission.control"  #   window.*, click.*, scroll.*, lookup, zoom.smart (list in mouse.toml)
button6 = { scroll = "down", lines = 5 }

dpi = "mission.control"      # Logitech controls over HID++ (dpi, gesture, cid.0x....)
button7 = { action = "volume.up", repeat = true }   # repeat while held
button8 = { action = "click.left", hold = true }    # held down while held: drags
button9 = { app = "Safari" } # also text, sequence, shell, scroll

[[app]]
bundle_id = "com.google.Chrome"
buttons = { back = "passthrough", forward = "passthrough" }

[hold.back]                  # while back is held: wheel and gestures; tapped, it's back
"scroll.up" = "volume.up"
"move.left" = "space.left"
distance = 60

[scroll]                     # notched wheels only
smooth = true                # synthesized trackpad-like glide
reverse = "vertical"         # true, "vertical" or "horizontal"
lines = 3
fast = "opt"
fast_factor = 3

[pointer]                    # HID properties, no permission; trackpads untouched
speed = 0.5
acceleration = false

[[device]]                   # per-device pointer settings
name = "lift"
speed = 0.6

# How navigate.back/.forward reach an app (bundle id prefixes), on top of the built-in
# list (Apple apps, Firefox, Opera, ForkLift get a swipe; others get buttons 4/5).
[navigate]
swipe = ["com.example."]
buttons = ["com.apple.Xcode"]

# ── wm.toml ──────────────────────────────────────────────
# AeroSpace's keys for windows only; app-level options (config-version, start-at-login,
# auto-reload-config, normalization toggles, key-mapping, exec.*, after-startup-command)
# aren't accepted: HyperSpace handles those itself (menu, always-on reload, qwerty notation).
# Supported: accordion-padding, default-root-container-*, on-focus-changed,
# on-focused-monitor-changed, on-mode-changed, exec-on-workspace-change,
# automatically-unhide-macos-hidden-apps, persistent-workspaces (omitted = workspaces named
# in bindings), focus-follows-mouse, gaps (per side, per monitor),
# workspace-to-monitor-force-assignment, mode.*.binding, on-window-detected, and
# HyperSpace's scratchpad-fallback-workspace, detect-monitor-input, show-mode-bindings and
# reopen-apps-in-last-workspace
# (if = 'test ...' or the legacy if.* table). Commands: all of AeroSpace's except split,
# config and debug-windows (subscribe without binding-triggered); shell syntax ; && || ( ) without pipes.
# The menu bar shows the focused workspace, preceded by the mode's initial outside main.
persistent-workspaces = ['1', '2', 'Develop']
gaps.inner.horizontal = 5
gaps.outer.top = [{ monitor.main = 16 }, 24]

[mode.main.binding]
    ctrl-alt-shift-h = 'focus left'
    ctrl-alt-shift-cmd-1 = 'move-node-to-workspace 1'
    ctrl-alt-shift-period = 'mode service'

[mode.service.binding]
    esc = ['reload-config', 'mode main']

[[on-window-detected]]
    if.app-id = 'com.microsoft.VSCode'
    run = ['move-node-to-workspace Develop']
```

---

## 7. Tech stack

- **Swift 6** (strict concurrency), Swift Package Manager plus a small Xcode project only for bundling and signing.
  - All the APIs we need are Apple frameworks (CoreGraphics, IOKit, ApplicationServices); Swift calls them directly, with no binding layer.
  - AeroSpace and LinearMouse are Swift too, so their logic can be studied and reused directly.
  - Native code with no garbage collector; with an allocation-free hot path, latency stays predictable.
- **AppKit** for the menu bar and onboarding; SwiftUI only for the settings window.
- Target: **macOS 15+**.
- **Not sandboxed** (App Sandbox blocks controlling other apps' windows via AX), so distribution is outside the App Store, signed with Developer ID and notarized.
- External dependencies: only a TOML parser (e.g. `TOMLKit`). Everything else is system frameworks.
- Tests: unit tests for KeyEngine/MouseEngine (pure, no IO) and for the WM layout algorithm.

---

## 8. Roadmap

| Phase | Scope | Expected outcome |
|---|---|---|
| **0 — Spike** ✅ | Minimal event tap; Caps→F18 via `UserKeyMapping`; swipe vs ⌘[ for back/forward; AX window enumeration; list every Logitech Lift input per source (S1/S2/S3) and the permissions S2/S3 need | Real permissions and limits confirmed on the target Mac |
| **1 — Foundations** ✅ | Package, menu bar app, Accessibility onboarding, TOML config + hot reload, `hsctl` | App starts, asks for one permission, reloads config. Measured: 12 MB footprint, 0% idle CPU |
| **2 — Keyboard** ✅ | L0 + KeyEngine (Caps layer, `[map]` remaps, per-app and per-device overrides). General dual-role keys deferred | Replaces typical Karabiner usage |
| **3 — Mouse** ✅ | ✅ MouseEngine (S1): any button except left, universal back/forward, per-app overrides, wheel reverse/linear. Next: HIDInput (S3 Logitech HID++ for the DPI button), `hsctl list-inputs`, per-device settings | Replaces LinearMouse, remaps any mouse input |
| **4 — WM** ✅ (needs real-world testing) | Tree, virtual workspaces, commands, rules, optimizations from §5.4 | Replaces AeroSpace for daily use |
| **5 — Extras** | Simultaneous keys, more vendor protocols, settings UI, Karabiner rule importer | — |

---

## 9. Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Name | **HyperSpace** (CLI: `hsctl`) |
| 2 | Config format | **TOML** |
| 3 | Language | **Swift 6** |
| 4 | Caps Lock | Per-key layer; loses the caps lock toggle; unmapped keys keep their normal behavior |
| 4b | Remapped keys/inputs | Do only what they are mapped to; original function is lost |
| 5 | Mouse | Generic remapping of any input from any mouse (S1/S2/S3); side buttons → back/forward in every app |
| 6 | WM | AeroSpace model and commands, with the optimizations in §5.4 |
| 7 | Documentation | English |

Reference test mouse: Logitech Lift.
