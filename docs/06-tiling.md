# 6. Tiling

Tiling is implemented by `Tiling/WindowManager.swift`, `Layout.swift` and `ColumnLayout.swift`. Enable it with `tiling.enabled` (default `true`) or the *Tile windows* switch.
When it is off, HyperSpace stops observing apps, brings every parked window back and discards its window state.

## What gets tiled

Only **standard windows** (`AX.isStandardWindow`): role `AXWindow`, subrole `AXStandardWindow`, and a settable position. Dialogs, sheets, panels and popovers are ignored.
Excluded from a retile: minimized windows, hidden apps, windows on other macOS Spaces (not in the on-screen list), **native full-screen windows** (a frame that covers a whole display),
floating windows and scratchpad windows. Windows without a CGWindowID are skipped (and noted in the debug report).
New windows join the end of the tiling order; the first window of a workspace is its **master**.

## Layouts

Set `tiling.layout` (default `columns`); each display has its own layout and ratio at runtime (`layout …`, `ratio …`, the menu, Settings).
The area is the display's visible frame (menu bar and Dock excluded) shrunk by `padding` on every side; `gap` separates windows.

| Layout | Arrangement |
|---|---|
| `tall` | master on the left (width `(W − gap) × ratio`), the others stacked vertically on the right |
| `wide` | master on top (height `(H − gap) × ratio`), the others side by side below |
| `columns` | i3-style: columns side by side, each a vertical stack. No master ratio |
| `monocle` | every window gets the whole area (stacked on top of each other); focus decides which is in front |

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

## Focus, swap, master

- **`focus <dir>`**: among all visible windows of displayed workspaces (floating and other displays included) it picks the nearest one in that direction by window centers,
  preferring windows that overlap on the perpendicular axis (others are penalised).
- **`swap <dir>`**: in `columns` as above; in the other layouts it finds the neighbour among *tiled* visible windows (also on other displays) and exchanges order, weight, workspace and frames — so the window can cross displays.
- **`swap master`**: exchanges the window with the first tiled window of its workspace.
- **`float`**: toggles floating for the focused window; a floating window is raised and focused. The choice is remembered (and saved) and config reloads no longer override it.

## Resize

`resize width|height ±points` (the Settings Shortcuts page uses ±50):

- **Floating window**: resized directly (minimum 160 wide, 100 high).
- **`tall`/`wide`**: along the master/stack split, the ratio changes by `delta / area length` (the master grows with a positive delta; a stack window grows by shrinking the master).
  Along the stack, the window's weight changes (needs a stack of at least 2 windows, and the window cannot be the master).
- **`columns`**: *width* changes the window's column weight (needs 2+ columns); *height* changes the window's weight in its column (needs 2+ windows in it).
- **`monocle`**: nothing.
- Weights are computed so the other items keep their relative sizes; every item keeps at least 80 pt.

## Gaps and padding

`gap` = space between windows, `padding` = margin around the display's visible area. Both ≥ 0 in the file (0–64 in the UI, steps of 2). The layout thumbnails in *Settings → Tiling* are drawn to scale with these values.

## Floating windows and rules

A window floats if any of these holds (`TilingConfig.floats`):

1. its bundle id is in `tiling.floating`;
2. a `floatingWindows` rule matches: `app` (bundle id; absent/empty = any app) and `title` (case-insensitive *substring* of the window title; an empty title never matches);
3. you toggled it with `float` (a user override: it wins over the rules and is saved in `workspaces.json`, so it survives restarts).

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
- `AXEnhancedUserInterface` is switched off during a move (it makes some apps animate every AX resize) and restored after.
- If the app does not take focus within 0.15 s, HyperSpace activates it and retries.
- Failures are recorded in "Recent issues" of *Copy Debug Info*.
