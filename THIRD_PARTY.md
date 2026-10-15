# Third-party code and ideas

## LinearMouse — MIT License, Copyright (c) 2021-2026 LinearMouse
https://github.com/linearmouse/linearmouse

`Sources/HyperSpaceInput/Navigation.swift` follows LinearMouse's "universal back/forward"
(`UniversalBackForwardTransformer`, `GestureKit`): navigation swipe gesture events for apps
that support them, mouse buttons 4/5 for the others.

`Sources/HyperSpaceInput/SystemActions.swift` and the media keys in `Post.swift` follow
LinearMouse's `ButtonActionExecutor`, `DockKit`, `KeyKit` and `GestureKit`: Dock
notifications, symbolic hot keys, the zoom toggle gesture, window maximize and
IOHIDSystem auxiliary keys.

`Sources/HyperSpaceInput/PointerSettings.swift` uses the same HID properties and speed
curve as LinearMouse's `PointerKit` (pointer resolution, acceleration,
`HIDUseLinearScalingMouseAcceleration`).

## AeroSpace — MIT License, Copyright (c) 2023 Nikita Bobko
https://github.com/nikitabobko/AeroSpace

The window manager (`Sources/HyperSpaceCore/WM`, `Sources/HyperSpaceWM`) follows
AeroSpace's model and command set: the normalized tiling tree, `move`/`join-with`
semantics, accordion padding, virtual workspaces parked in a screen corner, window
classification heuristics (which windows tile, which float) and the focus sequence
(main attribute, raise, activate). The code is a rewrite around an event-driven cache.

## TOMLDecoder — MIT License, Copyright (c) Daniel Duan
https://github.com/dduan/TOMLDecoder

Used as a dependency to parse the config file.
