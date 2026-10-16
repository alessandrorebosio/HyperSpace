# Changelog

Every release, newest first. `scripts/release.sh` takes the notes of a release from its
section here, so a version's section is written before the version is released.

## [Unreleased]

### New

- **`monitor-brightness`, `monitor-volume` and `monitor-input`** change an external display's brightness, speaker volume (or `mute-toggle`) and input source over DDC: `monitor-brightness +10`, `monitor-input hdmi1 --monitor dell`. A key that switches the display to another computer, with `detect-monitor-input`, leaves the Mac with its workspaces.
- **`display_keys = true`** in keyboard.toml: the brightness keys change the external display under the pointer, and the volume keys the display's speakers when the sound plays there, which macOS can't do.
- **`subscribe`**, as AeroSpace's: `hsctl subscribe --all` prints one JSON line per event (`focus-changed`, `focused-monitor-changed`, `focused-workspace-changed`, `mode-changed`, `window-detected`) as it happens, the current state first unless `--no-send-initial`. For status bars such as SketchyBar, without polling.
- **`show-mode-bindings = true`** in wm.toml: a binding mode other than main (`mode service`) shows its keys and their commands at the bottom of the display while it's on.
- **Displays in the menu**: with more than one display, each one can be unchecked to leave it out of the window manager (`ignore-monitor`).
- **`list-monitors --all`** lists the displays left out too, and `%{monitor-is-ignored}` and `%{monitor-input}` (the input read over DDC) go in `--format`.

- **Check for Updates installs the update**: it downloads the release, checks that its app is signed with the same key, puts it in place of the running one and restarts HyperSpace. No quarantine, so macOS doesn't block it.

### Changed

- **The Mac's input on a display is learned only when the display surely shows the Mac**: when it's plugged in, or when you focus a window on it, no longer on the first read at launch (the display may then be showing another computer). `ignore-monitor off` still sets it by hand.
- **Displays are told apart by their EDID UUID**, not their name: two identical displays no longer share a workspace or an input.

## [0.5.0] - 2026-10-16

### New

- **`ignore-monitor (on|off|toggle) <monitor-pattern>...`** leaves displays out of the window manager as if they were disconnected: their workspaces wait on the other displays and come back with them.
- **`detect-monitor-input = true`** in wm.toml leaves out, by itself, a display that shows another input (another computer) while still connected to the Mac. The input is read over DDC every 2 seconds (Apple silicon); the one a display shows when first seen is taken as the Mac's, and `ignore-monitor off` on a display makes the input it shows now the Mac's.

## [0.4.0] - 2026-10-16

### New

- **`scratchpad --new <app-bundle-id>`** opens a new window of the app as the scratchpad, through the app's ⌘N menu item, in place of the one shown so far; a dialog it opens first (a template chooser) is left alone. Without such an item it works like `scratchpad`; a closed app is launched.
- **A window opened by `scratchpad` has a place to go back to.** When the app had no window and `scratchpad` opens one, putting it away sends it to the workspace of the app's `on-window-detected` rule, else to the workspace the app was last on, else to a fallback workspace: `scratchpad-fallback-workspace` in wm.toml, `Scratch` by default. That one shows in the menu, with Close All Windows to empty it, but `workspace next/prev` skip it.
- **`%{window-is-scratchpad}` and `%{window-scratchpad-home}`** in `--format`: whether a window is the shown scratchpad, and the workspace it goes back to.

### Changed

- **`scratchpad` takes the app's shown scratchpad, else its most recent window.**
- **Putting the scratchpad away sends it back to its workspace**, the one it was taken from, tiled as before (or floating, if it was), instead of parking it in a corner. ⌘-Tab to its app then shows that workspace, like for any window.
- **The scratchpad always shows centered at 80% of the display**, even after being moved or resized.
- **A scratchpad can become an ordinary window.** Tiling it (`layout tiling`) or moving it to another workspace or display leaves it there as an ordinary window; the next `scratchpad` of its app takes another of its windows when there is one.

### Fixed

- **A workspace switch is no longer undone by a late activation.** Pressing `workspace next` several times in a row could go back a step, or a display could go back to the workspace it showed before, when macOS reported the focus of the window just left after the switch.
- **Windows come back intact after quitting or restarting HyperSpace.** Quitting could leave some windows of hidden workspaces off screen, and at the next start they could keep the size of a tile on another display (a window too short, a gap below). Quitting now waits for every app to take its windows back, and at start windows stay put until the saved layout is restored.

## [0.3.0] - 2026-10-16

### New

- **Check for Updates** in the menu: asks GitHub for the latest release, only when clicked, and offers to open its page.
- **zsh completion for `hsctl`**: `eval "$(hsctl completion zsh)"` in `~/.zshrc` completes commands, flags and workspace names.

### Project

- The tests run on GitHub Actions for every push and pull request.
- `CHANGELOG.md` holds the release notes, and `scripts/release.sh` takes them from there.

## [0.2.0] - 2026-10-16

### New

- **Apps reopen where you left them.** When an app's last window closes or the app quits, HyperSpace remembers its workspace (across restarts too). Its next window goes back there, before `on-window-detected` rules run, and focus follows if the app is in front.
- **`scratchpad <app-bundle-id>`.** Summons a window of the app floating over the current workspace, centered at 80% the first time, and puts it away with the same key. The app is launched if needed, and ⌘-Tab to it brings it back. It survives a HyperSpace restart.
- **`move-workspace-to-monitor --no-swap`.** Moves a workspace to the other display without bringing back the one it covers: that one just hides, and the display left shows the workspace used last there.
- **Workspaces in the menu.** The menu lists every workspace with windows, the focused one checked, with its apps' icons. Each opens a submenu to show the workspace or focus one of its windows.

### Fixed

- Closing the focused window no longer switches to the workspace of the app macOS activates next: focus stays on the current workspace's next window.

## [0.1.1] - 2026-10-15

### Changed

- Faster workspace switches: the check that catches missed window events no longer runs on the switch's path (it waits a second after focus settles), helper windows aren't read again every time, and one call per layout change to each app is gone. An Electron app's window now moves in about 20 ms instead of 150-230 ms.
- Installed by hand from the release zip (no Homebrew tap).

## [0.1.0] - 2026-10-15

First release: keyboard remapping (Caps Lock layer), mouse remapping (Logitech included) and an AeroSpace-compatible tiling window manager, in one menu bar app. One process, no drivers, one permission (Accessibility). Requires macOS 15 or later.

- **Keyboard**: Caps Lock and other layers, dual-role keys, double taps, per-app and per-device remaps.
- **Mouse**: buttons, Logitech controls over HID++, wheel and gesture actions, smooth scrolling, pointer speed and acceleration.
- **Window manager**: AeroSpace's config (wm.toml) and commands (hsctl), layout kept across restarts, native tabs, floating dialogs, multiple displays with each display's workspace in the menu bar.
- **hsctl**: status, enable/disable, reload, and every window manager command.

[Unreleased]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.5.0...develop
[0.5.0]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alessandrorebosio/HyperSpace/releases/tag/v0.1.0
