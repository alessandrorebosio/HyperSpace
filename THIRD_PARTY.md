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

## TOMLDecoder — MIT License, Copyright (c) Daniel Duan
https://github.com/dduan/TOMLDecoder

Used as a dependency to parse the config file.
