# Using HyperSpace

How to use each feature, with the options it takes. Your config only needs the lines that
differ from the defaults: everything below is optional.

- [Getting started](#getting-started)
- [Keyboard](#keyboard-keyboardtoml)
- [Mouse](#mouse-mousetoml)
- [Actions](#actions)
- [Window manager](#window-manager-wmtoml)
- [Files HyperSpace keeps](#files-hyperspace-keeps)

## Getting started

The config is three files in `~/.config/hyperspace/` (`hsctl config-path` prints the folder):

| File | What | Off when |
|---|---|---|
| `keyboard.toml` | key remaps, Caps Lock and other layers, double taps | missing |
| `mouse.toml` | mouse buttons, wheel, pointer speed | missing |
| `wm.toml` | tiling window manager (AeroSpace format) | missing or only comments |

- **Saved = applied.** No restart. A file with a mistake keeps its last good settings; the
  error shows in the menu ("Error in …") and in `hsctl status`.
- **Open Config** in the menu creates any missing file with every option commented out.
- **Try an action before mapping it:** `hsctl do volume.up`, `hsctl do mission.control`.
- **Bundle ids** for per-app rules: `hsctl apps` (running apps), or
  `osascript -e 'id of app "Safari"'`.
- **Enabled** in the menu (or `hsctl toggle`) undoes every remap and stops the window
  manager without quitting.

## Keyboard (`keyboard.toml`)

Keys are named by their US position: `a`…`z`, `0`…`9`, `f1`…`f20`, `escape`, `tab`,
`space`, `return`, `backspace`, `delete.forward`, `arrow.left/.right/.up/.down`, `home`,
`end`, `page.up`, `page.down`, `capslock`, `shift.left/.right`, `control.left/.right`,
`option.left/.right`, `command.left/.right`. Modifiers: `shift`, `ctrl`, `opt`, `cmd`,
`fn`, joined with `-` (`cmd-shift-k`). Quote names with dots in table headers:
`[layer."page.up"]`.

### Remap a key

```toml
[map]
"command.right" = "option.right"            # key -> key: works everywhere, even in password fields
f1 = "cmd-space"                            # key -> combo
f12 = { action = "volume.up", repeat = true }
```

Only for one app, or one keyboard:

```toml
[[app]]
bundle_id = "com.apple.Terminal"
map = { f1 = "passthrough" }                # F1 keeps its normal behavior in Terminal

[[device]]
name = "magic keyboard"                     # part of the name, or vendor/product (hidutil list)
map = { "option.left" = "command.left" }
```

### Caps Lock as a modifier

```toml
[capslock]
hold = "shift-ctrl-opt"     # held: other keys get these modifiers ("shift-ctrl-opt-cmd" for all four)
alone = "escape"            # tapped alone (default: nothing)
led = "held"                # "held" = LED on while held; "off" (default) = always off
tap_timeout_ms = 200        # held longer = not a tap

[capslock.map]              # Caps + key does this instead, in every app
return = { app = "Visual Studio Code" }
h = "arrow.left"

[[capslock.app]]            # Caps + key in one app only
bundle_id = "com.microsoft.VSCode"
map = { d = "cmd-shift-k" }
```

Once `[capslock]` exists, Caps Lock no longer toggles caps lock.

### Other layers and dual-role keys

Any key works like `[capslock]`: tapped it types `alone`, held the other keys use its
`map` and `hold` modifiers. Fast typing isn't affected: a key pressed during the layer key
counts as held only if it's released first.

```toml
[layer.space]
alone = "space"
map = { j = "arrow.down", k = "arrow.up", h = "arrow.left", l = "arrow.right" }

[layer.return]              # Return when tapped, Control when held
alone = "return"
hold = "ctrl"
```

### Double taps

The first tap works as usual, the second does the action. Modifier keys work too.

```toml
double_tap_ms = 300         # 100-1000, before any [section]

[double]
"shift.left" = "cmd-space"
escape = "mission.control"
```

### External displays

`display_keys = true` (before any section): the brightness keys change the external display
under the pointer, and the volume keys its speakers when the sound plays there, over DDC
(Apple silicon).

## Mouse (`mouse.toml`)

Buttons: `button1` = right, `button2` or `middle` = wheel click, `button3` or `back` and
`button4` or `forward` = side buttons, `button5`…`button31` = extra. Logitech mice also have
`dpi`, `gesture` and any control as `"cid.0x00c3"`, read over Logitech's protocol. The left
button can't be remapped.

```toml
[buttons]
back = "navigate.back"      # back/forward in every app, any layout
forward = "navigate.forward"
middle = "media.play"

[[app]]                     # different in one app
bundle_id = "com.google.Chrome"
buttons = { back = "passthrough", forward = "passthrough" }
```

### Gestures while a button is held

Tapped alone the button still does its own action.

```toml
[hold.back]
"scroll.up" = "volume.up"   # per wheel notch
"scroll.down" = "volume.down"
"move.left" = "space.left"  # move the mouse while holding
"move.right" = "space.right"
distance = 60               # points per gesture
```

### Wheel and pointer

Wheels only; trackpads and Magic Mouse are never touched.

```toml
[scroll]
smooth = true               # the notched wheel glides like a trackpad
reverse = true              # true, "vertical" or "horizontal"
linear = true               # same distance per notch
lines = 3                   # per notch, when linear or smooth (1-20)
fast = "opt"                # hold to scroll faster...
fast_factor = 3             # ...by this much

[pointer]                   # every mouse; trackpads keep the macOS settings
speed = 0.5                 # 0 (slow) ... 1 (fast)
acceleration = false        # false = linear, or 0-20

[[device]]                  # one mouse only; wins over [pointer]
name = "lift"
speed = 0.6
```

`navigate.back/.forward` reach Apple apps, Firefox, Opera and ForkLift as a trackpad swipe and
every other app as buttons 4/5. To change that per app (bundle id prefixes):

```toml
[navigate]
swipe = ["com.example.App"]
buttons = ["com.apple.Xcode"]
```

## Actions

What a key or a button can do, in both files:

| Action | Does |
|---|---|
| `"cmd-w"`, `"arrow.left"` | a key or combo |
| `"navigate.back"`, `"navigate.forward"` | back/forward in every app |
| `"volume.up"`, `".down"`, `".mute"` | volume |
| `"brightness.up"`, `".down"` | display brightness |
| `"keyboard.brightness.up"`, `".down"` | keyboard backlight |
| `"media.play"`, `".next"`, `".previous"`, `".forward"`, `".rewind"` | playback |
| `"mission.control"`, `".windows"`, `".desktop"`, `".launchpad"` | Mission Control |
| `"space.left"`, `"space.right"` | one desktop Space |
| `"window.maximize"`, `"window.minimize"` | the focused window |
| `"lookup"`, `"zoom.smart"` | Look Up, smart zoom |
| `"click.left"`, `".double"`, `".right"`, `".middle"`, `".back"`, `".forward"` | clicks |
| `"scroll.up"`, `".down"`, `".left"`, `".right"` | 3 lines; `{ scroll = "down", lines = 5 }` or `pixels = 40` |
| `{ app = "Safari" }` | open or focus an app (name or bundle id) |
| `{ text = "me@example.com" }` | type text |
| `{ sequence = ["cmd-c", "cmd-tab", "cmd-v"] }` | several in a row |
| `{ shell = "open ~/Downloads" }` | a shell command |
| `{ action = "volume.up", repeat = true }` | repeat while held |
| `{ action = "click.left", hold = true }` | hold down while held (drag) |
| `"none"` / `"passthrough"` | nothing / the normal behavior (app exceptions) |

## Window manager (`wm.toml`)

AeroSpace's format and commands: an `~/.aerospace.toml` works as is, minus the app-level keys
(start at login and reload are in the menu, always on). Every command also runs from the
terminal: `hsctl workspace 2`, `hsctl list-windows --all`. `hsctl --help` lists them;
`eval "$(hsctl completion zsh)"` in `~/.zshrc` completes them.

### Keys and modes

```toml
[mode.main.binding]
alt-h = 'focus left'
alt-shift-h = 'move left'
alt-1 = 'workspace 1'
alt-shift-1 = 'move-node-to-workspace 1'
alt-shift-semicolon = 'mode service'

[mode.service.binding]      # one key, then back to main
esc = ['reload-config', 'mode main']
f = ['layout floating tiling', 'mode main']
```

Modifiers: `cmd`, `alt`, `ctrl`, `shift`. Keys: `a`-`z`, `0`-`9`, `keypad0`-`9`, `f1`-`f20`,
`minus`, `equal`, `period`, `comma`, `slash`, `backslash`, `quote`, `semicolon`, `backtick`,
`leftSquareBracket`, `rightSquareBracket`, `space`, `enter`, `esc`, `backspace`, `tab`,
`pageUp`, `pageDown`, `home`, `end`, `forwardDelete`, `left`, `down`, `up`, `right`.

With Caps Lock held as `shift-ctrl-opt` (see [Keyboard](#caps-lock-as-a-modifier)), bind
`ctrl-alt-shift-<key>`: Caps + key, with one hand.

**Forgot a key?**

```toml
show-mode-bindings = true                                                  # a mode's keys while it's on
show-bindings-on-hold = { modifiers = 'ctrl-alt-shift', delay-ms = 1000 }  # hold them alone: the main keys that use them
```

Holding exactly those modifiers (Caps Lock counts) with no other key shows their bindings at
the bottom of the display. Press a key and it runs as usual; the panel goes away.

### Look

```toml
gaps.inner.horizontal = 8   # between windows; also gaps.inner.vertical
gaps.outer.top = 8          # from the display's edges; also .left, .bottom, .right
gaps.outer.left = [{ monitor.main = 16 }, { monitor."dell" = 32 }, 24]   # per display, last = the rest
accordion-padding = 30
default-root-container-layout = 'tiles'        # tiles | accordion
default-root-container-orientation = 'auto'    # horizontal | vertical | auto
```

### Workspaces and displays

```toml
persistent-workspaces = ['1', '2', '3']   # kept when empty; omitted = the ones named in bindings or assigned

[workspace-to-monitor-force-assignment]
1 = 'main'                  # main, secondary, a number from the left, or a regex on the name
2 = 'secondary'
```

- `move-workspace-to-monitor next` swaps with the other display's workspace; add `--no-swap`
  to move it and leave the other one hidden.
- `on-focused-monitor-changed = ['move-mouse monitor-lazy-center']`: the mouse follows the
  focus to the other display.
- `focus-follows-mouse.enabled = true`: the window under the pointer gets the focus.

### Apps on their workspace

```toml
[[on-window-detected]]
if.app-id = 'com.apple.Terminal'
run = 'move-node-to-workspace Shell'
```

Also `if.app-name-regex-substring`, `if.window-title-regex-substring`, `if.workspace`,
`if.during-aerospace-startup`, `check-further-callbacks = true`, or `if = 'test …'`.

An app you open again opens on the workspace you're on (rules still win). To send it back to
the workspace it was last on instead: `reopen-apps-in-last-workspace = true`, or the menu.

### Scratchpad

`scratchpad <bundle-id>` brings an app's window floating over the current workspace (80% of the
display, centered); the same key puts it back. It launches the app if needed;
`scratchpad --new <bundle-id>` opens a new window for it. Tiling or moving it makes it an
ordinary window again. Put away with no rule for its app, it goes where the app was last, else
to `scratchpad-fallback-workspace = 'Scratch'`.

```toml
ctrl-alt-shift-t = 'scratchpad com.apple.Terminal'
```

### Minimized, hidden and full screen windows

A minimized window, the windows of an app hidden with ⌘H and a window in macOS full screen
(the green button, or `macos-native-fullscreen`) leave the layout: the others take their room.
They come back to their spot (same workspace, next to the same window, same size, even after
HyperSpace restarts), and focus follows them when you bring them back from the Dock.
`list-windows` still lists them, with the workspace they come back to. `fullscreen` (a tile
over the whole workspace) is HyperSpace's own and survives a minimize.

### External displays

| | |
|---|---|
| `detect-monitor-input = true` | a display switched to another computer is left out, as if unplugged, until it shows the Mac again (DDC, every 2 s) |
| `ignore-monitor on <pattern>` | leave a display out by hand (also the menu, Displays) |
| `monitor-brightness +10 --monitor dell` | brightness, `+`/`-` or absolute percent |
| `monitor-volume mute-toggle` | speakers: `mute-toggle` or a percent |
| `monitor-input hdmi1 --monitor dell` | input: `dp1`, `dp2`, `hdmi1`, `hdmi2`, `usb-c` or a code |

### Scripts and status bars

```sh
hsctl list-windows --all --format '%{window-id} | %{app-name} | %{workspace}'
hsctl list-workspaces --all
hsctl subscribe --all       # one JSON line per event, for SketchyBar and the like
```

`--format` variables: `workspace`, `workspace-is-focused`, `workspace-is-visible`,
`monitor-id`, `monitor-name`, `window-id`, `window-title`, `window-layout`,
`window-is-fullscreen`, `window-is-macos-fullscreen`, `window-is-scratchpad`,
`window-scratchpad-home`, `app-name`, `app-bundle-id`, `app-pid`; for `list-monitors`:
`monitor-is-ignored`, `monitor-input`. Events: `focus-changed`, `focused-monitor-changed`,
`focused-workspace-changed`, `mode-changed`, `window-detected`.

### Menu

The menu bar shows each display's workspace. The menu lists the workspaces and their windows
(click to go there), the displays to leave out, and the options Reopen Apps in Last Workspace
and Show Mode Bindings, which write to `wm.toml`.

## Files HyperSpace keeps

In `~/Library/Application Support/HyperSpace/`, none of them to edit by hand:

| File | What |
|---|---|
| `layout.json` | the layout, put back when HyperSpace starts |
| `set-aside.json` | where minimized, hidden and full screen windows go back |
| `app-workspaces.json` | the workspace each app was last on (scratchpads, `reopen-apps-in-last-workspace`) |
| `monitor-inputs.json` | the Mac's input on each display (`detect-monitor-input`) |
