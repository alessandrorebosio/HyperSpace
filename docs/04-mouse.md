# 4. Mouse

Three features, all handled by the event tap (they need Accessibility; see [Architecture](01-architecture.md)):

```json
"mouse": {
  "reverseScroll": true,
  "dragModifier": "ctrl+alt",
  "buttons": [
    { "button": 3, "action": "navigate back" },
    { "button": 4, "action": "navigate forward" },
    { "button": 2, "modifiers": "cmd", "action": "key cmd+w" }
  ]
}
```

## Reverse scroll (`reverseScroll`)

- Flips the sign of both axes (integer, point and fixed-point deltas) **only for discrete wheels**: events with `scrollWheelEventIsContinuous == 0`.
  Trackpad and Magic Mouse (continuous scroll) keep the system's natural direction.
- The tap subscribes to scroll events only if the option is on. Default `false`. In Settings: *Mouse → Scrolling → Reverse scroll wheel*.

## Buttons (`buttons`)

- `button` is the CGEvent button number: **2 = middle, 3 = back, 4 = forward**, then 5, 6, … up to **31**. Left (0) and right (1) cannot be mapped
  (error `mouse button must be between 2 and 31`), otherwise the mouse would become unusable. Settings label buttons above 4 as "Button N+1".
- `modifiers` (optional): modifiers only (`cmd`, `alt`, `ctrl`, `shift`, `hyper`, `meh`). The mapping fires only with **exactly** those modifiers.
- `action`: any [action](05-actions.md). `none` disables the button (the click is swallowed and does nothing).
- When a button is mapped, both press and release are swallowed; the action fires on press.
- Two rows with the same button and modifiers: the last wins (Settings shows a warning).
- Modifiers held by a modifier-only carrier (e.g. caps lock → ⌃⌥⇧) also count for buttons.

### Ready-made actions in Settings

*Settings → Mouse → Buttons → Add Button*: click the mouse button over the window (hold modifiers to include them), then press the key combination to send, pick a ready-made action from the menu,
or choose **Disable Button**. Mappings are suspended during capture so the button reaches the window.

| Group | Entries → action |
|---|---|
| **Navigation** | Back → `navigate back`, Forward → `navigate forward` |
| **Browser** | Open Link in New Tab → `click cmd`; Reload → `key cmd+r`; New Tab → `key cmd+t`; Close Tab → `key cmd+w`; Reopen Closed Tab → `key shift+cmd+t`; Next Tab → `key ctrl+tab`; Previous Tab → `key ctrl+shift+tab` |
| **Edit** | Copy/Paste/Cut/Undo → `key cmd+c/v/x/z`; Redo → `key shift+cmd+z`; Zoom In/Out → `key cmd+=` / `key cmd+-` |
| **System** | Mission Control, App Windows, Show Desktop → `system …`; Spotlight → `key cmd+space`; Screenshot → `key shift+cmd+5`; Toggle Full Screen → `key ctrl+cmd+f`; Lock Screen → `key ctrl+cmd+q` |
| **Media** | Play/Pause, Next/Previous Track, Volume Up/Down, Mute → `media …` |

### `navigate back|forward`

Universal Back/Forward, independent of language and layout (`Navigation` in `SystemActions.swift`):

1. **Xcode** (`com.apple.dt.Xcode`): sends ⌃⌘← / ⌃⌘→.
2. Otherwise it presses, through Accessibility, the frontmost app's **Back/Forward menu item**. The item is recognised by identifier (`Back`, `goBack:`, `GoBack`, …), or by unlocalised
   shortcut (⌘[ / ⌘] or ⌃- / ⌃⇧-), or by title in several languages (English, Italian "indietro"/"vai indietro"/"avanti"/"vai avanti", German, French, Spanish, Dutch, Swedish; only items that have a shortcut qualify).
   The menu bar is searched to depth 2 first, then up to 5 (to avoid descending straight into history/bookmark submenus). The found item is cached per app (cache pruned every 5 minutes of apps no longer running).
3. If the app has no such item: sends a real back/forward mouse button (button 3/4), which Chrome, Firefox, Electron and JetBrains apps handle themselves.

### `click <modifiers>`

A left click at the pointer position with those modifiers held (e.g. `click cmd` = ⌘-click, opens a link in a new tab).

## Modifier + drag (`dragModifier`)

- Sets the modifiers (e.g. `ctrl+alt`). With **exactly** those modifiers held: **left drag = move the window**, **right drag = resize**. The click never reaches the window (it and its drag and release are swallowed).
- On press, HyperSpace finds the window under the pointer (`AXUIElementCopyElementAtPosition`), focuses it and remembers its position and size. During the drag it moves/resizes through AX
  (on the main thread; only the latest position travels from the tap). Resize has a 160×100 minimum.
- No retile happens while dragging (`drag != nil`).
- It works on windows of any app, even with tiling off (then it just moves/resizes).

On release, for a window **in the tiling** (not floating, tiling on):

| Gesture | Effect |
|---|---|
| Move and drop **on another tiled window** | the two windows swap places (and columns, if in the same workspace); if they were in different workspaces the window joins the other one's workspace |
| Move and drop **on another display** (not on a window) | the window joins the workspace shown on that display |
| Move and drop elsewhere | it returns to its place |
| Resize (`tall`/`wide` layout) | moves the master/stack split: the ratio changes by `Δ / display width` (or height), in the right direction for the master or a stack window |
| Resize (`columns`/`monocle` layout) | no effect on the layout: the window returns to its place |

A **floating window** stays where you leave it. See also [Tiling](06-tiling.md#drag-and-drop-and-snap-back).
