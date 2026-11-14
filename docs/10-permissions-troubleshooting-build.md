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
- Missing permission is shown in the menu (`Accessibility permission needed`), on the window pages (banner) and on the General page.
- **Signing and the grant**: macOS ties the Accessibility grant to the app's *designated requirement*. A plain ad-hoc signature bases it on the binary hash, which changes on every build, so the grant is lost even though the switch
  looks on in System Settings. `make app` therefore signs ad-hoc pinning the requirement to the bundle id (`identifier "com.alessandrorebosio.HyperSpace"`) so the grant survives rebuilds. This is convenient for development but weaker (any app signed with that bundle id inherits the grant).
  For a strong binding create a self-signed code-signing certificate named **`HyperSpace Dev`** (*Keychain Access → Certificate Assistant → Create a Certificate*, *Self Signed Root*, *Code Signing*): if present, `make app` uses it automatically.
- The app cannot be sandboxed nor go on the Mac App Store: it uses private (but long-stable) interfaces: `_AXUIElementGetWindow` like yabai/Amethyst/Rectangle, `CoreDockSendNotification` for the Mission Control actions and MultitouchSupport for the trackpad edge sliders.
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
| Keyboard locked | Click *Unlock Keyboard* with the mouse (menu or Settings → Keyboard); it also unlocks by itself after the chosen time; quitting unlocks |
| Empty workspace on another display: menu bar stays lit on the other display, typing goes to the old window | HyperSpace clicks the desktop of that display so the Finder becomes active there ([Empty workspaces](07-workspaces-and-displays.md#empty-workspaces)); no click while a mouse button is held or a window covers the middle of the display (the log says `empty display: no click, …`) |
| A window moved to another display has the wrong size | It is written again and retiled at 0.3 s and 0.8 s; an app with a minimum size larger than its tile keeps its own. Check *Copy Debug Info → Recent issues* for failed AX moves |
| `Config error: mouse button must be between 2 and 31` | Buttons 0/1 (left/right click) cannot be mapped |

### Copy Debug Info

*Menu bar → Copy Debug Info* copies a text report (window titles shortened to 40 characters) to paste in a bug report:

- `HyperSpace <version> — <date>`, macOS version and uptime;
- Accessibility `granted`/`missing`, *launched at login*;
- `Devices:` the wireless keyboards, mice and trackpads that report a battery, with their level (or `none with a battery`);
- Keyboard `locked`/`active` and the names of connected keyboards;
- `Problem: …` if any;
- Tiling: `running`/`stopped`, enabled, layout; per display: id, UUID, frame, visible frame, the workspace it shows, `[focused]`;
- *Displays left out* (asleep or on another input, see [page 7](07-workspaces-and-displays.md));
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
The build is for the architecture of the Mac it runs on: **arm64 only** on Apple silicon (no universal binary, so no Intel build).

```bash
make build      # swift build -c release (CONFIG=release by default)
make app        # build/HyperSpace.app: release build, Info.plist, icon, stripped, codesigned
make run        # make app + open the bundle
make install    # make app + quit the running HyperSpace + copy to /Applications (replaces the existing copy)
make test       # run the tests
make clean      # remove .build, .build-clt (CI's Command Line Tools build), .swiftpm and build/
```

- `make app` copies the binary, `Resources/Info.plist` and `Resources/AppIcon.icns` into the bundle, strips the binary, and codesigns it with hardened runtime (`--options runtime`)
  using `HyperSpace Dev` if that identity exists, otherwise ad-hoc with the designated requirement pinned to the bundle id.
  Override with `SIGN_IDENTITY=… make app`, or `CONFIG=debug`. The identity, the SDK version and the test plugin path are looked up only by the targets that need them, once per `make`.
- `make app` also rewrites the binary's build version with `vtool` (minimum macOS 13.0, SDK = `xcrun --show-sdk-version`). SwiftPM records the deployment target as the SDK version, and AppKit would then run the app in compatibility mode, with the pre-Liquid Glass look on macOS 26 and later.
- `Resources/AppIcon.icns` is drawn by `scripts/make-icon.py` (needs Pillow): run `python3 scripts/make-icon.py` after changing the icon. The 16 and 32 px sizes leave out the glyphs: only the tiles stay.
- There is no `scripts/bundle.sh`; the bundle is built by the Makefile.
- After rebuilding, relaunch the app (`make run`) to test the new binary.

## Test

```bash
make test
```

Tests use **Swift Testing** (`Tests/HyperSpaceTests/`, one file per area, shared helpers in `TestHelpers.swift`). **Use `make test`, not plain `swift test`**: with only the Command Line Tools, SwiftPM does not always hand the Swift Testing macro plugin
to the compiler and fails with `plugin for module 'TestingMacros' not found`. The Makefile passes it explicitly (`-Xswiftc -load-plugin-library … libTestingMacros.dylib`, found next to the active `swift`) when it exists.

What is covered:

- **Config**: the default config, workspace shortcuts, rules and pins, last binding wins, clamped spacing, rules for an unknown workspace, title rules, error messages (wrong type, missing key, broken JSON, the menu's short title), action parsing and its error messages, which actions repeat, the tap's event mask, key table consistency.
- **Config file**: `ConfigWriter` (round trip, key order, layout of the JSON, escaping; editing only the touched key, refusing a file with a syntax error, writing through a symbolic link) and the `ConfigStore` watcher (an edit, a deleted file that comes back, a broken file and its fix) on a temporary file.
- **Keyboard**: carriers and combinations (avoiding bound keys and twins, sharing, the active layout, invalid and too many), modifier names and messages, per-keyboard remap precedence, shortcut labels and text, mouse presets, the keyboard lock's remaining time.
- **Event tap decisions** (`TapState`): bound presses and their swallowed key-ups, autorepeat, the overview key, suspension, modifier-only and key carriers, mouse buttons, a new config.
- **Trackpad**: edge sliders on all four edges (direction, a second finger, a press, the first notch in a corner, edges set to nothing), corner double taps (timing, movement, zones, holding the pointer) and their config.
- **Layouts**: `tall`/`wide`/`columns`/`monocle`/`accordion` frames and weights, column operations (stack/unstack, swap, accordion), neighbours across displays, frame steps (only what changed, shrink before moving, across displays), parking, centring.
- **Workspaces**: homes, pinned displays and display sync (each display shows one of its own, moved workspaces, what a display shows after losing a workspace), new-window workspace choice, launch tracking and timeout, saved state round trip, saved columns and restorer matching, menu summaries.
- **Scratchpad**: frame and centring, the remembered size, actions and size config.
- **Settings models' pure parts**: tiling bindings and scratchpad apps, workspace names and the rules that follow them, comparing shortcuts and actions by meaning, `SyncedSlice` and `Optional.assignChange` (`FileSync.swift`).

The UI is not unit-tested; to check a settings layout, render the pages to PNG files (below).

### Screenshots of the settings window

```bash
make app
build/HyperSpace.app/Contents/MacOS/HyperSpace --render-settings ~/Desktop/hyperspace-shots
```

Draws every page of the settings window (sidebar included), in light and dark appearance, at 720×460 (the minimum size) and 900×640, at 2× scale, as `<page>-<light|dark>-<width>x<height>.png` (e.g. `tiling-dark-900x640.png`), then quits.
Nothing else starts: no event tap, remapping, tiling or menu bar item, and nothing is written to `config.json` (the pages show your current config). Run it with HyperSpace quit or running, it makes no difference.
The code is in `Settings/SettingsSnapshot.swift`; the window is drawn offscreen (invisible) with `cacheDisplay`, so AppKit controls are included.

Where the offscreen drawing comes out blank (the GitHub runners: no Liquid Glass and no SwiftUI content), set `HYPERSPACE_SNAPSHOT_SCREENCAPTURE=1`: each window is shown on screen and photographed with `screencapture -l` (needs the Screen Recording permission, which the runners have).

### Continuous integration

`.github/workflows/ci.yml` runs on every push to `develop` and `main`, on pull requests and by hand (*Run workflow*), on a GitHub macOS runner:
`make app`, `make test`, then `--render-settings` with a sample config (`.github/ci/sample-config.json`, copied to `~/.hyperspace/config.json` on the runner) so the lists have rows to show.
The screenshots are kept as the **settings-screenshots** artifact of the run (Actions → the run → Artifacts) and, except for pull requests, also pushed to the hidden git ref `refs/ci/screenshots` (not a branch), which can be read without the GitHub web page:

```bash
mkdir /tmp/shots && cd /tmp/shots && git init -q && git fetch -q https://github.com/alessandrorebosio/HyperSpace refs/ci/screenshots && git checkout -q FETCH_HEAD
```
