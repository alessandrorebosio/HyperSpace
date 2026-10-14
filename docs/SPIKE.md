# Phase 0 — Spike findings

Code: [`Spikes/`](../Spikes) (`helm-spike`, throwaway). Interactive run: `Spikes/run-phase0.sh`.

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
- DPI button `0x00FD`: diverted OK but no event was recorded in the run. To confirm whether it wasn't pressed or the Lift doesn't report it.
- The first request to a sleeping device can take > 0.4 s: HID++ calls need a ~2 s timeout and must never run on the input thread.
- Another process was talking HID++ to the receiver at the same time (different software id). Helm must tolerate shared access and match responses by software id.

### S2 — Raw HID on standard mouse/keyboard interfaces needs **Input Monitoring** ⚠️
- `IOHIDDeviceOpen` on every generic desktop interface (mouse `1:2`, keyboard `1:6`) returns `not permitted` while `IOHIDCheckAccess(ListenEvent)` is denied. This applies to **mice too**, not just keyboards.
- Design impact: S2 is not free. Since S1 (event tap) already covers standard buttons/scroll and S3 covers Logitech firmware buttons, **S2 becomes a last-resort source**, off by default, enabled only for exotic non-Logitech devices. Most users never need Input Monitoring.

### L0 — `UserKeyMapping` API is public and available ✅
- `IOHIDEventSystemClientCreateSimpleClient` / `IOHIDServiceClientSetProperty` are in the public SDK headers (`IOKit/hidsystem`).
- 3 keyboard services found: built-in keyboard, Bolt receiver, Karabiner virtual keyboard. Helm must skip Karabiner's virtual keyboard.
- Effect on key events still to verify interactively (see below).

### TCC
- A binary launched from another app is judged on the *responsible* app's permissions (here: Claude, which has neither Accessibility nor Input Monitoring). The real app must be a proper `.app` bundle so it gets its own TCC entry.

## Pending (interactive, `run-phase0.sh`)
- [ ] Active event tap with **Accessibility only**: does it see and modify key events (no Input Monitoring)?
- [ ] Caps Lock → F18 via L0: no caps toggle, F18 down/up reaches the tap; hjkl layer; unmapped keys pass through.
- [ ] Side buttons → ⌘[ / ⌘] work in Safari and other apps.
- [ ] Scroll event fields for the Lift (line vs point deltas, continuous flag).
- [x] HID++ diversion: middle/back/forward reported as diverted events, restored on exit.
- [ ] HID++ diversion of the DPI button (`0x00FD`).
- First interactive run: tap and ax were skipped because the terminal app had no Accessibility. The script now checks this up front and can rerun single steps (`./run-phase0.sh tap ax`).
- [ ] Tap callback latency (target < 1 ms).
- [ ] AX window enumeration: sequential vs parallel per app vs CGWindowList.
- [ ] Swipe gesture synthesis for universal back/forward (not implemented yet: needs private CGEvent gesture fields, separate spike).
