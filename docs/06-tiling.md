# 6. Tiling

Tiling is implemented by `Tiling/WindowManager.swift` (and its `WindowManager+*.swift` extensions), `Layout.swift` and `ColumnLayout.swift`. Enable it with `tiling.enabled` (default `true`) or the *Tile windows* switch.
When it is off, HyperSpace stops observing apps, brings every parked window back and discards its window state.

## What gets tiled

**Standard windows**: role `AXWindow`, subrole `AXStandardWindow`, and a settable position. **Dialogs** (subrole `AXDialog`/`AXSystemDialog`, movable) are tracked too, as floating windows of their parent (see [Dialogs](#dialogs)). Sheets, panels and popovers are ignored.
Windows are described on the app's own AX queue (`AX.probe`: role, subrole, title, frame, the app's main window), not on the main thread; a window AX does not describe yet (no subrole) is looked at again after 0.2, 0.4, 0.8, 1.6 and 3.2 s.
Excluded from a retile: minimized windows, hidden apps, windows on other macOS Spaces (not in the on-screen list), **native full-screen windows** (a frame that covers a whole display),
floating windows and scratchpad windows. Windows without a CGWindowID are skipped (and noted in the debug report).
New windows join the end of the tiling order; the first window of a workspace is its **master**.

## Layouts

Set `tiling.layout` (default `columns`); each display has its own layout and ratio at runtime (`layout …`, `ratio …` actions; Settings sets the default).
The area is the display's `NSScreen.visibleFrame` (menu bar and Dock excluded), flipped to AX coordinates against the main display, shrunk by `padding` on every side (ignored if it would leave no room); `gap` separates windows. No layout uses fixed screen coordinates.

| Layout | Arrangement |
|---|---|
| `tall` | master on the left (width `(W − gap) × ratio`), the others stacked vertically on the right |
| `wide` | master on top (height `(H − gap) × ratio`), the others side by side below |
| `columns` | i3-style: columns side by side, each a vertical stack. No master ratio |
| `monocle` | every window gets the whole area (stacked on top of each other); focus decides which is in front |
| `accordion` | windows on top of each other, all the same size; the focused one in front, the ones before it aligned to the left edge and the ones after it to the right edge, so `accordionPadding` points (default 30) of each neighbour stay visible on the sides. Focusing another window re-centres the stack |

- Windows sharing a split (the stack in `tall`/`wide`, all columns, the rows of a column) are sized by **weights** (default 1 each), changed by [resizing](#resize). The last tile absorbs rounding.
- `masterRatio` (default 0.55, clamped 0.1…0.9) applies to `tall`/`wide`. Actions `ratio ±x` change it per display, clamped the same way.
- A window with a minimum size that cannot take its tile is not retried in a loop (see [snap back](#drag-and-drop-and-snap-back)).

### Columns layout

Each workspace has a `ColumnLayout`: new windows get their own column on the right; closed windows leave the arrangement. `swap` (`hyper+arrows` by default) means:

| Key | Window shares its column | Window is alone in its column |
|---|---|---|
| **left / right** | leaves the column into a new column on that side | swaps its column with the neighbouring one |
| **down / up** | swaps with the window below/above in the column | joins the neighbouring column (the left one first) at the bottom/top |

After a `swap` in columns the moved window's weight is reset to 1.

### Accordion on any layout

The `accordion` action (Settings → Shortcuts → *Stack windows as an accordion*) stacks the windows of the focused workspace as an accordion without changing the display's layout, and unstacks them when pressed again (like i3's tabbed/stacked containers).

- **`columns`**: all the workspace's windows go into **one accordion column** (in order, the focused one in front). `swap left/right` takes the window **out** into a new column beside the accordion, so moving windows out one by one puts them back side by side the way you want; `swap up/down` reorders the stack; `focus left/right` goes through the stack. An accordion left with one window is a normal column again. Pressing `accordion` inside an accordion gives each of its windows its own column. New windows opened while the accordion has the focus join it. Accordion columns are saved with the columns in `workspaces.json` (`accordions`).
- **`tall`/`wide`/`monocle`**: the whole workspace is drawn as an accordion; `focus left/right` goes through it, and any `swap` puts the workspace back in its layout. Saved as `accordionWorkspaces`.
- The visible edges use `accordionPadding`.

## Focus, swap, master

In `accordion`, `focus left/right` and `swap left/right` go to / exchange with the previous or next window of the stack (in order); past either end `focus` goes on to the nearest window on another display.

- **`focus <dir>`**: among all visible windows of displayed workspaces (floating and other displays included) it picks the nearest one in that direction by window centers,
  preferring windows that overlap on the perpendicular axis (others are penalised).
- **`swap <dir>`**: in `columns` as above; in the other layouts it finds the neighbour among *tiled* visible windows (also on other displays) and exchanges order, weight, workspace and frames — so the window can cross displays.
- **`swap master`**: exchanges the window with the first tiled window of its workspace.
- **`float`**: toggles floating for the focused window; a floating window is raised and focused. The choice is remembered (and saved) and config reloads no longer override it.

## Resize

`resize width|height ±points` (the Settings Shortcuts page uses ±50):

- **Floating window** (tiling on): resized directly (minimum 160 wide, 100 high). With tiling off the command does nothing: no window is tracked.
- **`tall`/`wide`**: along the master/stack split, the ratio changes by `delta / area length` (the master grows with a positive delta; a stack window grows by shrinking the master).
  Along the stack, the window's weight changes (needs a stack of at least 2 windows, and the window cannot be the master).
- **`columns`**: *width* changes the window's column weight (needs 2+ columns); *height* changes the window's weight in its column (needs 2+ windows in it).
- **`monocle`**, **`accordion`**: nothing.
- Weights are computed so the other items keep their relative sizes; every item keeps at least 80 pt.

## Gaps and padding

`gap` = space between windows, `padding` = margin around the display's visible area. Both 0–64, in the file (clamped) and in the UI (steps of 2). The layout thumbnails in *Settings → Tiling* are drawn to scale with these values.

## Floating windows and rules

A window floats if any of these holds (rules 2–3: `TilingConfig.floats`):

1. it is **dialog-like** (`AX.isDialogLike`), in any app: a standard window with a close button but no full-screen button and a missing or disabled zoom button, such as the Finder's Empty Trash and Copy progress windows or fixed-size alerts. Windows with no title-bar buttons at all (borderless terminals) still tile;
2. its bundle id is in `tiling.floating`;
3. a `floatingWindows` rule matches: `app` (bundle id; absent/empty = any app) and `title` (case-insensitive *substring* of the window title; an empty title never matches);
4. you toggled it with `float` (a user override: it wins over the rules and is saved in `workspaces.json`, so it survives restarts).

```json
"floating": ["com.apple.finder"],
"floatingWindows": [
  { "app": "com.autodesk.fusion360", "title": "Preferences" },
  { "title": "Picture-in-Picture" }
]
```

- Title rules are applied when the window is tracked and again on every **title change** (many windows get their title a moment after opening), unless the window has a user override.
- On a config reload, rules are re-evaluated for all windows without a user override.
- Floating windows are not moved by the layout. When their workspace is hidden they are parked like tiled ones; when the workspace comes back, they return to their frame (or are centred on the display now showing the workspace, if their frame was elsewhere).
- In *Settings → Window Rules → Floating*: an app with no title = all its windows; "Any app" with a title = title rule for every app.

## Dialogs

- A dialog joins the **workspace of its parent**: the app's main window (`AXMainWindow`), else its window focused last in a shown workspace, else any of its windows. It is parked and shown with that workspace, and moves with the parent on `move-to-workspace`.
- When the parent's app **comes to the front** (⌘Tab, a click, the Dock, or HyperSpace focusing it) its on-screen dialogs are raised above it (`AXRaise`). Focus changes inside the same app do not raise them, so a non-modal panel never locks you out of its window.
- Dialog-like standard windows (no zoom/full-screen button) get the same parent and workspace.

## Drag and drop and snap back

- **Modifier + drag** (`mouse.dragModifier`): see [Mouse](04-mouse.md#modifier--drag-dragmodifier). Dropping a tiled window on another tiled window swaps them; on another display it joins that display's workspace; resizing in `tall`/`wide` moves the split.
- **Snap back**: if you move or resize a tiled window by hand (AX `moved`/`resized` notifications), it returns to its tile **once the mouse button is released** (HyperSpace waits, checking every 0.15 s, until
  no mouse button is down, then retiles). Not applied to floating, scratchpad or parked windows, and ignored for 0.5 s after HyperSpace's own move (so a window that cannot take its tile does not loop).
  To really move a window use the shortcuts or the modifier drag.

## Retile triggers

New/closed/minimized windows, app hide/unhide, Space change (rescan), display changes, focus changes (workspace follow), config reload, `retile`, layout/ratio/resize/swap actions, snap back.
Bursts are coalesced (30 ms). `retile` also: parks windows of non-displayed workspaces, shows floating windows of displayed ones, and saves the state (2 s later, only if it changed).

## Windows in apps with slow or odd AX behaviour

- Apps that fail to answer AX right after launch are retried every 0.5 s up to 20 times; two extra rescans run 2 s and 6 s after start.
- Moves use `size → position → size` across displays (the first resize lets the window fit the destination, the second fixes apps that clamp to the old screen); within a display only what changed, shrinking before moving.
- Across displays (moving a window to a workspace shown on another display, `swap` with a window there, a workspace moved to another display):
  - the frame is read back right after the writes and written once more (position, then size) if the app kept another size or position;
  - the workspace is retiled again after 0.3 s and 0.8 s: many apps resize themselves for the new display's scale a moment after the move, too soon (< 0.5 s) to be taken for a hand resize and snapped back. Floating and scratchpad windows are left alone.
- `AXEnhancedUserInterface` is switched off during a move (it makes some apps animate every AX resize) and restored after.
- If the app does not take focus within 0.15 s, HyperSpace activates it and retries.
- Failures are recorded in "Recent issues" of *Copy Debug Info*.
