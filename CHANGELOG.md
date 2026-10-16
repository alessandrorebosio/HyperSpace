# Changelog

Every release, newest first. `scripts/release.sh` takes the notes of a release from its
section here, so a version's section is written before the version is released.

## [Unreleased]

### New

- **Check for Updates** in the menu: asks GitHub for the latest release, only when clicked, and offers to open its page.
- **zsh completion for `hsctl`**: `eval "$(hsctl completion zsh)"` in `~/.zshrc` completes commands, flags and workspace names.

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

[Unreleased]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.2.0...develop
[0.2.0]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alessandrorebosio/HyperSpace/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alessandrorebosio/HyperSpace/releases/tag/v0.1.0
