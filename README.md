# HyperSpace

A single lightweight macOS app for:
- keyboard remapping, including a fully customizable Caps Lock layer (like Karabiner-Elements)
- generic remapping of any input from any mouse, Logitech included: side buttons as back/forward in every app (like LinearMouse)
- tiling window management (like AeroSpace, more optimized)

Goal: one process, no drivers, one permission (Accessibility).

Status: phases 1–2 done: menu bar app, TOML config with hot reload, `hsctl`, keyboard remapping (Caps Lock and other layers, dual-role keys, double taps, per-app and per-device remaps), mouse remapping (buttons, Logitech controls over HID++, wheel and gesture actions while a button is held, smooth scrolling, pointer speed and acceleration), and system actions (media keys, Mission Control, windows, clicks, apps, text). Window management comes next. See [docs/DESIGN.md](docs/DESIGN.md) and the spike results in [docs/SPIKE.md](docs/SPIKE.md).

## Build

Requires macOS 15+ and Swift 6 (Command Line Tools are enough).

```sh
scripts/bundle.sh          # builds build/HyperSpace.app (hsctl is inside Contents/MacOS)
open build/HyperSpace.app
scripts/test.sh            # runs the tests
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
