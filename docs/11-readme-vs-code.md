# 11. README vs code

The repository README (in Italian) was compared with the code. The code wins; these are the differences found.

## Inconsistencies

| # | README says | Code does |
|---|---|---|
| 1 | Per-app workspace rules are edited in "Tiling → App Rules" | The **App Rules** section is on the **Workspaces** page |
| 2 | **Caps+N** shows workspace N, **Caps+⌘+Tab** runs `move-workspace-to-display` | Neither is in the default config (it defines no workspaces and no display shortcuts); they exist only if you create them (Settings → Workspaces / Shortcuts → Displays) |
| 3 | Modifier-drag resize of a tiled window "moves the master/stack split" | Only in `tall`/`wide`. In `columns` and `monocle` the delta is 0: the layout is unchanged and the window returns to its tile |
| 4 | The menu lists the workspaces that have open apps | Only when **more than one workspace is configured** (`summaries()` returns nothing otherwise) |
| 5 | — (the Settings → Tiling footer, not the README) | The footer still says "Next layout in Shortcuts cycles through them on the fly", referring to the removed `layout next` action: stale UI text in `TilingView.swift` |

## Undocumented in the README

- `move-to-scratchpad <App>` exists (the README shows only the argument-less form); it is what Settings writes for *To tiling and back*.
- With more than one workspace configured, the menu bar icon is replaced by the workspace shown on each display (`1 2`, the focused display's workspace in a filled box).
- Mouse buttons must be in 2…31; 0/1 produce a config error.
- Unknown JSON keys are silently ignored; values are clamped (`gap`/`padding` ≥ 0, `masterRatio` 0.1…0.9, `scratchpad` sizes 0.2…1).
- The `tiling` action and layout changes are runtime-only: they are not written to the file, and a reload restores the file's values.
- While the keyboard is locked the tap also listens to every key event and `NX_SYSDEFINED`.
- Architecture tree omits `Keyboard/CapsLock`, `KeyboardLayout`, `KeyboardLock`, `Core/AppLauncher`, `RemapTarget`, `ConfigWriter`, `SystemActions`, `App/MainMenu`.
- Note: there is no `scripts/bundle.sh`; `make app` builds the bundle.
