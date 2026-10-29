# 2. Configuration

## File, creation and reload

- **Path**: `~/.config/hyperspace/config.json` (`ConfigStore.url`).
- **Creation**: on first launch (or from *Edit Config…*) if the file is missing, the default config (`DefaultConfig.json`) is written.
- **Automatic reload**: the file is watched with a kqueue `DispatchSource` (`write`, `extend`, `delete`, `rename`), at zero cost while untouched. Several events per save
  are coalesced with a 0.15 s delay. If the editor saves by atomic rename the watcher re-attaches itself; if the file is briefly missing it retries after 1 s.
- **Manual reload**: the [`reload`](05-actions.md) action (`hyper+escape` in the default config).
- What a reload applies: HID remaps always; tap and tiling only with the Accessibility permission (see [Architecture](01-architecture.md)).
- **Edits from the UI**: the Settings window rewrites the file with `ConfigWriter` (only touched keys change, stable key order, one line per binding/remap);
  the watcher then applies it like a manual edit. The file gets reformatted and **unknown keys are preserved**. JSON has no comments.

## Errors

- Invalid JSON → `invalid JSON: …`; wrong type or missing required key → `invalid config: …`.
- Semantic errors (unknown action, key or layout, rule for a missing workspace, too many combinations…) → a `ConfigError` message.
- On error the menu bar icon becomes ⚠︎ (and is shown even when tiling is off), the top of the menu shows `Config error: …` (click: opens the file) and **the last valid
  config stays active**. The error clears on the next successful load.
- **Unknown JSON keys are silently ignored** (plain `Decodable`): a typo such as `"gaps"` instead of `"gap"` produces no error and the default applies.
- A repeated binding (same key and modifiers) is not an error: **the last one wins**. Compile order: `keyboard.bindings` in order first, then workspace shortcuts (`switch`, `move`),
  which therefore win over an identical binding.

## Full structure

```json
{
  "keyboard": {
    "hyperKey": "caps_lock",
    "remap":    [ { "from": "...", "to": "...", "keyboard": "all" } ],
    "bindings": [ { "keys": "...", "action": "..." } ]
  },
  "mouse": {
    "reverseScroll": false,
    "dragModifier": "ctrl+alt",
    "buttons": [ { "button": 3, "modifiers": "", "action": "navigate back" } ]
  },
  "tiling": {
    "enabled": true,
    "layout": "columns",
    "gap": 8,
    "padding": 8,
    "masterRatio": 0.55,
    "mouseFollowsFocus": true,
    "scratchpad": { "width": 0.6, "height": 0.7 },
    "floating": [ "com.apple.calculator" ],
    "floatingWindows": [ { "app": "com.autodesk.fusion360", "title": "Preferences" } ],
    "workspaces": [ { "name": "1", "switch": "meh+1", "move": "hyper+1" } ],
    "assign": [ { "app": "com.spotify.client", "workspace": "music" } ]
  }
}
```

Every section and key is optional.

### `keyboard`

