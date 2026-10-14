# Helm — Design

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
- No device *settings* (DPI, SmartShift, lighting): Helm remaps inputs, it doesn't configure hardware.
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

Result: **one permission (Accessibility)**. If only simple remaps are used, **no permissions at all**.

Mouse inputs that the event tap can't see are read through raw HID (§5.2, sources S2/S3). Whether that needs Input Monitoring for pointer devices is verified in the spike; if it does, the permission is requested only when the config actually maps such an input.

WM hotkeys go through the same L1 event tap (one tap for the keyboard, no duplicate Carbon `RegisterEventHotKey`).

### Known limits of this choice (accepted on purpose)
- **Secure Input** (password fields, Terminal with "Secure Keyboard Entry"): the L1 tap doesn't see key events. L0 remaps keep working; the Caps Lock layer does not.
- A `CGEventTap` sees events already processed by macOS: some special keys (fn/Globe, media keys) are more limited than in Karabiner.
- If the tap callback is slow, macOS disables it (`kCGEventTapDisabledByTimeout`): it must be re-enabled and the callback must stay minimal.

---

## 4. Architecture

```
┌──────────────────────── Helm.app (one process) ──────────────────────────────┐
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
│                         Unix socket ────┘  (`helmctl` CLI, optional)         │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Modules (Swift Package, separate targets)

| Target | Responsibility | Depends on |
|---|---|---|
| `HelmCore` | Config models, TOML parsing, validation, logging (`os.Logger`), permissions | — |
| `KeyEngine` | Compiles rules into lookup tables; state machine for layers and dual-role keys | Core |
| `MouseEngine` | Normalizes every source into `MouseInput`; button/scroll rules per device | Core |
| `HIDInput` | Raw HID reading (S2) and vendor protocols (S3, Logitech HID++ first); starts only when needed | Core, IOKit |
| `HIDMapper` | Applies/removes L0 `UserKeyMapping` per device, restores it on quit | Core, IOKit |
| `InputTap` | `CGEventTap` lifecycle, dedicated thread, re-enable on timeout | Key/MouseEngine |
| `WindowManager` | Tiling tree, virtual workspaces, commands, AX window observation | Core |
| `HelmApp` | Menu bar app, permission onboarding, login item | all |
| `helmctl` | Socket client for WM commands and `reload` | Core |

The CLI is called `helmctl`, not `helm`, to avoid clashing with the Kubernetes `helm` CLI.

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
- Implementation:
  1. L0 remaps Caps Lock to an unused key (e.g. F18). This kills the caps lock toggle and the built-in Caps Lock delay at kernel level, and gives L1 a normal key down/up pair to track.
  2. L1 tracks the F18 down/up state and looks up `layer[keycode]` for each key while it's held. A hit emits the mapped action and swallows the original event; a miss passes the event through.
  3. Tap alone (down → up with no other key in between, within `tap_timeout`) emits the `alone` action, if any.
- The same layer mechanism works for any other key used as a layer trigger.
- Mappings can be overridden per app (bundle id).

**Other keyboard features**
- Simple 1:1 remaps (pushed to L0 when possible)
- Dual-role keys (`to_if_alone`) with a configurable timeout
- Conditions: frontmost app (bundle id), device (vendor/product id)
- Simultaneous keys (e.g. `j+k` → Esc): v1.1

### 5.2 Mouse (v1): generic remapping of any input

**Requirement:** Helm must read and remap **any input coming from any mouse**, regardless of how the device delivers it. No model-specific features: the reference device (Logitech Lift) is just the test case.

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

**Side buttons → back/forward in every app (main requirement)**
- Side buttons arrive through S1 as `otherMouseDown` with button number 3 (back) and 4 (forward).
- Default action `navigate_back` / `navigate_forward`, sent as **⌘[ / ⌘]**: works in Safari, Finder, Xcode, App Store, System Settings and most native apps.
- Per-app overrides for apps that use different shortcuts (e.g. VS Code `ctrl+-` / `ctrl+shift+-`) or that already handle the buttons natively (Chrome, Firefox: pass through).
- Spike alternative: synthesize a **swipe navigation gesture** (like Mac Mouse Fix). Apps that support trackpad swipe-to-go-back would react without per-app rules. If reliable, it becomes the default, with ⌘[ / ⌘] as a fallback.

**Scroll and pointer**
- Separate reverse setting for mouse/trackpad, linear scrolling, speed/acceleration per device.
- Device identification: S2/S3 know the device directly; for S1 events, match on the last active device from IOHIDManager (as LinearMouse does).

### 5.3 Reference device: Logitech Lift
Used to validate the generic design, not hard-coded anywhere.
- Spike: list every input the Lift produces and record which source (S1/S2/S3) sees it, over both Bluetooth and the Bolt receiver.
- Buttons that only S3 can see get diverted via HID++ when the config maps them, and released (firmware default restored) when Helm quits or the mapping is removed.
- DPI and other device *settings* (not inputs) are out of scope for v1.

### 5.4 Window manager (v1): AeroSpace model, optimized

Same concepts and command names as AeroSpace, so moving an existing config over is easy:
- Tiling tree (h/v tiles, accordion), focus/move/resize/join, floating per app
- Virtual workspaces (not macOS Spaces, no SIP changes), workspace-to-monitor assignment
- App rules (e.g. Finder floating, Slack → workspace 9)
- Commands from hotkeys and from `helmctl`

Optimizations over AeroSpace:
- **Window state cache**: frames, app and window ids live in memory and are updated from `AXObserver` notifications. The WM doesn't query AX on every command (AX calls are slow, and some apps take tens of ms to answer).
- **Diff-based layout**: after each command only the windows whose frame actually changed get an AX `setFrame`. Unchanged windows aren't touched.
- **Batched workspace switch**: all hide/show moves are computed first, then applied concurrently per app. Today they are applied one after the other.
- **Per-app timeouts** (`AXUIElementSetMessagingTimeout`): a frozen app can't block the whole WM.
- **WM actor off the input thread**: hotkeys never wait for the WM.

---

## 6. Configuration (draft)

`~/.config/helm/helm.toml`, reloaded automatically on save.

```toml
# ── Keyboard ─────────────────────────────────────────────
[keyboard]
simple = [
  { from = "right_command", to = "right_option", device = { vendor = 0x05ac } },
]

