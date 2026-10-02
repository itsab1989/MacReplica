import Foundation

/// A small reader for the TOML subset that tool configuration files use: tables (`[a.b]`),
/// `key = value` pairs with strings, numbers, booleans, arrays and inline tables (arrays may span
/// lines). Dates, arrays of tables (`[[x]]`) and multi-line strings are skipped.
///
/// It only reads; values are returned as `String`, `Bool`, `Double`/`Int`, `[Any]` and `[String: Any]`.
public enum MiniTOML {
    public static func parse(_ text: String) -> [String: Any] {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return parser.document()
    }

    /// The value at a dotted path, e.g. `envs.demo.dependencies`.
    public static func value(_ document: [String: Any], _ path: [String]) -> Any? {
        var current: Any? = document
        for key in path { current = (current as? [String: Any])?[key] }
        return current
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }
        var current: Unicode.Scalar? { atEnd ? nil : scalars[index] }

        mutating func document() -> [String: Any] {
            var root: [String: Any] = [:]
            var table: [String] = []
            var skippingArrayTable = false
            while !atEnd {
                skipWhitespaceAndComments(newlines: true)
                guard let character = current else { break }
                if character == "[" {
                    if index + 1 < scalars.count, scalars[index + 1] == "[" {
                        skippingArrayTable = true
                        skipLine()
                        continue
                    }
                    index += 1
                    table = keyPath(until: "]")
                    index += 1
                    skippingArrayTable = false
                    Self.ensureTable(&root, table)
                    skipLine()
                    continue
                }
                let key = keyPath(until: "=")
                guard current == "=" else { skipLine(); continue }
                index += 1
                skipWhitespaceAndComments(newlines: false)
                let value = parseValue()
                if !skippingArrayTable, !key.isEmpty, let value { Self.set(&root, table + key, value) }
                skipLine()
            }
            return root
        }

        mutating func keyPath(until terminator: Unicode.Scalar) -> [String] {
            var parts: [String] = []
            var bare = ""
            while let character = current, character != terminator, character != "\n" {
                if character == "\"" || character == "'" {
                    parts.append(parseString() ?? "")
                    continue
                }
                if character == "." {
                    if !bare.isEmpty { parts.append(bare.trimmingCharacters(in: .whitespaces)) }
                    bare = ""
                } else if character != " " && character != "\t" {
                    bare.unicodeScalars.append(character)
                }
                index += 1
            }
            if !bare.isEmpty { parts.append(bare) }
            return parts
        }

        mutating func parseValue() -> Any? {
            guard let character = current else { return nil }
            switch character {
            case "\"", "'":
                return parseString()
            case "[":
                index += 1
                var items: [Any] = []
                while true {
                    skipWhitespaceAndComments(newlines: true)
                    guard let next = current else { return items }
                    if next == "]" { index += 1; return items }
                    if next == "," { index += 1; continue }
                    guard let item = parseValue() else { index += 1; continue }
                    items.append(item)
                }
            case "{":
                index += 1
                var table: [String: Any] = [:]
                while true {
                    skipWhitespaceAndComments(newlines: false)
                    guard let next = current else { return table }
                    if next == "}" { index += 1; return table }
                    if next == "," { index += 1; continue }
                    let key = keyPath(until: "=")
                    guard current == "=" else { return table }
                    index += 1
                    skipWhitespaceAndComments(newlines: false)
                    if let value = parseValue(), !key.isEmpty { Self.set(&table, key, value) }
                }
            default:
                var word = ""
                while let next = current, !",]}\n#".unicodeScalars.contains(next) {
                    word.unicodeScalars.append(next)
                    index += 1
                }
                word = word.trimmingCharacters(in: .whitespaces)
                if word == "true" { return true }
                if word == "false" { return false }
                if let integer = Int(word.replacingOccurrences(of: "_", with: "")) { return integer }
                if let number = Double(word.replacingOccurrences(of: "_", with: "")) { return number }
                return word.isEmpty ? nil : word
            }
        }

        mutating func parseString() -> String? {
            guard let quote = current else { return nil }
            index += 1
            var result = ""
            while let character = current {
                index += 1
                if character == quote { return result }
                if character == "\n" { return result }
                if quote == "\"", character == "\\", let escaped = current {
                    index += 1
                    switch escaped {
                    case "n": result += "\n"
                    case "t": result += "\t"
                    case "\\": result += "\\"
                    case "\"": result += "\""
                    default: result.unicodeScalars.append(escaped)
                    }
                    continue
                }
                result.unicodeScalars.append(character)
            }
            return result
        }

        mutating func skipWhitespaceAndComments(newlines: Bool) {
            while let character = current {
                if character == " " || character == "\t" || character == "\r" || (newlines && character == "\n") {
                    index += 1
                } else if character == "#" {
                    while let next = current, next != "\n" { index += 1 }
                } else {
                    return
                }
            }
        }

        mutating func skipLine() {
            while let character = current, character != "\n" { index += 1 }
            if current == "\n" { index += 1 }
        }

        static func ensureTable(_ root: inout [String: Any], _ path: [String]) {
            guard let first = path.first else { return }
            var child = root[first] as? [String: Any] ?? [:]
            ensureTable(&child, Array(path.dropFirst()))
            root[first] = child
        }

        static func set(_ root: inout [String: Any], _ path: [String], _ value: Any) {
            guard let first = path.first else { return }
            if path.count == 1 { root[first] = value; return }
            var child = root[first] as? [String: Any] ?? [:]
            set(&child, Array(path.dropFirst()), value)
            root[first] = child
        }
    }
}
