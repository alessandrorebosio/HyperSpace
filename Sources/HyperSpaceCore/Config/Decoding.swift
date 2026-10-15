/// Coding key that accepts any name, used to list the keys actually present in a table.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// A keyed container for a TOML table whose keys must all be in `Key`.
    func table<Key: CodingKey & CaseIterable>(_ keys: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try rejectUnknownKeys(keys)
        return try container(keyedBy: keys)
    }

    /// Throws on keys the model doesn't know, so a typo like `capslok` isn't silently ignored.
    func rejectUnknownKeys<Key: CodingKey & CaseIterable>(_: Key.Type) throws {
        // TOMLDecoder hands out a keyed container even for scalars and arrays, so check first.
        guard isTable else {
            throw DecodingError.typeMismatch([String: Any].self, .init(codingPath: codingPath, debugDescription: "expected a table"))
        }
        let known = Set(Key.allCases.map(\.stringValue))
        let present = try container(keyedBy: AnyKey.self).allKeys
        if let unknown = present.first(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath + [unknown],
                debugDescription: "unknown key; expected one of: \(known.sorted().joined(separator: ", "))"
            ))
        }
    }

    private var isTable: Bool {
        if (try? unkeyedContainer()) != nil { return false }
        guard let single = try? singleValueContainer() else { return true }
        return (try? single.decode(String.self)) == nil
            && (try? single.decode(Int.self)) == nil
            && (try? single.decode(Double.self)) == nil
            && (try? single.decode(Bool.self)) == nil
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, default value: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? value()
    }
}