| Key | Type | Default | Notes |
|---|---|---|---|
| `hyperKey` | string | — | Shorthand for `{ "from": <key>, "to": "hyper" }` on every keyboard, inserted first among the remaps. Saving from Settings converts it into a normal remap. |
| `remap[].from` | string | required | Physical key name ([key names](03-keyboard.md#key-names)). |
| `remap[].to` | string | required | A key, `none`, or a combination `mod+mod[+key]`. |
| `remap[].keyboard` | string | `all` | `all`, `builtin` (aliases `built-in`, `internal`), `external`, or part of the product name (case-insensitive). |
| `bindings[].keys` | string | required | `mod+mod+key`, the last token is the key. |
| `bindings[].action` | string | required | See [Actions](05-actions.md). |

### `mouse`

| Key | Type | Default | Notes |
|---|---|---|---|
| `reverseScroll` | bool | `false` | Reverses only notched wheels (not trackpad/Magic Mouse). |
| `dragModifier` | string | absent (off) | Modifiers only, e.g. `ctrl+alt`. Empty string = off. |
| `buttons[].button` | int | required | **2 to 31** (0 and 1 are left/right click: error). 2 = middle, 3 = back, 4 = forward. |
| `buttons[].modifiers` | string | `""` | Modifiers only; the mapping applies only with exactly those. |
| `buttons[].action` | string | required | See [Actions](05-actions.md). |

### `tiling`

| Key | Type | Default | Validation |
|---|---|---|---|
| `enabled` | bool | `true` | — |
| `layout` | string | `columns` | `tall`, `wide`, `columns`, `monocle` (case-insensitive); anything else → error |
| `gap` | number | `8` | minimum 0 |
| `padding` | number | `8` | minimum 0 |
| `masterRatio` | number | `0.55` | clamped to 0.1…0.9 |
| `mouseFollowsFocus` | bool | `true` | — |
| `scratchpad.width` / `.height` | number | `0.6` / `0.7` | fractions of the display's visible area, clamped to 0.2…1 |
| `floating` | `[string]` | `[]` | Bundle ids that are never tiled |
| `floatingWindows[]` | `{ app?, title }` | `[]` | `title` required and non-empty (entries with an empty title are dropped); `app` absent or empty = any app |
| `workspaces[]` | `{ name?, switch?, move? }` | `[]` | missing/empty `name` = 1-based position; empty `switch`/`move` = no shortcut |
| `assign[]` | `{ app, workspace }` | `[]` | `workspace` is a name or a 1-based number; if it does not exist → error |

The UI limits gap and padding to 0–64 in steps of 2, but the file accepts any value ≥ 0.

Workspace notes: with `workspaces` empty there are still `max(1, number of displays)` workspaces, with no shortcuts. If fewer workspaces are configured than displays there is still one per display;
those past the last configured are named by their number. See [Workspaces and displays](07-workspaces-and-displays.md).

## Default config

Written on first launch (`DefaultConfig.swift`):

```json
{
  "keyboard": {
    "remap": [ { "from": "caps_lock", "to": "hyper" } ],
    "bindings": [
      { "keys": "hyper+h", "action": "focus left" },
      { "keys": "hyper+j", "action": "focus down" },
      { "keys": "hyper+k", "action": "focus up" },
      { "keys": "hyper+l", "action": "focus right" },
      { "keys": "hyper+left",  "action": "swap left" },
      { "keys": "hyper+down",  "action": "swap down" },
      { "keys": "hyper+up",    "action": "swap up" },
      { "keys": "hyper+right", "action": "swap right" },
      { "keys": "hyper+return", "action": "swap master" },
      { "keys": "hyper+f", "action": "float" },
      { "keys": "hyper+minus", "action": "ratio -0.05" },
      { "keys": "hyper+equal", "action": "ratio +0.05" },
      { "keys": "hyper+r", "action": "retile" },
      { "keys": "hyper+t", "action": "launch Terminal" },
      { "keys": "hyper+escape", "action": "reload" }
    ]
  },
  "mouse": {
    "reverseScroll": false,
    "dragModifier": "ctrl+alt",
    "buttons": [
      { "button": 3, "action": "navigate back" },
      { "button": 4, "action": "navigate forward" }
    ]
  },
  "tiling": {
    "enabled": true, "layout": "columns", "gap": 8, "padding": 8, "masterRatio": 0.55,
    "floating": [ "com.apple.systempreferences", "com.apple.calculator", "com.apple.ActivityMonitor" ]
  }
}
```

The default config defines **no** workspaces and no workspace/display shortcuts.

## Example

Three workspaces, assigned apps, a scratchpad and a few remaps:

```json
{
  "keyboard": {
    "remap": [
      { "from": "caps_lock", "to": "hyper" },
      { "from": "right_option", "to": "escape" },
      { "from": "left_command", "to": "left_option", "keyboard": "external" },
      { "from": "left_option",  "to": "left_command", "keyboard": "external" }
    ],
    "bindings": [
      { "keys": "hyper+h", "action": "focus left" },
      { "keys": "hyper+l", "action": "focus right" },
      { "keys": "hyper+tab", "action": "move-workspace-to-display" },
      { "keys": "hyper+x", "action": "move-to-scratchpad" },
      { "keys": "meh+x", "action": "scratchpad com.anthropic.claudefordesktop" },
      { "keys": "hyper+return", "action": "launch Terminal" }
    ]
  },
  "tiling": {
    "workspaces": [
      { "name": "1",     "switch": "meh+1", "move": "hyper+1" },
      { "name": "music", "switch": "meh+2", "move": "hyper+2" },
      { "name": "cad",   "switch": "meh+3", "move": "hyper+3" }
    ],
    "assign": [
      { "app": "com.spotify.client", "workspace": "music" },
      { "app": "com.autodesk.fusion360", "workspace": "cad" }
    ],
    "floatingWindows": [ { "title": "Picture-in-Picture" } ],
    "scratchpad": { "width": 0.6, "height": 0.7 }
  }
}
```

## What is not in the config

- **Keyboard lock duration**: a Mac preference (`UserDefaults`, key `keyboardLockMinutes`; choices 1/3/5/10 minutes or never; default 3).
- **Workspace state**: `~/Library/Application Support/HyperSpace/workspaces.json` ([page 7](07-workspaces-and-displays.md#saved-state-and-restore)).
- **Per-display layout and master ratio, tiling on/off at runtime**: changed by actions (`layout …`, `ratio …`, `tiling`) or the menu; they stay in memory and are **not written** to the file.
  A reload that changes `layout`/`masterRatio` clears the per-display values. The `tiling` action does not change `tiling.enabled` in the file: a reload brings back the file's value.
- **Settings window frame**: saved by AppKit (`HyperSpaceSettings`).
- **Launch at login**: handled by `SMAppService.mainApp`.
