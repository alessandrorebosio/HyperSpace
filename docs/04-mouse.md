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
- Settings lists the rules in the order of the file and saves them in that order: with two rules for the same button and modifiers the last one wins, so reordering would change which one applies.

### Ready-made actions in Settings

*Settings → Mouse → Buttons → Add Button*: click the mouse button over the window (hold modifiers to include them), then press the key combination to send, pick a ready-made action from the menu,
or choose **Disable Button**. Mappings are suspended during capture so the button reaches the window.

| Group | Entries → action |
|---|---|
| **Navigation** | Back → `navigate back`, Forward → `navigate forward` |
| **Browser** | Open Link in New Tab → `click cmd`; Reload → `key cmd+r`; New Tab → `key cmd+t`; Close Tab → `key cmd+w`; Reopen Closed Tab → `key shift+cmd+t`; Next Tab → `key ctrl+tab`; Previous Tab → `key ctrl+shift+tab` |
| **Edit** | Copy/Paste/Cut/Undo → `key cmd+c/v/x/z`; Redo → `key shift+cmd+z`; Zoom In/Out → `key cmd+=` / `key cmd+-` |
| **System** | Mission Control, App Windows, Show Desktop → `system …`; Spotlight → `key cmd+space`; Screenshot → `key shift+cmd+5`; Toggle Full Screen → `key ctrl+cmd+f`; Lock Screen → `key ctrl+cmd+q` |
| **Media** | Play/Pause, Next/Previous Track, Volume Up/Down, Mute, Brightness Up/Down → `media …` |

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
  on the app's `AXWriter` queue (focus first, then the moves, in order), one write at a time with only the newest point waiting; only the latest position travels from the tap to the main thread. Resize has a 160×100 minimum.
- No retile happens while dragging (`drag != nil`).
- It works on windows of any app, even with tiling off (then it just moves/resizes).

On release, for a window **in the tiling** (not floating, tiling on):

| Gesture | Effect |
|---|---|
| Move and drop **on another tiled window** | the two windows swap places (and columns, if in the same workspace); if they were in different workspaces the window joins the other one's workspace |
| Move and drop **on another display** (not on a window) | the window joins the workspace shown on that display |
| Move and drop elsewhere | it returns to its place |
| Resize (`tall`/`wide` layout) | moves the master/stack split: the ratio changes by `Δ / display width` (or height), in the right direction for the master or a stack window |
| Resize (`columns`/`monocle`/`accordion` layout) | no effect on the layout: the window returns to its place |

A **floating window** stays where you leave it. See also [Tiling](06-tiling.md#drag-and-drop-and-snap-back).

## Trackpad edge sliders (`trackpad`)

Off by default. When on, **one finger slid up or down along the left or right edge** of a trackpad changes what that edge is set to: `volume`, `brightness` (the display's, through the system brightness keys: the built-in display and Apple displays, not other monitors) or `none`. The defaults are brightness on the left, volume on the right.

- Each edge band is 8% of the trackpad's width. A finger put down there is a slider from the start; every 5% of the trackpad's height it moves is one notch (a key press, with the system's volume or brightness indicator), so the full height is 20 notches.
- **The pointer is held still** while the finger is down in the band (`CGAssociateMouseAndMouseCursorPosition`); it may move a pixel or two before the touch is recognised. Moving sideways by more than 5% of the width before the first notch makes it an ordinary pointer move: the hold lifts and the finger is ignored until lifted.
- A second finger (a scroll, a two-finger click) ends the slider until every finger is lifted; a finger that starts outside the bands, or on an edge set to `none`, is never a slider. Clicks and taps are not affected.
- Built-in trackpads and Magic Trackpads are used; the Magic Mouse (whose surface is also a multitouch device) is not. Trackpads connected later are picked up when macOS reports them and after waking.
- The touches come from Apple's private **MultitouchSupport** framework (as in BetterTouchTool or MiddleClick), loaded at run time: the recognition is in `EdgeSliderTracker` (pure, tested), the framework glue in `EdgeSliders`. If the framework is missing or changes, the sliders do nothing and *Copy Debug Info* says so.
- Settings: the **Trackpad** page: the *Edge sliders* switch and a menu per edge.
