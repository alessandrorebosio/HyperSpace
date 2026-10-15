# Phase 0 — Spike findings

Code: the throwaway `HyperSpace-spike` tool, removed after phase 0 (see commit `767051f` in the git history). `hidutil property --get UserKeyMapping` shows the L0 mappings it used to print.

Test machine: macOS 27.0.1, Swift 6.4 (Command Line Tools only, no Xcode), Logitech Lift on a Bolt receiver (`046D:C548`).
Also running on the machine: Karabiner-Elements (with its DriverKit virtual keyboard), LinearMouse, AeroSpace. They must be quit for the interactive tests, since they intercept the same events.

## Results so far

### S3 — Logitech HID++ works with **no permissions** ✅
- The receiver's vendor interface (`usage page 0xFF00`) opens with `kIOReturnSuccess` even when the process has neither Accessibility nor Input Monitoring.
- The Lift sits in Bolt slot 2, speaks **HID++ 4.5** and reports its name ("LIFT VERTICAL ERGONOMIC MOUSE").
- Feature `0x1B04` (Reprogrammable Keys) exposes 7 controls:

| CID | Control | Divertable | Seen by S1 (event tap)? |
|---|---|---|---|
| `0x0050` | Left click | no | yes |
| `0x0051` | Right click | no | yes |
| `0x0052` | Middle click | yes | yes |
| `0x0053` | Back | yes | yes (button 3) |
| `0x0056` | Forward | yes | yes (button 4) |
| `0x00FD` | DPI switch (top button) | yes | **no**, handled by the firmware |
| `0x00D7` | Virtual gesture button (flags `0xA0` = virtual) | yes | no |

- Conclusion: the DPI button can only be remapped through S3, which confirms the design. S3 costs no permissions.
- **Diversion works** (interactive run): after `setCidReporting(0x03)` middle/back/forward are no longer delivered to macOS and arrive as `divertedButtons` events instead, ~1 ms apart from the physical press. Events carry the full set of held CIDs (up to 4), so chords like back+forward+middle are visible. `setCidReporting(0x02)` restored all 5 controls on exit.
- DPI button `0x00FD`: confirmed in the second run, see below.
- The first request to a sleeping device can take > 0.4 s: HID++ calls need a ~2 s timeout and must never run on the input thread.
- Another process was talking HID++ to the receiver at the same time (different software id). HyperSpace must tolerate shared access and match responses by software id.

### S2 — Raw HID on standard mouse/keyboard interfaces needs **Input Monitoring** ⚠️
- `IOHIDDeviceOpen` on every generic desktop interface (mouse `1:2`, keyboard `1:6`) returns `not permitted` while `IOHIDCheckAccess(ListenEvent)` is denied. This applies to **mice too**, not just keyboards.
- Design impact: S2 is not free. Since S1 (event tap) already covers standard buttons/scroll and S3 covers Logitech firmware buttons, **S2 becomes a last-resort source**, off by default, enabled only for exotic non-Logitech devices. Most users never need Input Monitoring.

### L0 — `UserKeyMapping` API is public and available ✅
- `IOHIDEventSystemClientCreateSimpleClient` / `IOHIDServiceClientSetProperty` are in the public SDK headers (`IOKit/hidsystem`).
- 3 keyboard services found: built-in keyboard, Bolt receiver, Karabiner virtual keyboard. HyperSpace must skip Karabiner's virtual keyboard.
- Effect on key events still to verify interactively (see below).

### L1 — Active event tap needs **Accessibility only** ✅
- With Accessibility granted to the terminal and Input Monitoring *not* granted, the active tap (`kCGSessionEventTap`, `.defaultTap`) was created and saw every key down/up and modifier change. Confirms the single-permission design.
- Slowest callback over the 40 s run (excluding logging): **284 µs**, below the 1 ms target even in a debug build with a dictionary lookup.

- **Cold start:** the second run reported a 60 ms worst case. It's the first `CGEvent(keyboardEventSource:)` call in the process: measured separately at ~100 ms the first time, 0.002 ms afterwards. HyperSpace must **pre-warm** event creation at startup (create and drop one event of each kind) so the first remapped key isn't slow.

### Mouse through the event tap (S1) ✅
- Lift buttons arrive as `otherMouseDown/Up` with button **2 = middle, 3 = back, 4 = forward**, subtype 0.
- Back/forward were swallowed and replaced with ⌘[ / ⌘].
- Scroll: the Lift sends line-based wheel events (`lines = ±1`, `points = ±1`, `continuous = 0`, no phase): it's a notched wheel, so linear/smooth scrolling has to be synthesized by HyperSpace.

### DPI button via HID++ (S3) ✅
- After diversion the DPI button arrives as CID `0x00FD` press/release events, like the other buttons. It never reaches macOS on its own, so S3 is the only way to remap it, with no permission needed.

### Caps Lock → F18 (L0 + L1) ✅
- After `UserKeyMapping` Caps Lock arrives as key code **79 (F18)** with a normal down/up pair. No caps lock toggle (`flagsChanged` code 57) was observed during the whole run.
- F18 carries the `0x800000` (secondary fn) flag and **auto-repeats** while held: the layer must swallow repeats of the trigger key.
- Tap-alone detection worked (10 taps, each reported as "Caps tapped alone").
- While Caps was held, unmapped keys passed through as normal key codes.
- The keyboard service list during the run had no Karabiner virtual keyboard, so Karabiner wasn't grabbing devices.

### L2 — AX window enumeration: parallel per app is ~10× faster ✅
| Measure | Time |
|---|---|
| AX sequential (6 apps, 5 windows) | 264.5 ms |
| AX parallel, one thread per app | 25.1 ms |
| Slowest single app (VS Code) | 121.4 ms |
| `CGWindowList` snapshot (8 windows, no permission) | 60.2 ms |

- One slow app (VS Code, 121 ms) dominates the sequential time: confirms per-app concurrency and per-app timeouts from DESIGN §5.4.
- `CGWindowList` is not a cheap shortcut (60 ms here): the window cache should be fed by `AXObserver` notifications, not by snapshots.

### TCC
- A binary launched from another app is judged on the *responsible* app's permissions (here: Claude, which has neither Accessibility nor Input Monitoring). The real app must be a proper `.app` bundle so it gets its own TCC entry.

## Pending (interactive, `run-phase0.sh`)
- [x] Active event tap with **Accessibility only** sees and modifies key events.
- [x] Caps Lock → F18 via L0: no caps toggle, F18 down/up reaches the tap, tap-alone, unmapped keys pass through.
- [x] Caps + hjkl while F18 is held is remapped (3 rounds in the second run).
- [x] Side buttons reach the tap and are replaced by ⌘[ / ⌘].
- [x] Scroll event fields for the Lift (line-based, non-continuous).
- [x] HID++ diversion: middle/back/forward reported as diverted events, restored on exit.
- [x] HID++ diversion of the DPI button (`0x00FD`).
- First interactive run: tap and ax were skipped because the terminal app had no Accessibility. The script now checks this up front and can rerun single steps (`./run-phase0.sh tap ax`).
- [x] Tap callback latency: 284 µs worst case.
- [x] AX window enumeration: sequential vs parallel per app vs CGWindowList.
- [ ] Swipe gesture synthesis for universal back/forward (not implemented yet: needs private CGEvent gesture fields, separate spike).
