# 7. Workspaces and displays

macOS has no public API to manage Spaces, so HyperSpace's workspaces are **virtual**: every window belongs to a workspace, and the windows of workspaces that are not shown
are parked off-screen. Everything below lives in `Tiling/WindowManager.swift` and `WindowManager+Workspaces.swift`.

## Defining workspaces

```json
"tiling": {
  "workspaces": [
    { "name": "1",     "switch": "meh+1", "move": "hyper+1" },
    { "name": "music", "switch": "meh+2", "move": "hyper+2" }
  ]
}
```

- `name` (default: 1-based position), `switch` = shortcut that shows the workspace, `move` = shortcut that moves the focused window there (Settings calls it *Move window here*), `display` = the display it is pinned to (see [Pinned workspaces](#pinned-workspaces)).
- Workspace count: `max(1, configured workspaces, number of displays)`. Workspaces past the configured ones are named with their 1-based number and have no shortcuts.
- Fewer workspaces than before (after a reload): windows of removed ones join the first workspace.
- Actions: `workspace n`, `workspace back-and-forth`, `move-to-workspace n` ([Actions](05-actions.md)).

## One home display per workspace

- **Workspace 1 lives on the main display** (the one with the menu bar), **2 on the second**, 3 on the third, and so on (displays ordered: main first, then left to right, then by `y`). Workspaces beyond the number of displays live on the main display.
- Each display **shows exactly one** of its workspaces (the lowest-numbered one by default), or none if no workspace lives there.
- `workspace n` (**`switchWorkspace`**) shows n on *its* display, remembers what it replaced, and focuses its last focused window (or the first one; with no windows, it moves the pointer to the display
  centre and makes that display the active one by clicking its desktop, see [Empty workspaces](#empty-workspaces)). The menu bar highlights the target workspace right away. The other displays are untouched. The previously focused workspace is remembered for `back-and-forth`.
- Focus moving to another display brings the pointer along (at the centre of the window, or of the display when the workspace is empty), and switching workspace puts it in the middle of the display's visible area (not when the workspace was already the focused one, nor while a mouse button is held); turn it off with `"mouseFollowsFocus": false` (Settings → Tiling → *Pointer follows focus*).

## Pinned workspaces

A workspace can be fixed to a display with `"display"` (Settings → Workspaces → *Display*):

```json
"workspaces": [
  { "name": "code", "display": "LG UltraFine" },
  { "name": "chat", "display": "main" },
  { "name": "web",  "display": "2" }
]
```

- The value is `"main"` (the display with the menu bar), a number (1 = main display, then left to right, as above), the monitor's **name** (exact, else the first display whose name contains it, case-insensitive) or its **UUID** (what Settings writes when two connected monitors have the same name). Empty or missing = not pinned.
- While that display is connected the pin is the workspace's home, before any `move-workspace-to-display` move and before the default rule; `move-workspace-to-display` does nothing on a pinned workspace (a beep). A pin in the config clears a move made by hand for that workspace.
- While that display is not connected (unplugged, asleep for a while) the pin is ignored: the workspace lives where it would without it, and goes back to its display as soon as it returns.
- `ScreenInfo.pinned(_:among:)` resolves a pin; the debug report lists the pins and the display each one resolves to.

## Empty workspaces

An empty workspace has no window to focus, yet its display must become the active one: otherwise the keyboard keeps typing into the window left on the other display, and the menu bar, new windows and Spotlight stay there. macOS lights up a display's menu bar only for the **active app**, and it ignores a background app activating itself (`NSApp.activate`, or `AXFrontmost` on itself): a click is the one thing it always honours.

So focusing an empty workspace (`workspace n`, `focus <dir>` or `focus-display` towards it, a window moved away leaving its workspace empty, a scratchpad hidden over one):

1. HyperSpace (`FocusAnchor`, `Tiling/FocusAnchor.swift`) **clicks the desktop** in the middle of the display's visible area, a moment later (the windows of the workspace just left are still there for a moment), with a synthetic left click (no modifiers, stamped with `EventTap.syntheticMarker`, so the event tap and your mouse mappings ignore it). As with a click of yours on an empty desktop, the **Finder** becomes the active app on that display and its menu bar is lit there. The pointer stays in the middle of the display;
2. no click is sent while a mouse button is held, nor when a window covers that point (a floating window, a scratchpad): its app would take the focus instead;
3. until a window is focused, that display **counts as the focused one** for HyperSpace too (menu bar highlight, apps opened from there, layout and workspace commands), even if macOS still reports the window left behind as focused;
4. that ends as soon as a window is focused, or another app than the Finder becomes active (⌘Tab, Spotlight, an app opening).

Earlier versions clicked an invisible window of HyperSpace's own instead; on macOS 27 that makes HyperSpace active but no longer moves the lit menu bar to that display.

## Moving windows and workspaces

| What | How |
|---|---|
| One window to a workspace | `move-to-workspace n` (or the workspace's `move` shortcut). If the target workspace is not shown the window disappears (parked) and focus goes to what is left; the display's workspace is not changed. |
| A window to another display | `move-to-workspace n` with a workspace that lives there; or drag it with the modifier onto that display / onto a window there |
| A whole workspace to another display | `move-workspace-to-display`: the focused workspace (windows and arrangement) goes to the **next display** (wraps around) and from then on lives there (`homeOverride`, by display UUID). Its floating windows are carried over keeping position and size as shares of the visible area. The workspace that display showed stays intact but hidden, and **stays on that display** (its home is set there if it was elsewhere): the two workspaces are never swapped. The display left behind returns to the last of *its own* workspaces it showed (or its first; none if no workspace lives there any more). |
| Focus to the next display | `focus-display` |

The move is not undone automatically; to bring a workspace back, run `move-workspace-to-display` again (with two displays it returns to the other one). The override is saved with the state.

## Display changes

- Displays are remembered by **UUID** (`CGDisplayCreateUUIDFromDisplayID`), which stays the same when a monitor is plugged in again (its id may not).
- A display disconnected: its workspaces move to the main display (their home becomes unavailable; a `homeOverride` pointing to a missing display is ignored), and the workspace it showed is remembered (`departed`). When it returns it **shows that workspace again**, with its windows and columns, and its layout/ratio.
- **Standby or another input**: `DisplayMonitor` polls every 5 s while tiling runs (one cheap call with a single display). A display that is asleep or inactive (`CGDisplayIsAsleep` / `!CGDisplayIsActive`) for **60 s** is left out of the layout as if unplugged; it comes back on the first poll it is awake. Not applied when every display is dark (the Mac sleeping). A monitor switched to another input that macOS still reports as active cannot be told apart and is not left out.
- macOS moves the windows of a removed display onto the remaining one, parked ones too: a parked window found in view is **parked again** (retiles run right away and at 0.5 s and 1.5 s after the change), and a floating one whose display is gone gets where macOS put it as its saved frame. Focus changes right after a display change do not switch workspaces.
- After any display change `syncDisplays` re-assigns which workspace each display shows, and a retile follows.
- The menu bar title is refreshed (see [Settings and menu](09-settings-and-menu.md)).

## How windows are hidden ("parked")

- Moving between displays of different sizes, floating windows keep their position and size as **percentages of the visible frame** (`ScreenInfo.relocate`), both when their workspace comes back on another display and on `move-to-workspace` to a workspace shown elsewhere. Tiled windows are simply re-laid out.
- A window whose workspace is not displayed is moved to the **bottom-right corner of its display** (position `maxX−1, maxY−1`: practically all of it off-screen). Its previous frame is remembered (`hiddenFrame`).
- Parked windows come back: when their workspace is shown (tiled ones are placed by the retile; floating ones return to their frame, or the same place relative to the new display), on **quit**, when tiling is **turned off**, and after a **crash** (at startup,
  windows with less than 10% visible on any display are centred on the main display).
- Writes use the per-app `AXQueues` queues; on quit, pending writes are flushed (up to 1.5 s) so windows really come back.
- ⌘Tab or a click on a window of a hidden workspace **shows that workspace** (focus follows), except for focus changes caused by HyperSpace itself (ignored for 0.6 s after it moves things) and for a window just moved away.

## App assignments

```json
"assign": [
  { "app": "com.autodesk.fusion360", "workspace": "cad" },
  { "app": "com.spotify.client", "workspace": "music" }
]
```

- `workspace` is a name or a number (1-based); renaming a workspace in Settings updates the rules. A rule for a workspace that no longer exists is dropped on save, and is a config error if it is in the file.
- A new window's workspace is chosen in this order (`newWindowWorkspace`): the app's **rule**, the workspace the window had **before a restart**, the workspace the app was **opened from**, else the one shown **where the window appears**.
  Choices outside the workspace count are skipped.
- **Launch without waiting for focus**: right after an app launches its windows are looked for again after 0.5, 1.5, 3 and 6 s, and a window created before AX describes it is retried, so a window of an app with a rule goes to its workspace (and is parked there if that workspace is hidden) as soon as it exists, not when you first focus the app.
- **Opened from**: `LaunchTracker` remembers the workspace you were on when an app launched (up to 60 s until its first window, then 3 s of grace for further windows). If you switch workspace while the app loads, its window appears in the original workspace (hidden), and the focus stays where you are.
- An app **with a rule** that you just opened takes you to its workspace (`reveal`), even if the app is slow to show its window. Not during the 90 s after a login launch (apps macOS reopens by itself), and not for restored windows or scratchpad windows.
- Without a rule, an app that finishes loading after you left its workspace stays in that workspace and does not steal focus.

## Saved state and restore

`WorkspaceState` is saved to `~/Library/Application Support/HyperSpace/workspaces.json` (JSON, sorted keys, ISO-8601 dates):

| Field | Meaning |
|---|---|
| `windows[]` | in tiling order: `app` (bundle id), `title`, `workspace`, `floating` (only if toggled by hand), `scratchpad` |
| `columns` | per workspace, its columns as indices into `windows` |
| `displays` | display UUID → workspace it shows (displays not connected included) |
| `moved` | workspace → UUID of the display it was moved to |
| `layouts` | display UUID → layout and master ratio |
| `accordions` | per workspace, the columns that are stacked as an accordion |
| `accordionWorkspaces` | workspaces stacked whole with the `accordion` shortcut |
| `savedAt` | when |

- **When**: 2 s after a change (and only if the state really changed, ignoring titles), and immediately on quit. The state is built on the main thread from the titles already cached on the windows, and written on the `HyperSpace.state` queue. Nothing is saved while a restore is still matching windows.
- **Restore**: at start the state is loaded if it is **less than 7 days old**. For a minute, each window found is matched to a saved one: same app and title, otherwise the first unclaimed saved window of that app (titles change, e.g. browser tabs).
  The window takes its saved workspace, floating flag, scratchpad flag, order and columns. App rules take precedence over the saved workspace. After 60 s the matching ends. Saved windows for apps not reopened yet are kept in the file on quit.
- `displays`, `moved` and `layouts` are matched by UUID; a saved display not connected yet keeps its workspace for when it is plugged in.
- Windows are recognised after a Mac reboot too, since apps reopen their windows.
