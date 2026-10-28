enum DefaultConfig {
    static let json = """
    {
      "keyboard": {
        "hyperKey": "caps_lock",
        "remap": [],
        "bindings": [
          { "keys": "hyper+h", "action": "focus left" },
          { "keys": "hyper+j", "action": "focus down" },
          { "keys": "hyper+k", "action": "focus up" },
          { "keys": "hyper+l", "action": "focus right" },
          { "keys": "hyper+left", "action": "swap left" },
          { "keys": "hyper+down", "action": "swap down" },
          { "keys": "hyper+up", "action": "swap up" },
          { "keys": "hyper+right", "action": "swap right" },
          { "keys": "hyper+return", "action": "swap master" },
          { "keys": "hyper+space", "action": "layout next" },
          { "keys": "hyper+f", "action": "float" },
          { "keys": "hyper+minus", "action": "ratio -0.05" },
          { "keys": "hyper+equal", "action": "ratio +0.05" },
          { "keys": "hyper+r", "action": "retile" },
          { "keys": "hyper+n", "action": "display next" },
          { "keys": "hyper+t", "action": "launch Terminal" },
          { "keys": "hyper+escape", "action": "reload" }
        ]
      },
      "mouse": {
        "reverseScroll": false,
        "dragModifier": "ctrl+alt",
        "buttons": [
          { "button": 3, "action": "key cmd+[" },
          { "button": 4, "action": "key cmd+]" }
        ]
      },
      "tiling": {
        "enabled": true,
        "layout": "tall",
        "gap": 8,
        "padding": 8,
        "masterRatio": 0.55,
        "floating": [
          "com.apple.systempreferences",
          "com.apple.calculator",
          "com.apple.ActivityMonitor",
          "com.apple.finder"
        ]
      }
    }

    """
}