# Once configured, Caps Lock no longer toggles caps lock.
[keyboard.capslock]
alone = "none"               # action when tapped alone, e.g. "escape"
tap_timeout_ms = 200

# Caps + key. Keys not listed here keep their normal behavior.
[keyboard.capslock.map]
h = "left_arrow"
j = "down_arrow"
k = "up_arrow"
l = "right_arrow"
u = "cmd-left_arrow"
o = "cmd-right_arrow"
t = { shell = "open -a Terminal" }
"1" = { wm = "workspace 1" }

# Per-app override of the Caps layer
[[keyboard.capslock.app]]
bundle_id = "com.microsoft.VSCode"
map = { d = "cmd-shift-k" }

# ── Mouse ────────────────────────────────────────────────
# Any input from any mouse. Unmapped inputs pass through untouched.
[mouse.buttons]
button3 = "navigate_back"     # side buttons; default: swipe or ⌘[ (chosen after the spike)
button4 = "navigate_forward"
button2 = { wm = "fullscreen" }

[[mouse.buttons.app]]
bundle_id = "com.microsoft.VSCode"
button3 = "ctrl-minus"
button4 = "ctrl-shift-minus"

[[mouse.buttons.app]]
bundle_id = "com.google.Chrome"
button3 = "passthrough"
button4 = "passthrough"

[[mouse.device]]
match = { vendor = 0x046d }   # Logitech
scroll = { reverse = true, linear = true, lines = 3 }
# Inputs only visible via raw HID / HID++ are named by `helmctl list-inputs`
buttons = { "hidpp:0x00c4" = "cmd-tab" }

# ── Window manager ───────────────────────────────────────
[wm]
enabled = true
gaps = { inner = 8, outer = 8 }

[wm.bindings]
"alt-h" = "focus left"
"alt-shift-h" = "move left"
"alt-1" = "workspace 1"
"alt-shift-1" = "move-node-to-workspace 1"

[[wm.rule]]
app = "com.apple.finder"
layout = "floating"
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
| **0 — Spike** | Minimal event tap; Caps→F18 via `UserKeyMapping`; swipe vs ⌘[ for back/forward; AX window enumeration; list every Logitech Lift input per source (S1/S2/S3) and the permissions S2/S3 need | Real permissions and limits confirmed on the target Mac |
| **1 — Foundations** | Package, menu bar app, Accessibility onboarding, TOML config + hot reload, `helmctl` | App starts, asks for one permission, reloads config |
| **2 — Keyboard** | L0 + KeyEngine (Caps layer, simple remaps, dual-role, per-app conditions) | Replaces typical Karabiner usage |
| **3 — Mouse** | MouseEngine (S1), back/forward everywhere, per-device scrolling; then HIDInput (S2, S3 with Logitech HID++), `helmctl list-inputs` | Replaces LinearMouse, remaps any mouse input |
| **4 — WM** | Tree, virtual workspaces, commands, rules, optimizations from §5.4 | Replaces AeroSpace for daily use |
| **5 — Extras** | Simultaneous keys, more vendor protocols, settings UI, Karabiner rule importer | — |

---

## 9. Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Name | **Helm** (CLI: `helmctl`) |
| 2 | Config format | **TOML** |
| 3 | Language | **Swift 6** |
| 4 | Caps Lock | Per-key layer; loses the caps lock toggle; unmapped keys keep their normal behavior |
| 4b | Remapped keys/inputs | Do only what they are mapped to; original function is lost |
| 5 | Mouse | Generic remapping of any input from any mouse (S1/S2/S3); side buttons → back/forward in every app |
| 6 | WM | AeroSpace model and commands, with the optimizations in §5.4 |
| 7 | Documentation | English |

Reference test mouse: Logitech Lift.
