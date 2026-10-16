# HyperSpace

[![Tests](https://github.com/alessandrorebosio/HyperSpace/actions/workflows/test.yml/badge.svg)](https://github.com/alessandrorebosio/HyperSpace/actions/workflows/test.yml)

A single lightweight macOS app for:
- keyboard remapping, including a fully customizable Caps Lock layer (like Karabiner-Elements)
- generic remapping of any input from any mouse, Logitech included: side buttons as back/forward in every app (like LinearMouse)
- tiling window management (compatible with AeroSpace)

Goal: one process, no drivers, one permission (Accessibility).

Keyboard remapping (Caps Lock and other layers, dual-role keys, double taps, per-app and per-device remaps), mouse remapping (buttons, Logitech controls over HID++, wheel and gesture actions while a button is held, smooth scrolling, pointer speed and acceleration), system actions (media keys, Mission Control, windows, clicks, apps, text), and a tiling window manager compatible with AeroSpace: wm.toml takes AeroSpace's window keys (app-level ones like start-at-login live in the menu), `hsctl` takes AeroSpace's commands (empty wm.toml = off). On top of those, `scratchpad <app-bundle-id>` summons an app's window floating over the current workspace, centered at 80% of the display, and puts it back in its workspace with the same key (it launches the app if needed); `scratchpad --new` opens a new window of the app for it, through its ⌘N menu item; tiling or moving it makes it an ordinary window again. `move-workspace-to-monitor --no-swap` moves a workspace without bringing back the one it covers. `ignore-monitor on <monitor-pattern>` leaves a display out as if it were disconnected (its workspaces wait on the others), and `detect-monitor-input = true` in wm.toml does it by itself for a display switched to another input, such as another computer, while it stays connected to the Mac (read over DDC, Apple silicon). The menu bar shows each display's workspace. See [docs/DESIGN.md](docs/DESIGN.md).

## Install

Download `HyperSpace-<version>.zip` from [Releases](https://github.com/alessandrorebosio/HyperSpace/releases), unzip it and move `HyperSpace.app` to `/Applications`.

The app is signed with a self-signed identity, not notarized: the first time, macOS blocks it. Allow it in System Settings → Privacy & Security ("Open Anyway"), or run:

```sh
xattr -dr com.apple.quarantine /Applications/HyperSpace.app
```

Then grant Accessibility when asked (System Settings → Privacy & Security → Accessibility). To use `hsctl` from the terminal:

```sh
ln -s /Applications/HyperSpace.app/Contents/MacOS/hsctl /opt/homebrew/bin/hsctl
```

## Build

Requires macOS 15+ and Swift 6 (Command Line Tools are enough).

```sh
scripts/bundle.sh          # builds build/HyperSpace.app (hsctl is inside Contents/MacOS)
open build/HyperSpace.app
scripts/test.sh            # runs the tests
scripts/release.sh         # tests, bundle, then build/HyperSpace-<version>.zip
```

The app is signed with a self-signed "HyperSpace Dev" identity that `scripts/signing.sh` creates on the first build, in a keychain file private to this checkout (`.signing/`, git-ignored; the login keychain isn't touched). A stable signature means macOS keeps the Accessibility permission across rebuilds. Set `HYPERSPACE_SIGN_IDENTITY` to sign with another identity.

## Config

Three optional files in `~/.config/hyperspace/` (or `$XDG_CONFIG_HOME/hyperspace/`):
`keyboard.toml`, `mouse.toml`, `wm.toml`. A missing file means that feature is off.
"Open Config" in the menu creates commented starter files. Changes are applied on save;
errors show up in the menu and in `hsctl status`, per file, and a broken file keeps its
last good settings.

## hsctl

```sh
hsctl status        # permissions and config state
hsctl disable       # undo every remap, HyperSpace stays open (also from the menu)
hsctl enable        # turn it back on; `hsctl toggle` switches
hsctl do volume.up  # perform any action now, as a mapped input would
hsctl reload        # reload the config
hsctl config-path
hsctl apps          # running apps and their bundle ids, for per-app rules
hsctl version
```

Tab completion in zsh (commands, flags, workspace names): add this to `~/.zshrc`, after `compinit`:

```sh
eval "$(hsctl completion zsh)"
```

## License

MIT, see [LICENSE](LICENSE). Third-party code and ideas: [THIRD_PARTY.md](THIRD_PARTY.md).
