# 10. Permissions, troubleshooting, build and test

## Permissions

**Accessibility is the only permission.** It covers the active event tap (read + modify input), posting synthetic events, and AX window control. Not needed: Input Monitoring, Screen Recording (titles are never requested from `CGWindowList`),
notifications, drivers/kexts, root.

| Feature | Needs Accessibility |
|---|---|
| Per-keyboard HID remaps (1:1) | **No** — active before the permission is granted |
| Combinations (carriers), shortcuts, caps lock suppression, mouse buttons, reverse scroll, drag, keyboard lock | Yes (event tap) |
| Tiling, workspaces, scratchpad, `navigate` | Yes (AX) |

- At launch HyperSpace asks (`AXIsProcessTrustedWithOptions` with prompt). Until it is granted a 1 s timer polls cheaply; as soon as it arrives the already-loaded config is applied, with no restart.
- Missing permission is shown in the menu (`Accessibility not granted to this build`), on the window pages (banner) and on the Settings page.
- **Signing and the grant**: macOS ties the Accessibility grant to the app's *designated requirement*. A plain ad-hoc signature bases it on the binary hash, which changes on every build, so the grant is lost even though the switch
  looks on in System Settings. `make app` therefore signs ad-hoc pinning the requirement to the bundle id (`identifier "com.alessandrorebosio.HyperSpace"`) so the grant survives rebuilds. This is convenient for development but weaker (any app signed with that bundle id inherits the grant).
  For a strong binding create a self-signed code-signing certificate named **`HyperSpace Dev`** (*Keychain Access → Certificate Assistant → Create a Certificate*, *Self Signed Root*, *Code Signing*): if present, `make app` uses it automatically.
- The app cannot be sandboxed nor go on the Mac App Store: it uses the private (but long-stable) `_AXUIElementGetWindow`, like yabai/Amethyst/Rectangle.
- Known limit: Spaces are not created or managed; windows of the visible Space on each display are tiled.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Shortcuts, mouse, tiling do nothing | Accessibility granted *to this build*? (menu shows a problem; after a rebuild with a different signature, remove and re-add HyperSpace in System Settings → Privacy & Security → Accessibility) |
| Menu icon is ⚠︎ | Click the top menu item: permission → opens the pane; config error → opens the file. The last valid config remains active |
| Config change not applied | Fix the error shown; check JSON syntax; remember unknown keys are silently ignored (typos); use the `reload` action |
| A remap does nothing | Is the key name right? Several rules on the same key: the most specific wins. Rules for a keyboard name must match its product name (see *Copy Debug Info → keyboards*) |
| "too many different combinations (at most 8)" | Reduce distinct combinations as remap targets |
| A key combination from F13–F20 acts oddly | Carriers use F13–F20: avoid binding those keys yourself |
| A window will not tile | Only standard windows tile; dialogs, panels and native full-screen windows are ignored; check floating rules and `float` toggles. A window that can neither zoom nor go full screen floats as a dialog (`floating (dialog)` in Copy Debug Info); `float` tiles it anyway |
| A window jumps back after moving it | Intentional snap back; use modifier drag or the shortcuts |
| Windows left in the bottom-right corner | Normally restored on quit/tiling off; after a crash they are rescued (centred) at the next start |
| Nothing at all after login | At login for 90 s apps with rules do not move you; the first config may still be loading |
| Keyboard locked | Click *Unlock* with the mouse (menu or Settings → Keyboard); it also unlocks by itself after the chosen time; quitting unlocks |
| `Config error: mouse button must be between 2 and 31` | Buttons 0/1 (left/right click) cannot be mapped |

### Copy Debug Info

*Menu bar → Copy Debug Info* copies a text report (window titles shortened to 40 characters) to paste in a bug report:

- `HyperSpace <version> — <date>`, macOS version and uptime;
- Accessibility `granted`/`missing`, *launched at login*;
- Keyboard `locked`/`active` and the names of connected keyboards;
- `Problem: …` if any;
- Tiling: `running`/`stopped`, enabled, layout; per display: id, frame, the workspace it shows, `[focused]`;
- *Moved workspaces* (home overrides);
- per workspace with windows: app bundle id, window id, title, frame, and flags (`floating`, `floating (dialog)`, `scratchpad`/`scratchpad shown`, `parked`, `off screen`);
- *Watched apps*;
- **Recent issues** (last 30): apps that cannot be watched yet, windows without id, failed AX moves (with the AX error code), focus that did not take, scratchpad app not found.

Verbose logs go to the unified log (subsystem `com.alessandrorebosio.HyperSpace`, category `app`); e.g.:

```bash
log stream --predicate 'subsystem == "com.alessandrorebosio.HyperSpace"' --level debug
```

## Build

Only the Command Line Tools are needed (not Xcode). SwiftPM, no dependencies; platform macOS 13+, `swift-tools-version:5.10`.

```bash
make build      # swift build -c release (CONFIG=release by default)
make app        # build/HyperSpace.app: release build, Info.plist, icon, stripped, codesigned
make run        # make app + open the bundle
make install    # make app + copy to /Applications (replaces the existing copy)
make test       # run the tests
make clean      # remove .build and build/
```

- `make app` copies the binary, `Resources/Info.plist` and `Resources/AppIcon.icns` into the bundle, strips the binary, and codesigns it with hardened runtime (`--options runtime`)
  using `HyperSpace Dev` if that identity exists, otherwise ad-hoc with the designated requirement pinned to the bundle id.
  Override with `SIGN_IDENTITY=… make app`, or `CONFIG=debug`.
- There is no `scripts/bundle.sh`; the bundle is built by the Makefile.
- After rebuilding, relaunch the app (`make run`) to test the new binary.

## Test

```bash
make test
```

Tests use **Swift Testing** (`Tests/HyperSpaceTests/HyperSpaceTests.swift`). **Use `make test`, not plain `swift test`**: with only the Command Line Tools, SwiftPM does not always hand the Swift Testing macro plugin
to the compiler and fails with `plugin for module 'TestingMacros' not found`. The Makefile passes it explicitly (`-Xswiftc -load-plugin-library … libTestingMacros.dylib`, found next to the active `swift`) when it exists.

What is covered: config parsing (default config, workspace shortcuts and rules, rule for an unknown workspace, title rules), carriers and combinations (avoiding bound keys, sharing, invalid combinations), key labels/text, mouse presets parsing, column
operations (stack/unstack), layout frames and weights, workspace homes and display sync (each display shows one of its own, moved workspaces, what a display shows after losing a workspace), new-window workspace choice, launch tracking and timeout,
frame steps (only what changed, shrink before moving, across displays), saved state round trip and restorer matching, scratchpad frame/centring and the "window missing the size stays centred" logic, scratchpad actions and size config.

The UI is not unit-tested; to check a settings layout, render it offscreen to a PNG from a temporary test.
