# HyperSpace wiki

HyperSpace is a macOS menu-bar app (Swift + AppKit, no dependencies) that combines a **keyboard mapper**, a **mouse mapper** and a
**tiling window manager** with virtual workspaces, multiple displays and a scratchpad. This wiki describes what the app contains and how it works,
written from the code in `Sources/HyperSpace/`. For a quick overview and install steps see the repository [README](../README.md) (in Italian).

> Where the README and the code disagree, these pages follow the **code**. The differences are listed in
> [README vs code](11-readme-vs-code.md).

## Index

| Page | Contents |
|---|---|
| [1. Overview and architecture](01-architecture.md) | Modules, threads, data flow from config to features |
| [2. Configuration](02-configuration.md) | `config.json`: every section and key, defaults, reload, errors |
| [3. Keyboard](03-keyboard.md) | Shortcuts, key names, per-keyboard remaps (HID), combinations/carriers, keyboard lock |
| [4. Mouse](04-mouse.md) | Button mapping, reverse scroll, modifier + drag |
| [5. Actions](05-actions.md) | Full list of actions and their arguments |
| [6. Tiling](06-tiling.md) | Layouts, gaps/padding, floating windows and rules, resize, focus/swap, drag & drop, snap back |
| [7. Workspaces and displays](07-workspaces-and-displays.md) | Workspaces per display, moving, app assignments, parking, saved state |
| [8. Scratchpad](08-scratchpad.md) | Per-app and generic scratchpad, size, centering, overlap |
| [9. Settings window and menu bar](09-settings-and-menu.md) | Every settings page, the menu bar, the app menu |
| [10. Permissions, troubleshooting, build and test](10-permissions-troubleshooting-build.md) | Accessibility, Copy Debug Info, `make app`, `make test` |
| [11. README vs code](11-readme-vs-code.md) | Where the README does not match the code |

## At a glance

- **One permission: Accessibility.** Key remapping works without it.
- **Config**: `~/.config/hyperspace/config.json`, created on first launch, reloaded on every save. Edit by hand or from *Settings…* (which rewrites the file).
- **Workspace state**: `~/Library/Application Support/HyperSpace/workspaces.json`.
- **Version / requirements**: 0.1.0, macOS 13+ (`LSMinimumSystemVersion`); an agent app (`LSUIElement`): no Dock icon except while the Settings window is open.
- **Bundle id**: `com.alessandrorebosio.HyperSpace`.
