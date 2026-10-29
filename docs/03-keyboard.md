# 3. Keyboard

The keyboard side has three independent parts:

1. **Shortcuts** (`keyboard.bindings`): combination → [action](05-actions.md), handled by the event tap (needs Accessibility).
2. **Remaps** (`keyboard.remap`): a key becomes another key or a combination, per keyboard. The 1:1 case lives in the system HID layer and needs no permission.
3. **Keyboard lock**: ignores every key, for cleaning the keyboard.

## Shortcuts (`bindings`)

```json
"bindings": [
  { "keys": "hyper+h",          "action": "focus left" },
  { "keys": "cmd+alt+t",        "action": "launch Terminal" },
  { "keys": "cmd+shift+return", "action": "shell open -a Safari" }
]
```

- `keys` is `modifier+…+key`; **the last token is the key**, the others must be modifiers. Spaces around tokens are ignored.
- **Modifiers** (case-insensitive): `cmd`/`command`/`⌘`, `alt`/`opt`/`option`/`⌥`, `ctrl`/`control`/`⌃`, `shift`/`⇧`, `hyper` (= ⌃⌥⇧⌘), `meh` (= ⌃⌥⇧).
- Matching is **exact on modifiers**: `hyper+h` does not fire while another modifier is also held. Only cmd/alt/ctrl/shift are considered (not fn or caps lock).
- The key must have a keycode: media keys and `f21`–`f24` can be remapped but not used in a binding (error `'…' can be remapped but not used in a shortcut`).
- When a binding fires, the key-down is **swallowed**, and so is the matching key-up: the frontmost app sees nothing.
- Keycodes are physical ANSI positions; see [Keyboard layouts and symbols](#keyboard-layouts-and-symbols).
- Several bindings with the same combination: the last wins (see [Configuration](02-configuration.md#errors)).

## Key names

Used in both bindings and remaps (case-insensitive). The first name is canonical.

| Group | Names |
|---|---|
| Letters, digits | `a`–`z`, `0`–`9` |
| Function | `f1`–`f24` (`f21`–`f24` have no keycode: remap only) |
| Modifiers | `left_command` (`left_cmd`), `right_command` (`right_cmd`), `left_option` (`left_alt`), `right_option` (`right_alt`), `left_control`, `right_control`, `left_shift`, `right_shift`, `caps_lock`, `fn` (alias `globe`) |
| Editing | `return` (`enter`), `escape` (`esc`), `tab`, `space`, `delete` (`backspace`), `forward_delete`, `insert` (`help`), `application` (`menu`) |
| Navigation | `left` `right` `up` `down` `home` `end` `page_up` `page_down` |
| Punctuation | `minus` `-`, `equal` `=`, `left_bracket` `[`, `right_bracket` `]`, `backslash` `\`, `non_us_pound`, `semicolon` `;`, `quote` `'`, `grave` `` ` ``, `comma` `,`, `period` `.`, `slash` `/`, `section` (`§`, `non_us_backslash`) |
| PC keys | `print_screen` `scroll_lock` `pause` |
| Keypad | `keypad_0`–`keypad_9`, `keypad_period`, `keypad_enter`, `keypad_plus`, `keypad_minus`, `keypad_multiply`, `keypad_divide`, `keypad_equal`, `keypad_comma`, `keypad_clear` (`num_lock`) |
| International | `international1` (`jis_underscore`), `international3` (`jis_yen`), `lang1` (`kana`), `lang2` (`eisu`) |
| Media (remap only) | `mute` `volume_up` `volume_down` `play_pause` `next_track` `previous_track` `eject` `brightness_up` `brightness_down` |
| Special | `none` (alias `disabled`): disables the key (HID usage 0) |
| Anything else | hexadecimal HID code: `0x39` (Keyboard page) or `0xC000000E2` (`page << 32 \| usage`); remap source/target only |

`fn` can be remapped on Apple keyboards; on most PC keyboards fn is handled by the firmware and never reaches the Mac.

## Remaps (`remap`)

```json
"remap": [
  { "from": "caps_lock",     "to": "escape" },
  { "from": "left_command",  "to": "left_option",  "keyboard": "external" },
  { "from": "left_option",   "to": "left_command", "keyboard": "external" },
  { "from": "fn",            "to": "left_control", "keyboard": "builtin" },
  { "from": "caps_lock",     "to": "shift+ctrl+alt" },
  { "from": "right_command", "to": "cmd+space" },
  { "from": "right_option",  "to": "none",         "keyboard": "Magic Keyboard" }
]
```

### Which keyboards (`keyboard`)

- `all` (default): every keyboard. `builtin` (`built-in`, `internal`): the built-in one only. `external`: all the others.
- Any other string: a **substring of the product name** (case-insensitive), e.g. `"Keychron"`, `"USB Receiver"`.
- If several rules remap the same key on the same keyboard the **most specific** wins: product name (2) > builtin/external (1) > all (0). At equal specificity the last in the file wins.
- Keyboards connected after launch are configured right away: `KeyboardRemapper` registers an IOKit notification (`IOHIDEventService`) and re-syncs after 0.3 s and 1.5 s
  (the HID service client appears shortly after the registry entry); on wake from sleep (`didWakeNotification`) it checks again.
- Writes happen only where needed (the current mapping is compared with the desired one). Nothing is polled.

### How it works (HID layer)

- Remaps are written as the `UserKeyMapping` property (`HIDKeyboardModifierMappingSrc`/`Dst` pairs) of each keyboard HID service through `IOHIDServiceClientSetProperty`
  (no `hidutil` processes). They happen **before** any app sees the key, cost zero CPU and **need no permission**: they work even without Accessibility.
- They are 1:1. A combination therefore goes through *carriers* (below).
- HyperSpace owns the whole `UserKeyMapping`: mappings set by hand with `hidutil` are replaced.
- On quit (`reset`) the mappings are removed; while a key is being captured in Settings they are suspended, so physical keys can be read.
- Swaps (cmd ↔ option) work: a keyboard's rules are applied together.
- `"to": "none"` disables the key.

### Targets: single key or combination

`to` is interpreted as follows (`RemapTarget.parse`):

1. **A single token that is a known key** (modifier, `none` and HID code included) → 1:1 remap.
2. **Several tokens joined by `+`**: modifiers (`ctrl`, `alt`, `shift`, `cmd`, `hyper`, `meh`, also `left_shift`, `right_command`…) plus **at most one** non-modifier key (which needs a keycode). Two normal keys → error. A key without keycode (e.g. media) → error.
3. A lone generic modifier (`shift`, `cmd`, `alt`, `ctrl`) is the corresponding **left** key (`left_shift`…), done in HID.

### Combinations and carriers

A combination cannot be expressed in HID, so:

1. the source key is remapped (in HID) onto an unused "carrier" key chosen from **F20, F19, F18, F17, F16, F15, F14, F13** (in that order), skipping those the config already uses
   (as a remap source or target, or in a binding);
2. the event tap recognises the carrier and turns it into the combination.

Behaviour:

- **Modifiers only** (e.g. `caps_lock → shift+ctrl+alt`, `hyper`, `meh`): the modifiers stay down while the key is held (autorepeat is ignored). They are added to the flags of all events
  (keys and also mouse clicks), so they work in bindings (`hyper+h`) and for ⌃⌥⇧-click. Several carriers held together merge their modifiers.
- **With a key** (e.g. `right_command → cmd+space`): pressing the key is the same as pressing the combination: a synthetic key event is emitted with the modifiers added to those already held (for key down and key up).
- The **same combination shares a single carrier**. At most **8 different combinations**; the ninth gives `too many different combinations (at most 8)`.
- Needs Accessibility (the tap is required).
- A key already used elsewhere is avoided as carrier, so binding F13–F20 yourself reduces the carriers available.

### Remapped caps lock

On recent macOS the HID layer still toggles caps lock even when the key is remapped. If a rule starts from `caps_lock` (`suppressCapsLock`), HyperSpace removes the caps flag from events
and switches the lock off through IOKit (`CapsLock.turnOff`, when the config is applied and on every `flagsChanged` carrying the flag). It applies to all keyboards and needs Accessibility.

### Remapping from Settings

*Settings… → Keyboard*: click the source field and press the physical key; then the target ("Becomes") by pressing what you want to obtain: a key, a combination with a key (hold ⌘ and press Space → `cmd+space`),
or modifiers only (hold ⇧⌃⌥ together and release → `shift+ctrl+alt`); a single modifier released alone is that physical key (e.g. Right Option). Alternative: the menu with all keys. Then the keyboard
(All keyboards / Built-in / All external / a connected keyboard). A warning appears if two rules share a key on the same keyboards. See [page 9](09-settings-and-menu.md).

## Keyboard layouts and symbols

Keycodes are physical positions, but apps match shortcuts by character. For the `key <combo>` action and for combinations with a key, `KeyboardLayout` maps ANSI symbol keys (`- = [ ] \ ; ' \` , . /`)
to the key that types that symbol in the active layout (table rebuilt when the input source changes, using `UCKeyTranslate`; keypad keys are excluded). For `=`, `+` is accepted as an alternative.
If the layout cannot type the symbol without modifiers (e.g. `[` on the Italian keyboard, which needs ⌥) the lookup fails and the original keycode is used: **not reliable as a shortcut**.
This applies to keys *sent*; incoming *bindings* always use the physical keycode.

## Keyboard lock

To clean the keyboard without typing. From *Settings → Keyboard → Keyboard Lock* or the menu bar (**Lock Keyboard**).

- Every `keyDown`, `keyUp` and `flagsChanged` event is dropped, and so are system keys (media, volume, brightness: `NX_SYSDEFINED` subtype 8); other subtypes (coming from the mouse) pass. Touch ID and the power button cannot be locked.
- Unlock **with the mouse**: *Unlock* on the page or **Unlock Keyboard** in the menu (same spot as Lock).
- **Automatic unlock** after 1, 3, 5, 10 minutes or never (picker next to the button, default 3), with a countdown on the page and in the menu. The picker is disabled while locked.
- While locked the menu bar icon shows a lock (and the icon is shown even if tiling is off).
- The lock is **not saved**: quitting HyperSpace re-enables the keyboard. It needs the tap, hence Accessibility.
- On lock/unlock, the modifiers held by carriers and the swallowed-key state are cleared.
