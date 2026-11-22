# HyperSpace

Keyboard mapper, mouse mapper and tiling window manager for macOS in a single menu bar app.
Swift + AppKit, no dependencies, ~1.8 MB binary (stripped, arm64).

**The only permission required: Accessibility.** No Input Monitoring, no Screen Recording,
no notifications, no drivers/kexts, no root.

## What it does

- **Keyboard**: shortcuts for any action, per-keyboard key remaps in the system's HID layer (no permission, zero CPU),
  a key turned into a combination (caps lock → hyper), a keyboard lock for cleaning. → [Keyboard](docs/03-keyboard.md)
- **Mouse and trackpad**: extra buttons mapped to actions (universal Back/Forward included), reversed scroll wheel,
  modifier + drag to move and resize windows, trackpad edge sliders and corner double taps. → [Mouse](docs/04-mouse.md)
- **Tiling**: `tall`, `wide`, `columns` (i3-style), `monocle` and `accordion` layouts, gaps, floating apps and
  windows, resizing and moving from the keyboard. → [Tiling](docs/06-tiling.md)
- **Workspaces**: virtual workspaces with a home display each, pinned to a monitor if you like, app rules,
  restored after a restart. → [Workspaces and displays](docs/07-workspaces-and-displays.md)
- **Scratchpad**: an app or a window shown on demand above the others, out of the tiling. → [Scratchpad](docs/08-scratchpad.md)
- **Settings window and menu bar**: every option has a page; the menu bar shows the workspaces, the devices'
  batteries and what is wrong, if anything. → [Settings and menu](docs/09-settings-and-menu.md)

## Build

Only the Command Line Tools are needed (Xcode is not required). `make app` builds for the Mac it runs on
(arm64 on Apple silicon); it does not build a universal binary.

```bash
make app        # build/HyperSpace.app (release, signed with "HyperSpace Dev" if present, else ad-hoc)
make run        # quit the running copy, build, launch
make install    # quit the running copy, then copy to /Applications
make test       # tests (Swift Testing)
```

On first launch macOS asks for the Accessibility permission; HyperSpace starts by itself as soon as it is granted.
The permission is tied to the app's signature: how `make app` signs so that it survives rebuilds, and how to bind it
to a certificate of your own, is in [docs/10](docs/10-permissions-troubleshooting-build.md#permissions), with the
other make targets, troubleshooting and the tests.

Every push to `develop` and `main` and every pull request is built and tested on macOS by GitHub Actions, with the
Command Line Tools alone too, and screenshots of every settings page are saved
([docs/10](docs/10-permissions-troubleshooting-build.md#continuous-integration)).

## Configuration

`~/.config/hyperspace/config.json` — created on first launch, reloaded automatically on every save. It can live anywhere:
**Settings → General → Move…** moves it, **Use Another File…** reads one you already have (a dotfiles folder, say), and
HyperSpace remembers the choice. A config from an older version in `~/.hyperspace/config.json` keeps working while it is the only one.
If the file has an error the menu bar icon turns into ⚠︎ and the menu shows the message; the last valid config stays active.
Everything in the file can also be set from **Settings…** (menu bar, ⌘,), which rewrites it.

```json
{
  "keyboard": {
    "remap": [
      { "from": "caps_lock", "to": "hyper" },
      { "from": "right_option", "to": "escape" }
    ],
    "bindings": [
      { "keys": "hyper+h", "action": "focus left" },
      { "keys": "cmd+alt+t", "action": "launch Terminal" }
    ]
  },
  "mouse": {
    "reverseScroll": true,
    "dragModifier": "ctrl+alt",
    "buttons": [ { "button": 3, "action": "key cmd+[" } ]
  },
  "tiling": {
    "enabled": true, "layout": "columns", "gap": 8, "padding": 8, "masterRatio": 0.55,
    "floating": ["com.apple.finder"]
  }
}
```

Every section and key, with its default: [Configuration](docs/02-configuration.md). Every action: [Actions](docs/05-actions.md).
Key names: [Keyboard](docs/03-keyboard.md#key-names).

## Documentation

| Page | Contents |
|---|---|
| [Overview and architecture](docs/01-architecture.md) | Modules, threads, data flow from config to features |
| [Configuration](docs/02-configuration.md) | `config.json`: every section and key, defaults, reload, errors |
| [Keyboard](docs/03-keyboard.md) | Shortcuts, key names, per-keyboard remaps, combinations, keyboard lock |
| [Mouse](docs/04-mouse.md) | Button mapping, reverse scroll, modifier + drag, trackpad edge sliders and corners |
| [Actions](docs/05-actions.md) | Full list of actions and their arguments |
| [Tiling](docs/06-tiling.md) | Layouts, gaps, floating windows and rules, resize, focus/swap, drag and drop |
| [Workspaces and displays](docs/07-workspaces-and-displays.md) | Workspaces per display, pins, app rules, saved state |
| [Scratchpad](docs/08-scratchpad.md) | Per-app and generic scratchpad, size, centring |
| [Settings window and menu bar](docs/09-settings-and-menu.md) | Every settings page, the menu bar, the app menu |
| [Permissions, troubleshooting, build and test](docs/10-permissions-troubleshooting-build.md) | Accessibility, Copy Debug Info, `make`, tests, CI |

## Known limitations

- Uses three private (but stable for years) interfaces, so the app cannot be sandboxed nor go on the Mac App Store
  (true of any AX-based window manager).
- macOS Spaces are not created or managed: the windows of the visible Space on each display are tiled.

Details in [docs/10](docs/10-permissions-troubleshooting-build.md#permissions).
