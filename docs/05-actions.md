# 5. Actions

Actions are `verb [argument]` strings used in `keyboard.bindings[].action` and `mouse.buttons[].action`. They are parsed **once at config load** (`Action.parse`):
an unknown action or bad arguments is a config error. The verb is case-insensitive; leading/trailing spaces are ignored. Actions run on the **main thread** (`ActionRunner`).

Window-manager commands only work while tiling is on (`running`), otherwise they do nothing (exception: `resize` on a floating window).

## Windows and layout

| Action | Arguments | Effect |
|---|---|---|
| `focus` | `left` \| `right` \| `up` \| `down` | Focus the nearest window in that direction among all visible ones (other displays and floating windows included). Windows overlapping on the perpendicular axis are preferred. |
| `swap` | `left` \| `right` \| `up` \| `down` | Move the focused window. In `columns` it stacks/unstacks/reorders (see [Tiling](06-tiling.md#columns-layout)); in other layouts it swaps place, weight and workspace with the neighbouring window (across displays too). Ignored for floating windows. |
| `swap master` | — | Swap the focused window with the first (master) window of its workspace. |
| `layout` | `tall` \| `wide` \| `columns` \| `monocle` | Change the layout of the focused display (not saved to the file). |
| `ratio` | signed number, e.g. `+0.05`, `-0.05` | Change the focused display's master ratio; clamped to 0.1…0.9. |
| `float` | — | Toggle the focused window between floating and tiled. From then on the user's choice beats config rules (`userOverride`). |
| `resize` | `width` \| `height` and points, e.g. `resize width +50` | Grow/shrink the focused window. Floating: resized directly (minimum 160×100). Tiled: moves the master/column split or changes the window's share of the stack/column (see [Tiling](06-tiling.md#resize)). |
| `tiling` | — | Turn tiling on/off at runtime (not written to the file). |
| `retile` | — | Recompute the layout now. |

## Workspaces and displays

| Action | Arguments | Effect |
|---|---|---|
| `workspace` | `<n>` (from 1) \| `back-and-forth` | Show workspace n on *its* display and focus it; `back-and-forth` returns to the last focused workspace. |
| `move-to-workspace` | `<n>` (from 1) | Move the focused window (only it) to workspace n. |
| `focus-display` | — | Focus the window of the workspace shown on the next display (wraps around). Needs more than one display. |
| `move-workspace-to-display` | — | Move the whole focused workspace (windows and arrangement) to the next display, where it is now "at home". Needs more than one display. |

Workspace numbers are 1-based; out-of-range values are ignored at runtime. The same commands are available as each workspace's `switch`/`move` (`workspaces[]`), which compile to `workspace n` and
`move-to-workspace n`. Details in [Workspaces and displays](07-workspaces-and-displays.md).

## Scratchpad

| Action | Arguments | Effect |
|---|---|---|
| `scratchpad` | `<App name or bundle id>` | Show/hide the app's scratchpad window, opening the app if needed. |
| `scratchpad` | (none) | Show/hide the windows sent to the scratchpad. |
| `move-to-scratchpad` | (none) | Send the focused window to the scratchpad, or from there back into the tiling of the current workspace. |
| `move-to-scratchpad` | `<App name or bundle id>` | Same for that app's window (opens the app if it is not running). This is the form Settings writes (*To tiling and back*). |

Details in [Scratchpad](08-scratchpad.md).

## Apps, commands, keys

| Action | Arguments | Effect |
|---|---|---|
| `launch` | `<App name or bundle id>` | Open or bring the app forward. Looks up the bundle id first, then an `.app` of that name in `/Applications`, `/System/Applications`, `/System/Applications/Utilities`, `/Applications/Utilities`, `~/Applications`. If not found it logs an error. |
| `shell` | `<command>` | Run the command with `/bin/sh -c`; stdout and stderr discarded; the process is tracked until it ends. Requires an argument. |
| `key` | `<combo>`, e.g. `key cmd+shift+4` | Send a synthetic key combination. Symbols are translated to the active layout ([Keyboard](03-keyboard.md#keyboard-layouts-and-symbols)). |
| `reload` | — | Reload `config.json`. |
| `none` | — | Does nothing: disables the key or button it is bound to. |

## Mouse, system and media

| Action | Arguments | Effect |
|---|---|---|
| `navigate` | `back` \| `forward` | Back/forward using the frontmost app's menu item ([Mouse](04-mouse.md#navigate-backforward)). |
| `system` | `mission_control` \| `app_windows` \| `show_desktop` | Mission Control, app windows, show desktop, via `CoreDockSendNotification` (works even when the system shortcuts are disabled or changed). |
| `media` | `play_pause` \| `next` \| `previous` \| `volume_up` \| `volume_down` \| `mute` | Media keys as `NX_SYSDEFINED` events (key down + key up). |
| `click` | modifiers, e.g. `click cmd` | Left click under the pointer with those modifiers. Empty argument = no modifiers; unknown modifier = error. |

## Typical error messages

| Message | Cause |
|---|---|
| `unknown action '…'` | verb not recognised |
| `expected left/right/up/down in '…'` | `focus`/`swap` without a valid direction |
| `unknown layout in '…'` | `layout` with a wrong name |
| `expected a number in '…'` | `ratio` without a number |
| `expected a workspace number in '…'` | `workspace`/`move-to-workspace` without a number ≥ 1 |
| `expected 'resize width\|height <points>' in '…'` | malformed `resize` |
| `missing argument in '…'` | `launch`/`shell`/`key` without an argument |
| `expected back/forward in '…'` | `navigate` |
| `unknown system action …` / `unknown media key …` | unknown argument |

## Removed actions

`display` (move the window to the next display) and `layout next` (next layout) were removed (commit `ab0bd52`): a config using them gets `unknown action 'display'` / `unknown layout in 'layout next'`.
To bring a window to another display use the **Move window here** shortcut of the workspace that lives on that display (`move-to-workspace n`); pick the layout from Settings or the menu bar.
`focus-display` and `move-workspace-to-display` still exist.
