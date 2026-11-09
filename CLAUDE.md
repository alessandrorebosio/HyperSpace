# HyperSpace

macOS menu bar app (SwiftPM, no Xcode project): key remapping, mouse and trackpad actions,
a tiling window manager with virtual workspaces. Docs in `docs/`.

## Constraints

- Targets **macOS 13** and must build with the **Command Line Tools only** (CI checks it): no
  SwiftUI macros (`@State`, `@Observable`, `#Preview`). View state lives in `ObservableObject`
  models with `@Published`.
- The `swiftui-macos` skill in `.claude/skills` assumes macOS 26 and Swift 6.2: use its
  runtime insights (view identity, observation cost, AppKit bridging), not its macOS 26-only
  APIs or `@Observable`.
- Settings models write the real `~/.hyperspace/config.json`: test pure functions, not the models.

## Commands

- `make test` — unit tests (Swift Testing)
- `make app` — builds `build/HyperSpace.app`; rebuild and relaunch it before asking for a manual test
- `build/HyperSpace.app/Contents/MacOS/HyperSpace --render-settings <folder>` — PNGs of every settings page
