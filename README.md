# HyperSpace

A single lightweight macOS app for:
- keyboard remapping, including a fully customizable Caps Lock layer (like Karabiner-Elements)
- generic remapping of any input from any mouse, Logitech included: side buttons as back/forward in every app (like LinearMouse)
- tiling window management (compatible with AeroSpace)

Goal: one process, no drivers, one permission (Accessibility).

Status: phases 1–2 done: menu bar app, TOML config with hot reload, `hsctl`, keyboard remapping (Caps Lock layer, key remaps, per-app and per-device overrides), mouse buttons and scrolling. Window management comes next. See [docs/DESIGN.md](docs/DESIGN.md) and the spike results in [docs/SPIKE.md](docs/SPIKE.md).

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
hsctl reload        # reload the config
hsctl config-path
hsctl apps          # running apps and their bundle ids, for per-app rules
hsctl version
```
