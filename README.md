# HyperSpace

Keyboard mapper, mouse mapper and tiling window manager for macOS in a single menu bar app.
Swift + AppKit, no dependencies, ~270 KB binary.

**The only permission required: Accessibility.** No Input Monitoring, no Screen Recording,
no notifications, no drivers/kexts, no root.

## Build

Only the Command Line Tools are needed (Xcode is not required).

```bash
make app        # build/HyperSpace.app (release, ad-hoc signed)
make run        # build + launch
make install    # copy to /Applications
make test       # tests (Swift Testing): config, shortcuts, combinations, layouts, workspace logic, saved state
```

To check the settings window without clicking through it, `build/HyperSpace.app/Contents/MacOS/HyperSpace --render-settings <folder>` saves every page as PNG (light and dark, 720×460 and 900×640) and quits; see [docs/10](docs/10-permissions-troubleshooting-build.md#screenshots-of-the-settings-window).

On first launch macOS asks for the Accessibility permission; HyperSpace starts by itself as soon as it is granted.

> **Signing and the permission.** macOS ties the Accessibility permission to the signature's *designated requirement*.
> A plain ad-hoc signature bases it on the binary hash, which changes on every rebuild: the permission is lost
> even though the switch stays on in System Settings. That is why `make app` signs ad-hoc while pinning the
> requirement to the bundle id (`identifier "com.alessandrorebosio.HyperSpace"`), so the permission survives rebuilds.
> It is convenient for development, but weaker: any app signed with that bundle id
> would inherit the permission. For a strong binding create a self-signed certificate (*Keychain Access →
> Certificate Assistant → Create a Certificate*, name `HyperSpace Dev`, *Self Signed Root*, *Code Signing*):
> if it exists, `make app` uses it automatically and the permission stays tied to the certificate.

## Configuration

`~/.hyperspace/config.json` — created on first launch, reloaded automatically on every save.
If the file has an error the menu bar icon turns into ⚠︎ and the menu shows the message; the last valid config stays active.

```json
{
  "keyboard": {
    "remap": [
      { "from": "caps_lock", "to": "hyper" },
      { "from": "right_option", "to": "escape" }
    ],
    "bindings": [
      { "keys": "hyper+h", "action": "focus left" },
      { "keys": "cmd+alt+t", "action": "launch Terminal" }
    ]
  },
  "mouse": {
    "reverseScroll": true,
    "dragModifier": "ctrl+alt",
    "buttons": [ { "button": 3, "action": "key cmd+[" } ]
  },
  "tiling": {
    "enabled": true, "layout": "columns", "gap": 8, "padding": 8, "masterRatio": 0.55,
    "floating": ["com.apple.finder"]
  }
}
```

### Menu bar and window

The icon is always in the menu bar; with tiling off it is drawn dimmed. Double-clicking the app while it runs
opens the settings. With more than one workspace configured the icon is replaced by the workspace shown on each
display (`1 2`, the focused display's one in a filled box).

The menu in the top bar starts with **Tiling** (on/off). With more than one workspace configured it lists the workspaces that have open apps, each with the icons of its apps next to it (✓ on the visible ones, window titles in the tooltip): a click shows the workspace. Wireless keyboards, mice and trackpads follow with their battery level (**Devices**). Below, **Lock Keyboard** (which becomes **Unlock Keyboard**), **Settings…** (⌘,), **Copy Debug Info** (copies to the clipboard the state of displays, workspaces and windows, with shortened titles, and the latest problems with apps: to paste when something goes wrong) and **Quit**. If there is a problem it shows at the top: a click opens the Accessibility permission or, for a config error, the file. While the window is open HyperSpace shows in the Dock and in ⌘Tab, with its own menu bar (⌘W closes it); once closed, it is back in the top bar only. The window follows the Liquid Glass style, is resizable (at least 720×460) and has a sidebar:
**Input** (**Keyboard**, **Mouse**, **Trackpad**), **Windows** (**Tiling**, **Workspaces**, **Window Rules**, **Shortcuts**) and
**HyperSpace** (**General**: version, launch at login, config file with Edit/Show in Finder, Accessibility permission, Quit).
At the bottom of the sidebar a status line always says whether HyperSpace is running, needs the Accessibility
permission or has a config error. Every page opens with its icon, name and a one-line summary;
lists have their **+ Add** button in the section header, keys and shortcuts are drawn as key caps (click one, then
press the keys), and tiling is switched on and off from the top of the Tiling page.
Without the Accessibility permission the pages that need it show a notice at the top with **Open System Settings…**
(it goes away by itself once granted); with tiling off the Windows pages show **Turn On**.
Every push to `develop` is built and tested on macOS by GitHub Actions, which also saves screenshots of every page
([docs/10](docs/10-permissions-troubleshooting-build.md#continuous-integration)).

### Keyboard
**Keyboard lock.** At the top of the Keyboard page (or from the menu bar, **Lock Keyboard**) you can lock the
keyboard to clean it: every key is ignored, media, volume and brightness included, until you unlock it
with the mouse (**Unlock** on the page or **Unlock Keyboard** in the menu, in the same place as Lock; a padlock shows in the menu bar).
To be safe it also unlocks by itself after the time chosen under it (1, 3, 5, 10 minutes or never;
3 by default), with the countdown on the page and in the menu. The lock is not saved: quitting HyperSpace turns the keyboard back on. Touch ID and the power button
cannot be locked.

| Key | Meaning |
|---|---|
| `remap` | 1:1 remapping of any key, per keyboard (see below). |
| `bindings` | Combination → action. Modifiers: `cmd`, `alt`/`opt`, `ctrl`, `shift`, `hyper`, `meh` (alt+ctrl+shift). |

#### Remapping (`remap`)

The easiest way is **Settings… → Keyboard** (menu bar, ⌘,): click the field, press the physical
key, then pick the target with **Press Keys…** by pressing what you want to get: a key,
a combination with a key (hold ⌘ and press Space → ⌘ Space) or modifiers only (hold ⇧⌃⌥ together and
release → ⌃⌥⇧). Otherwise there is the list of all keys. Finally choose which keyboards it applies to. Changes are written to `config.json` and applied at once.

```json
"remap": [
  { "from": "caps_lock",    "to": "escape" },
  { "from": "left_command", "to": "left_option",  "keyboard": "external" },
  { "from": "left_option",  "to": "left_command", "keyboard": "external" },
  { "from": "fn",           "to": "left_control", "keyboard": "builtin" },
  { "from": "caps_lock",    "to": "shift+ctrl+alt" },
  { "from": "right_command","to": "cmd+space" },
  { "from": "right_option", "to": "none",         "keyboard": "Magic Keyboard" }
]
```

- **Every keyboard**: built-in, USB, Bluetooth, even those connected after launch or after sleep. HyperSpace
  gets the new-keyboard event from IOKit and configures it at once; on wake from sleep it checks everything again.
- `keyboard` (optional): `all` (default), `builtin`, `external`, or part of the product name
  (e.g. `"USB Receiver"`, `"Keychron"`). If several rules remap the same key on a keyboard the most
  specific wins: product name > builtin/external > all.
- Swaps (cmd ↔ option) work: all the rules of a keyboard are applied together.
- `"to": "none"` disables the key.
- **A remapped Caps Lock no longer turns on caps.** On recent macOS the HID layer keeps toggling
  caps lock even when the key is remapped; when a rule starts from `caps_lock`, HyperSpace removes the
  caps flag from events and turns caps lock off at once (needs Accessibility). This applies to every keyboard.
- **Combinations**: `to` can be several keys joined by `+`, that is modifiers (`ctrl`, `alt`, `shift`, `cmd`, also
  `left_shift` etc.) plus at most one key. `hyper` = ⌃⌥⇧⌘, `meh` = ⌃⌥⇧.
  - Modifiers only (`shift+ctrl+alt`): they stay pressed while you hold the key, apply to keys and clicks,
    and work in `bindings` (`hyper+h`, `meh+k`…).
  - With a key (`cmd+space`): pressing the key is the same as pressing the combination.
  - The HID layer only does 1:1, so the key is remapped to an unused "carrier" key (F13–F20,
    skipping the ones you use) that the event tap translates into the combination (a symbol such as `-` is posted on the key that types it in the active layout). At most 8 different combinations; requires
    the Accessibility permission.
- `print_screen`, `scroll_lock` and `pause` have the key codes of F13, F14 and F15 (and `non_us_pound` that of `backslash`): in `bindings` they are indistinguishable, and using one in a remap also keeps its twin from being a carrier.
- `hyperKey: "caps_lock"` is still accepted as a shortcut for `{ "from": "caps_lock", "to": "hyper" }`.
- Remappings live in the system's HID layer (the `UserKeyMapping` property of each keyboard, the same one
  used by `hidutil`): they happen before any app sees the key, cost zero CPU and **need no
  permission at all**, so they are active even before Accessibility is granted. They are removed on quit.
- HyperSpace manages the whole `UserKeyMapping`: any mappings set by hand with `hidutil` are replaced.

#### Key names

| Group | Names |
|---|---|
| Letters, digits | `a`–`z`, `0`–`9` |
| Function | `f1`–`f24` (`f21`–`f24` only as remap target/source) |
| Modifiers | `left_command` `right_command` `left_option` `right_option` `left_control` `right_control` `left_shift` `right_shift` `caps_lock` `fn` (alias `globe`) |
| Editing | `return` `escape` `tab` `space` `delete` `forward_delete` `insert` `application` |
| Navigation | `left` `right` `up` `down` `home` `end` `page_up` `page_down` |
| Punctuation | `minus` `equal` `left_bracket` `right_bracket` `backslash` `semicolon` `quote` `grave` `comma` `period` `slash` `section` `non_us_pound` (also as symbols: `-` `=` `[` `]` `;` `'` `` ` `` `,` `.` `/` `\` `§`) |
| PC keyboards | `print_screen` `scroll_lock` `pause` |
| Keypad | `keypad_0`–`keypad_9` `keypad_period` `keypad_enter` `keypad_plus` `keypad_minus` `keypad_multiply` `keypad_divide` `keypad_equal` `keypad_comma` `keypad_clear` |
| International | `international1` `international3` `lang1` (kana) `lang2` (eisu) |
| Media (remap only) | `mute` `volume_up` `volume_down` `play_pause` `next_track` `previous_track` `eject` `brightness_up` `brightness_down` |
| Any other key | hexadecimal HID code: `0x39` (keyboard page) or `0xC000000E2` (`page << 32 \| usage`) |

Notes: `fn` can be remapped on Apple keyboards; on most PC keyboards the fn key is handled by the
firmware and never reaches the Mac. Media keys and `f21`–`f24` do not produce key events in macOS, so
they can be remapped but not used in `bindings`.

### Mouse

From **Settings… → Mouse**: a switch to reverse the scroll wheel and the button mapping.
From **Settings… → Trackpad**: with **Edge sliders** on, one finger slid up or down along the left or right edge of the trackpad changes the display
brightness or the volume (each edge can be set to either, or nothing); the pointer stays still meanwhile.
**Add Button**, click the mouse button over the window (holding modifiers if you want the
mapping to apply only with them), then press the combination it should send, pick a ready-made action
or **Disable Button**. Ready-made actions:

- **Navigation**: universal Back / Forward, independent of language and keyboard layout. HyperSpace presses the
  frontmost app's menu item whose shortcut is ⌘[ / ⌘] (Safari, Finder, Chrome, Mail…) or
  ⌃- / ⌃⇧- (VS Code and similar), finding it by shortcut rather than by name (the lookup is cached per app).
  If the app has no such item it sends a real back/forward mouse button (Chrome, Firefox, Electron, JetBrains);
  in Xcode it uses ⌃⌘← / ⌃⌘→.
- **Browser**: open link in new tab (⌘-click under the pointer), reload, new/close/reopen tab, next/previous tab.
- **Edit**: copy, paste, cut, undo, redo, zoom.
- **System**: Mission Control, app windows, show Desktop, Spotlight, screenshot, full screen, lock screen.
- **Media**: play/pause, next/previous track, volume, mute, brightness.

| Key | Meaning |
|---|---|
| `reverseScroll` | Reverses scrolling **of scroll wheels only** (trackpads and Magic Mouse stay "natural"). |
| `dragModifier` | Modifiers + left drag = move window; + right drag = resize. On a tiled window: dropping it on another swaps them; resizing moves the master/stack split in `tall` and `wide` (in the other layouts the window goes back to its tile). |
| `buttons` | Mouse button (2 = middle, 3 = back, 4 = forward, …) with optional `modifiers` → action (`none` disables it). |

`trackpad`: `edgeSliders` (off by default), `leftEdge` and `rightEdge` (`volume`, `brightness` or `none`).

### Tiling

From the **Tiling** page: on/off, layout (picked from previews that show gaps and margins), gaps;
from **Workspaces** the workspaces (name, shortcut to show it, shortcut to move the focused window there) and the
assigned apps; from **Window Rules** floating apps and windows and scratchpad apps; from **Shortcuts** the shortcuts for focus,
moving, resizing.

```json
"tiling": {
  "workspaces": [
    { "name": "1", "switch": "meh+1", "move": "hyper+1" },
    { "name": "2", "switch": "meh+2", "move": "hyper+2" }
  ]
}
```

**Per-app rules.** An app's windows open straight in its workspace; if the app is frontmost
(you just opened it) HyperSpace takes you to that workspace, even if the app takes a while to open (not in the minute and a half after logging in to the Mac, when apps reopen by themselves). From Workspaces → App Rules, or:

```json
"assign": [
  { "app": "com.autodesk.fusion360", "workspace": "cad" },
  { "app": "com.spotify.client", "workspace": "music" }
]
```

`workspace` is the name (or the number) of the workspace; renaming it from the Workspaces page, the rules follow it.

**Virtual workspaces with a fixed display.** macOS has no public API to manage Spaces, so workspaces
belong to HyperSpace. Each workspace has its display: **1 on the main display** (the one with the menu
bar), **2 on the second**, 3 on the third and so on; all the others live on the main one. Each display shows
one of its workspaces: a `switch` shortcut (e.g. `meh+N`) shows workspace N on its display and moves the focus there, without touching the other displays.
A workspace can also be **pinned to a monitor** (Settings → Workspaces → *Display*, or `"display"` in the config: `"main"`, a number, or the monitor's name): it always shows there while that monitor is connected, and goes back to its usual display while it is unplugged. The default config defines no workspaces or display shortcuts: create them in Settings → Workspaces / Shortcuts.
An app you open stays in the workspace you opened it from: if you switch workspace while it is still loading, its window appears there (hidden) and the focus stays where you are.
A tiled window you move or resize by hand goes back to its place when you release the mouse (to really move it use the shortcuts or the modifier drag).
When the focus moves to another display the pointer follows it (to the centre of the window, or of the display if the workspace is empty), and switching workspace puts it in the middle of the screen (`"mouseFollowsFocus": false` turns both off). An empty workspace takes the focus too: HyperSpace clicks a tiny invisible window of its own in the middle of that display, so it becomes the active app there, the menu bar lights up on that display and the keyboard no longer types into the window left on the other one, and the pointer stays there. A window moved to another display is resized again shortly after, for apps that adapt by themselves to the new display's scale. Moving a window to another workspace moves only that window. The `move-workspace-to-display` shortcut (Settings → Shortcuts → Displays) instead moves the whole workspace to the other display, which is its display from then on: the workspace that display was showing stays intact (hidden) on that display, without swapping places, and the display left behind goes back to the last of its own workspaces (or stays empty if it has none left). Windows of workspaces not shown are
parked in the bottom-right corner of their screen (as AeroSpace does). If a display is unplugged, its
workspaces move to the main one and go back to their place when you plug it in again.

In `columns`, moving a window (`swap`): **down/up** swaps it with the one below/above in the column,
or, if it is alone, stacks it in the next column; **left/right** takes it out of the column into a
new column on that side, or, if it is alone, swaps the column with its neighbour. `resize width` changes the
column width, `resize height` the height of the window in the column.
Only standard windows are managed; dialogs, panels and full-screen windows are ignored. Windows that look like
dialogs (they can be closed but neither zoomed nor made full screen, like Empty Trash or the Finder's copy)
stay floating in any app; `float` tiles them anyway.
**Scratchpad** (as in i3). One shortcut per app, e.g. `{ "keys": "meh+x", "action": "scratchpad com.anthropic.claudefordesktop" }`:
the first time it opens the app (if not open) and shows it in the middle of the active display, above the other windows and
out of the tiling; pressed again it hides it, then shows it again. It closes when you switch workspace, and if you
reach it with ⌘Tab it shows by itself. `move-to-scratchpad` (e.g. `hyper+x`) sends the focused
window to the scratchpad or puts it back into the tiling of the current workspace. The size is a fraction of the display:
`"scratchpad": { "width": 0.6, "height": 0.7 }` (default). Apps can also be managed from Settings → Window Rules →
Scratchpad Apps. The scratchpad is remembered across restarts.

`floating` lists the bundle IDs not to tile. `floatingWindows` floats only some windows, by
title (contains the text, case-insensitive), of one app or of all; it can also be managed from Settings → Window Rules →
Floating (an app with no title = all its windows). It also applies to windows that get their title a moment after opening:

```json
"floatingWindows": [
  { "app": "com.autodesk.fusion360", "title": "Preferences" },
  { "title": "Picture-in-Picture" }
]
```

### Actions
| Action | |
|---|---|
| `focus left\|right\|up\|down` | Moves the focus to the nearest window in that direction |
| `swap left\|right\|up\|down` | Swaps the window with its neighbour (across displays too) |
| `swap master` | Moves the window to the master position |
| `layout tall\|wide\|columns\|monocle\|accordion` | Changes the layout of the active display |
| `accordion` | Stacks the focused workspace's windows as an accordion, or unstacks them |
| `ratio +0.05` / `ratio -0.05` | Resizes the master area |
| `float` | Current window floating ↔ tiled |
| `scratchpad <App Name or bundle id>` | Shows/hides the app in the middle above the others, out of the tiling (opens it if needed) |
| `scratchpad` | Shows/hides the windows sent to the scratchpad |
| `move-to-scratchpad` | Sends the focused window to the scratchpad, or from there back into the tiling |
| `move-to-scratchpad <App Name or bundle id>` | The same for that app's window (opens the app if it is not running); what Settings writes for *To tiling and back* |
| `tiling` | Turns tiling on/off |
| `retile` | Recomputes the layout now |
| `focus-display` | Focuses a window on the next display |
| `move-workspace-to-display` | Moves the active workspace (windows and arrangement) to the next display |
| `workspace <n>` / `workspace back-and-forth` | Shows workspace n / goes back to the previous one |
| `move-to-workspace <n>` | Moves the focused window to workspace n |
| `resize width\|height <points>` | Widens/narrows the window (e.g. `resize width +50`): when tiled it moves the master/column split or changes the window's share of the column |
| `launch <App Name or bundle id>` | Opens/activates an app |
| `shell <command>` | Runs a command with `/bin/sh -c` |
| `key <combo>` | Sends a key combination (e.g. `key cmd+shift+4`). Symbols (`-`, `=`, `,`…) use the key that types them in the active layout; symbols the layout types only with ⌥ (e.g. `[` on the Italian keyboard) are not reliable as shortcuts |
| `reload` | Reloads the config |
| `none` | Does nothing: disables the key or button it is bound to |
| `navigate back\|forward` | Back/forward with the frontmost app's shortcut |
| `system mission_control\|app_windows\|show_desktop` | Mission Control, app windows, show Desktop (via the Dock) |
| `media play_pause\|next\|previous\|volume_up\|volume_down\|mute\|brightness_up\|brightness_down` | Media keys |
| `click <modifiers>` | Left click under the pointer with modifiers (e.g. `click cmd`) |

## Architecture

```
Sources/HyperSpace/
├── App/        AppDelegate (wiring, permission), StatusMenu (menu bar), MainMenu (menu while Settings is open)
├── Settings/   window with a Keyboard/Mouse/Trackpad, Tiling/Workspaces/Window Rules/Shortcuts, General sidebar (SwiftUI, created only when opened); SettingsSnapshot (--render-settings)
├── Core/       EventTap, Config/ConfigStore/ConfigWriter/DefaultConfig, Action/ActionRunner, SystemActions,
│               KeyCodes, Modifiers (and KeyCombo), RemapTarget, AppLauncher, Peripherals, Permissions
├── Keyboard/   KeyboardRemapper (UserKeyMapping per keyboard), KeyEmitter (synthetic events),
│               KeyboardLayout, CapsLock, KeyboardLock
├── Mouse/      DragController (tap → window manager bridge), EdgeSliders (trackpad edge sliders)
└── Tiling/     WindowManager (+ Scratchpad, SavedState, Workspaces, Commands, Debug extensions), ManagedWindow,
                ColumnLayout, AppWatcher (AXObserver), AXWriter (per-app writes), WorkspaceState (saved workspaces),
                LaunchTracker, Layout, ScreenInfo, DisplayMonitor, FocusAnchor, AX helpers
```

Choices made for performance and minimal permissions:

- **A single active event tap** (`CGEventTap` at HID level) shared by keyboard and mouse, on a **dedicated**
  high-priority **thread**: window work (main thread) can never slow input down.
  An active tap needs only Accessibility (a passive tap would need Input Monitoring).
- **It subscribes only to the events in use.** Mouse movements are intercepted only with the trackpad edge sliders on (to hold the pointer during a slide); scrolling only if
  `reverseScroll` is on; with an empty config the tap is not installed at all.
- **Lean hot path**: no locks of its own, and no allocation except the event a combination posts; bindings are compiled into `[Int16]` tables indexed by
  `keyCode << 4 | modifiers`; the config reaches the tap thread with `CFRunLoopPerformBlock`.
- **Remaps and hyper key in the HID layer**, per keyboard via `IOHIDServiceClient` (no `hidutil` processes): zero CPU, no permission; new keyboards detected with IOKit notifications.
- **Event-driven tiling**: `AXObserver` per app + `NSWorkspace` notifications, no polling. Bursts of
  events are coalesced into a single retile; window visibility and position come from
  `CGWindowListCopyWindowInfo` (without titles → no Screen Recording), read once per command together with the displays
  and the focused window, and windows are moved only if their position actually differs.
- **1000 Hz drag without backlog**: the tap keeps only the latest position and at most one update is
  queued on the main thread.
- **AX writes off the main thread**: moving, resizing, parking and focusing a window, modifier-drag included,
  happens on a serial queue per app (`AXWriter`). A slow or hung app only makes itself wait, never the
  shortcuts or the other apps. Reads and state stay on the main thread.
- **0.5 s AX timeout** for every element (macOS's default is 6 s).
- **Saved workspaces** in `~/Library/Application Support/HyperSpace/workspaces.json` (a moment after every
  change and on quit): after a restart of HyperSpace or of the Mac every window goes back to its workspace,
  with order and columns, recognised by app and title. Per-app rules take precedence.
- Config watched with a kqueue `DispatchSource`: no cost until the file changes.

### Known limitations
- Uses the private (but stable for years) function `_AXUIElementGetWindow`, like yabai/Amethyst/Rectangle:
  the app cannot be sandboxed nor go on the Mac App Store (true of any AX-based window manager).
- Spaces are not created/managed: the windows of the visible Space on each display are tiled.
