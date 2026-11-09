import Foundation
@testable import HyperSpace

func config(_ json: String) throws -> Config {
    try Config(JSONDecoder().decode(RawConfig.self, from: Data(json.utf8)))
}

/// The action bound to a shortcut, as text (Action is not Equatable).
func action(_ config: Config, _ keys: String) throws -> String? {
    let combo = try KeyCombo.parse(keys)
    let index = config.tap.keyTable[TapConfig.slot(Int(combo.keyCode), combo.modifiers)]
    return index >= 0 ? "\(config.tap.actions[Int(index)])" : nil
}
