# 8. Scratchpad

Like i3's scratchpad: a window that lives **out of the tiling and out of the workspaces**, shown on demand centred above everything else. Implemented in `WindowManager`
(`toggleScratchpad`, `moveToScratchpad`, `showScratchpad`, `hideScratchpad`), in `Tiling/WindowManager+Scratchpad.swift`.

## Shortcuts

| Action | Meaning |
|---|---|
| `scratchpad <App>` | Per-app scratchpad (App = name or bundle id). Show/hide that app's scratchpad window. |
| `move-to-scratchpad <App>` | Send that app's window to the scratchpad, or from there back to the tiling. |
| `scratchpad` | Generic: show/hide the windows that were sent to the scratchpad. |
| `move-to-scratchpad` | Generic: send the focused window to the scratchpad, or back to the tiling. |

```json
{ "keys": "meh+x",   "action": "scratchpad com.anthropic.claudefordesktop" },
{ "keys": "hyper+x", "action": "move-to-scratchpad" }
```

In *Settings → Window Rules → Scratchpad Apps* each app has two shortcuts: **Show / hide** (`scratchpad <bundle id>`) and **To tiling and back** (`move-to-scratchpad <bundle id>`).

## Per-app behaviour (`scratchpad <App>`)

1. The app name/bundle id is resolved (`AppLauncher.bundleID`); if not found, a note goes to the debug report.
2. If the app already has scratchpad windows: one of them shown and focused → **all hidden**; otherwise → **all shown**, the one you worked in last on top.
3. Else, if the app has a window in the tiling: the focused one (or the first) **becomes the scratchpad** and is shown.
4. Else (app not open, or no window): the app is launched and its **next window** becomes the scratchpad window (valid for 30 s), shown as soon as it is tracked.

## Generic behaviour (`scratchpad` without argument)

Among the windows in the scratchpad: if one is shown and focused → hide it; else if one is shown → focus it; else show the first hidden one.

## Move to scratchpad (`move-to-scratchpad`)

- Without argument it acts on the focused window; with an app, on that app's scratchpad window, or else its focused/first window; with the app not open, it opens it.
- A window **in the scratchpad** goes back into the tiling of the workspace *you are on* (the focused display's), and is focused. A window **in the tiling** becomes a scratchpad window and is shown.

## Showing, hiding, size

- **Size**: a fraction of the focused display's visible area: `"scratchpad": { "width": 0.6, "height": 0.7 }` (default; each value clamped to 0.2…1; also not exposed in Settings, it is config only).
- **Where**: centred on the display with focus. It stays visible until you hide it, and closes (with its dialogs) when you change workspace; `focus-display` and moving a workspace to another display do not close it. Pressing the shortcut of the workspace already focused changes nothing. ⌘Tab to a hidden scratchpad window shows it automatically (if more than 0.6 s after one of HyperSpace's own focus changes).
- **Hiding**: the window is parked like a hidden workspace's windows (bottom-right corner) and focus goes back to a window of the workspace shown on the display it was on, so the pointer stays on that display.
- Scratchpad windows are excluded from layouts, from the workspace summaries in the menu, from `focus`-by-workspace candidates, and from snap-back.
- The scratchpad state (which windows) is **saved** in `workspaces.json` (`scratchpad: true`) and restored across restarts.

## Centring and overlap logic

Some apps (terminals sizing in steps, apps with a minimum size) do not take the exact size asked for. After placing the window HyperSpace reads the size it really took (on the app's AX queue):

1. If it differs by more than 1 pt from the requested frame, HyperSpace **asks once more** after 0.1 s (a retry scheduled on the app's AX queue; the queue is not blocked meanwhile): coming from another display (a different scale) some apps resize themselves a moment after the move, so the first read is not their best.
   If it still differs, that **actual size is remembered** together with the target frame (`scratchpadFitted`), but only when it is within 10% of the target in each dimension (`isNearFit`): a size far off (a move that failed, a window that refused) would otherwise be passed on to every later show.
2. The window is **re-centred on the size it took** (moved only if more than 1 pt off).
3. **Other scratchpad windows adopt the same size**: as long as the target frame (display + configured fractions) is the same, new scratchpad windows are placed with the remembered size, centred in the target. They therefore **overlap exactly** instead of peeking out from behind each other.

If the display or the configured fraction changes, the target differs and the remembered size is ignored.

## Notes

- **Window level**: HyperSpace cannot change the `NSWindow.Level` (`.normal`/`.floating`) of another app's window: there is no public API for it (only the private SkyLight calls that yabai makes through its scripting addition, which needs SIP partly off). So a scratchpad window is hidden by parking it, not sent behind at a lower level.

- Windows created while their app is the scratchpad target are shown even when their workspace is not displayed.
- **New windows opened from a scratchpad window** (⌘N, or ⌘T in a terminal that opens tabs as windows) join the scratchpad instead of the tiling: when the app is frontmost and the window of that app focused last is a shown scratchpad window. They are shown at the scratchpad frame and toggle together with it.
- **Dialogs of a scratchpad window** (sheets, alerts, settings panels attached to it) are never tied to a workspace: they are hidden and shown with their window, and focusing one does not switch workspace.
- `workspace`/focus candidates never include scratchpad windows; a scratchpad window does not belong to any visible workspace even though it keeps a workspace index.
