import Foundation


/// AeroSpace's small shell, used by bindings, callbacks and `hsctl`:
/// `a; b` runs both, `a && b` runs b if a succeeded, `a || b` if it failed, parentheses group.
/// As in AeroSpace, `&&` binds tighter than `||`, and `exec-and-forget` takes the rest of
/// the text as is, so its bash script can contain anything.
public indirect enum WMScript: Sendable, Equatable {
    case command(WMCommand)
    case sequence([WMScript])
    case and(WMScript, WMScript)
    case or(WMScript, WMScript)

    public init(parsing text: String) throws(InvalidConfig) {
        var parser = ScriptParser(tokens: try Shell.tokens(text))
        guard !parser.tokens.isEmpty else { throw InvalidConfig(message: "empty command") }
        self = try parser.sequence()
        if let extra = parser.tokens.first { throw InvalidConfig(message: "unexpected '\(extra.text)'") }
    }

    /// Several commands from a TOML array, run in order like `;`.
    public init(commands: [String]) throws(InvalidConfig) {
        var scripts: [WMScript] = []
        for command in commands { scripts.append(try WMScript(parsing: command)) }
        self = scripts.count == 1 ? scripts[0] : .sequence(scripts)
    }

    /// Every command in the script, in order (for validation).
    public var commands: [WMCommand] {
        switch self {
        case let .command(command): [command]
        case let .sequence(scripts): scripts.flatMap(\.commands)
        case let .and(a, b), let .or(a, b): a.commands + b.commands
        }
    }

    /// Runs the script; `run` performs one command and says whether it succeeded.
    @discardableResult
    public func run(_ run: (WMCommand) -> Bool) -> Bool {
        switch self {
        case let .command(command): return run(command)
        case let .sequence(scripts):
            var ok = true
            for script in scripts { ok = script.run(run) }
            return ok
        case let .and(a, b): return a.run(run) && b.run(run)
        case let .or(a, b): return a.run(run) || b.run(run)
        }
    }
}

/// Splitting command text like a shell: quotes and backslashes group words.
public enum Shell {
    public enum Token: Equatable {
        case word(String)
        case op(String)

        var text: String {
            switch self {
            case let .word(word): word
            case let .op(op): op
            }
        }
    }

    /// The words of a single command.
    public static func words(_ text: String) throws(InvalidConfig) -> [String] {
        try tokens(text).map { token throws(InvalidConfig) in
            guard case let .word(word) = token else {
                throw InvalidConfig(message: "'\(token.text)' can only be used in bindings and callbacks")
            }
            return word
        }
    }

    public static func tokens(_ text: String) throws(InvalidConfig) -> [Token] {
        var tokens: [Token] = []
        var chars = Array(text)[...]
        var commandStart = true
        while let c = chars.first {
            if c.isWhitespace {
                chars.removeFirst()
                continue
            }
            let two = String(chars.prefix(2))
            if two == "&&" || two == "||" {
                tokens.append(.op(two))
                chars.removeFirst(2)
                commandStart = true
                continue
            }
            if c == ";" || c == "(" || c == ")" {
                tokens.append(.op(String(c)))
                chars.removeFirst()
                commandStart = c != ")"
                continue
            }
            if c == "|" { throw InvalidConfig(message: "pipes ('|') aren't supported") }
            var word = ""
            var quote: Character?
            while let c = chars.first {
                if let open = quote {
                    chars.removeFirst()
                    if c == open { quote = nil } else if c == "\\", open == "\"", let next = chars.first {
                        word.append(next)
                        chars.removeFirst()
                    } else { word.append(c) }
                } else if c == "'" || c == "\"" {
                    quote = c
                    chars.removeFirst()
                } else if c == "\\", chars.count > 1 {
                    chars.removeFirst()
                    word.append(chars.removeFirst())
                } else if c.isWhitespace || ";()|".contains(c) || (c == "&" && chars.dropFirst().first == "&") {
                    break
                } else {
                    word.append(c)
                    chars.removeFirst()
                }
            }
            if quote != nil { throw InvalidConfig(message: "unterminated quote") }
            tokens.append(.word(word))
            // exec-and-forget passes the rest of the text to bash untouched.
            if commandStart, word == "exec-and-forget" {
                let script = String(chars).trimmingCharacters(in: .whitespaces)
                if !script.isEmpty { tokens.append(.word(script)) }
                break
            }
            commandStart = false
        }
        return tokens
    }
}

private struct ScriptParser {
    var tokens: [Shell.Token]

    mutating func sequence() throws(InvalidConfig) -> WMScript {
        var items = [try or()]
        while tokens.first == .op(";") {
            tokens.removeFirst()
            if tokens.isEmpty || tokens.first == .op(")") { break } // trailing ';'
            items.append(try or())
        }
        return items.count == 1 ? items[0] : .sequence(items)
    }

    mutating func or() throws(InvalidConfig) -> WMScript {
        var left = try and()
        while tokens.first == .op("||") {
            tokens.removeFirst()
            left = .or(left, try and())
        }
        return left
    }

    mutating func and() throws(InvalidConfig) -> WMScript {
        var left = try primary()
        while tokens.first == .op("&&") {
            tokens.removeFirst()
            left = .and(left, try primary())
        }
        return left
    }

    mutating func primary() throws(InvalidConfig) -> WMScript {
        if tokens.first == .op("(") {
            tokens.removeFirst()
            let inner = try sequence()
            guard tokens.first == .op(")") else { throw InvalidConfig(message: "missing ')'") }
            tokens.removeFirst()
            return inner
        }
        var words: [String] = []
        while case let .word(word)? = tokens.first {
            words.append(word)
            tokens.removeFirst()
        }
        guard !words.isEmpty else { throw InvalidConfig(message: "expected a command" + (tokens.first.map { " before '\($0.text)'" } ?? "")) }
        return .command(try WMCommand(words: words))
    }
}
