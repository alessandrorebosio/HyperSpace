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
- No Logitech proprietary protocol (HID++) in v1, see §5.3.
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
| `MouseEngine` | Button remapping, scrolling (reverse, linear, speed) per device | Core |
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

**Caps Lock layer (main requirement)**
- While Caps Lock is held, every key can be mapped to an action (key, key combo, shell command, WM command). Each key is configured on its own.
- **Unmapped keys keep their normal behavior**: if `Caps + Q` has no mapping, the event passes through untouched (as plain `Q`, or with the original modifiers).
- What Caps Lock does when tapped alone is configurable: `caps_lock` (original toggle, default), `escape`, or nothing.
- Implementation:
  1. L0 remaps Caps Lock to an unused key (e.g. F18). This removes the caps lock toggle and the built-in Caps Lock delay, and gives L1 a normal key down/up pair to track.
  2. L1 tracks the F18 down/up state and looks up `layer[keycode]` for each key while it's held. A hit emits the mapped action and swallows the original event; a miss passes the event through.
  3. Tap alone (down → up with no other key in between, within `tap_timeout`) emits the `alone` action. To restore the original toggle, Helm sets the caps lock state through IOKit (`IOHIDSetModifierLockState`). To be verified in the spike.
- Mappings can be overridden per app (bundle id).

**Other keyboard features**
- Simple 1:1 remaps (pushed to L0 when possible)
- Dual-role keys (`to_if_alone`) with a configurable timeout
- Conditions: frontmost app (bundle id), device (vendor/product id)
- Simultaneous keys (e.g. `j+k` → Esc): v1.1

### 5.2 Mouse (v1)

**Side buttons → back/forward in every app (main requirement)**
- Side buttons arrive as `otherMouseDown` with button number 3 (back) and 4 (forward).
- Default strategy: convert them to **⌘[ / ⌘]**, which works in Safari, Finder, Xcode, App Store, System Settings and most native apps.
- Per-app overrides for apps that use different shortcuts (e.g. VS Code `ctrl+-` / `ctrl+shift+-`) or that already handle the buttons natively (Chrome, Firefox: pass through).
- Spike alternative: synthesize a **swipe navigation gesture** (like Mac Mouse Fix). Apps that support trackpad swipe-to-go-back would react without per-app rules. If reliable, it becomes the default, with ⌘[ / ⌘] as a fallback.

**Other mouse features**
- Remap of any extra button to keys, combos or WM commands
- Scrolling: separate reverse setting for mouse/trackpad, linear scrolling, speed/acceleration per device
- Device identification via IOHIDManager (match on last active device, as LinearMouse does)

### 5.3 Logitech
- Standard buttons (back/forward, middle, horizontal wheel) arrive as normal HID events, so **v1 covers them**.
- Gesture button, thumb wheel on some models, DPI and SmartShift require Logitech's proprietary **HID++** protocol. That means opening the HID device (possibly the **Input Monitoring** permission) and implementing the protocol per model. **Deferred to v2, optional and off by default.**

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

[keyboard.capslock]
alone = "caps_lock"          # "caps_lock" | "escape" | "none"
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
[mouse.buttons]
back    = "navigate_back"     # default: swipe or ⌘[ (chosen after the spike)
forward = "navigate_forward"

[[mouse.buttons.app]]
bundle_id = "com.microsoft.VSCode"
back = "ctrl-minus"
forward = "ctrl-shift-minus"

[[mouse.buttons.app]]
bundle_id = "com.google.Chrome"
back = "passthrough"
forward = "passthrough"

[[mouse.device]]
match = { vendor = 0x046d }   # Logitech
scroll = { reverse = true, linear = true, lines = 3 }

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
| **0 — Spike** | Minimal event tap; Caps→F18 via `UserKeyMapping`; caps lock toggle via IOKit; swipe vs ⌘[ for back/forward; AX window enumeration; Logitech device detection | Real permissions and limits confirmed on the target Mac |
| **1 — Foundations** | Package, menu bar app, Accessibility onboarding, TOML config + hot reload, `helmctl` | App starts, asks for one permission, reloads config |
| **2 — Keyboard** | L0 + KeyEngine (Caps layer, simple remaps, dual-role, per-app conditions) | Replaces typical Karabiner usage |
| **3 — Mouse** | MouseEngine: back/forward everywhere, per-device scrolling | Replaces LinearMouse |
| **4 — WM** | Tree, virtual workspaces, commands, rules, optimizations from §5.4 | Replaces AeroSpace for daily use |
| **5 — Extras** | Simultaneous keys, Logitech HID++ (optional), settings UI, Karabiner rule importer | — |

---

## 9. Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Name | **Helm** (CLI: `helmctl`) |
| 2 | Config format | **TOML** |
| 3 | Language | **Swift 6** |
| 4 | Caps Lock | Per-key layer, unmapped keys keep their normal behavior |
| 5 | Mouse side buttons | Back/forward in every app (swipe or ⌘[ / ⌘], per-app overrides) |
| 6 | WM | AeroSpace model and commands, with the optimizations in §5.4 |
| 7 | Documentation | English |

**Still open**
- Logitech model in use (decides whether HID++ is ever needed).
- What Caps Lock does when tapped alone (default: original caps lock toggle).
