# Helm

A single lightweight macOS app for:
- keyboard remapping, including a fully customizable Caps Lock layer (like Karabiner-Elements)
- generic remapping of any input from any mouse, Logitech included: side buttons as back/forward in every app (like LinearMouse)
- tiling window management (like AeroSpace, more optimized)

Goal: one process, no drivers, one permission (Accessibility).

Status: phases 1–2 done: menu bar app, TOML config with hot reload, `helmctl`, keyboard remapping (Caps Lock layer, simple remaps, per-app overrides). Mouse and window management come next. See [docs/DESIGN.md](docs/DESIGN.md) and the spike results in [docs/SPIKE.md](docs/SPIKE.md).

## Build

Requires macOS 15+ and Swift 6 (Command Line Tools are enough).

```sh
scripts/bundle.sh          # builds build/Helm.app (helmctl is inside Contents/MacOS)
open build/Helm.app
scripts/test.sh            # runs the tests
```

Without a signing certificate the app is signed ad hoc, and macOS forgets the Accessibility permission after every rebuild. To keep it, create a self-signed certificate once: Keychain Access → Certificate Assistant → Create a Certificate…, name **Helm Dev**, identity type *Self Signed Root*, certificate type *Code Signing*. `scripts/bundle.sh` picks it up automatically (or set `HELM_SIGN_IDENTITY`).

## Config

`~/.config/helm/helm.toml` (or `$XDG_CONFIG_HOME/helm/helm.toml`). "Open Config" in the menu creates a commented starter file. Changes are applied on save; errors show up in the menu and in `helmctl status`.

## helmctl

```sh
helmctl status        # permissions and config state
helmctl reload        # reload the config
helmctl config-path
helmctl version
```
