import Foundation

/// `references-prose.bib`, the one bibliography file Prose writes (citations
/// note, decision 5): entries chosen from Zotero whose keys no project file
/// has yet. It sits beside the main file and is named in its
/// `#bibliography` call. When another file gains one of its keys (the next
/// Better BibTeX auto-export), Prose removes that entry again, because Typst
/// rejects a key defined twice.
public enum ProseBibliography {
    public static let fileName = "references-prose.bib"

    /// One BibLaTeX entry: its key and where it is in the text, from `@`
    /// through its closing delimiter.
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let range: Range<String.Index>
    }

    /// The entries of a BibLaTeX text, in order. `@comment`, `@string` and
    /// `@preamble` blocks are not entries. Braces are counted to find each
    /// entry's end, as BibTeX requires them balanced.
    public static func entries(in text: String) -> [Entry] {
        var entries: [Entry] = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            var cursor = text.index(after: at)
            let typeStart = cursor
            while cursor < text.endIndex, text[cursor].isLetter {
                cursor = text.index(after: cursor)
            }
            let type = text[typeStart ..< cursor].lowercased()
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard !type.isEmpty, cursor < text.endIndex, text[cursor] == "{" || text[cursor] == "(" else {
                index = text.index(after: at)
                continue
            }
            let close: Character = text[cursor] == "{" ? "}" : ")"
            let open = text[cursor]
            let bodyStart = text.index(after: cursor)
            // Find the end: the closing delimiter at depth 0.
            var depth = 0
            var end = bodyStart
            var found = false
            while end < text.endIndex {
                let character = text[end]
                if character == "{" || (open == "(" && character == "(") {
                    depth += 1
                } else if character == "}" || (open == "(" && character == ")") {
                    if depth == 0, character == close {
                        found = true
                        break
                    }
                    depth -= 1
                }
                end = text.index(after: end)
            }
            guard found else {
                break
            }
            let after = text.index(after: end)
            if !["comment", "string", "preamble"].contains(type) {
                let body = text[bodyStart ..< end]
                let key = body.prefix { $0 != "," }.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !key.contains("=") {
                    entries.append(Entry(key: key, range: at ..< after))
                }
            }
            index = after
        }
        return entries
    }

    public static func keys(in text: String) -> [String] {
        entries(in: text).map(\.key)
    }

    /// `text` with `addition` appended after a blank line, ending with a
    /// newline. The existing text is kept byte for byte.
    public static func appending(_ addition: String, to text: String) -> String {
        let entry = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else {
            return text
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry + "\n"
        }
        let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + entry + "\n"
    }

    /// `text` without the entries whose keys are in `keys`, with the blank
    /// space after each; every other byte is kept. Nil when none is there.
    public static func removing(_ keys: Set<String>, from text: String) -> String? {
        let doomed = entries(in: text).filter { keys.contains($0.key) }
        guard !doomed.isEmpty else {
            return nil
        }
        var result = text
        for entry in doomed.reversed() {
            var end = entry.range.upperBound
            while end < text.endIndex, text[end] == " " || text[end] == "\t" || text[end] == "\n" || text[end] == "\r" {
                end = text.index(after: end)
            }
            result.removeSubrange(entry.range.lowerBound ..< end)
        }
        return result
    }
}

/// Adding a file to the `#bibliography(...)` call in a Typst source.
public enum BibliographyCall {
    public enum Edit: Equatable, Sendable {
        /// Replace this UTF-16 range with the text.
        case replace(NSRange, String)
        /// The call already names the file.
        case alreadyNamed
        /// The source has no `bibliography(...)` call with a path.
        case noCall
        /// The call names its files with something other than string
        /// literals, such as a variable.
        case unsupported
    }

    /// The edit that makes the first `bibliography(...)` call with a path
    /// name `path` as well: `bibliography("refs.bib", style: "apa")` becomes
    /// `bibliography(("refs.bib", "references-prose.bib"), style: "apa")`,
    /// and an array gains one item at its end. Other arguments are kept.
    /// Calls in `//` comments and calls with no path (a `set` rule with only
    /// named arguments) are skipped.
    public static func adding(_ path: String, to source: String) -> Edit {
        let text = source as NSString
        let literal = quoted(path)
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: "bibliography(", options: [], range: search)
            guard found.location != NSNotFound else {
                return .noCall
            }
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            if found.location > 0, isIdentifier(text.character(at: found.location - 1)) || inLineComment(
                text,
                at: found.location,
            ) {
                continue
            }
            var scanner = Scanner16(text: text, location: NSMaxRange(found))
            scanner.skipSpace()
            switch scanner.peek {
            case Unit.quote:
                let start = scanner.location
                guard let value = scanner.string() else {
                    return .unsupported
                }
                if value == path {
                    return .alreadyNamed
                }
                let range = NSRange(location: start, length: scanner.location - start)
                return .replace(range, "(\(text.substring(with: range)), \(literal))")
            case Unit.open:
                scanner.location += 1
                var lastEnd: Int?
                while true {
                    scanner.skipSpace()
                    if scanner.peek == Unit.close {
                        break
                    }
                    guard scanner.peek == Unit.quote, let value = scanner.string() else {
                        return .unsupported
                    }
                    if value == path {
                        return .alreadyNamed
                    }
                    lastEnd = scanner.location
                    scanner.skipSpace()
                    if scanner.peek == Unit.comma {
                        scanner.location += 1
                    } else if scanner.peek != Unit.close {
                        return .unsupported
                    }
                }
                guard let lastEnd else {
                    return .replace(NSRange(location: scanner.location, length: 0), "\(literal),")
                }
                return .replace(NSRange(location: lastEnd, length: 0), ", \(literal)")
            default:
                // A named argument first: a call with no path, such as
                // `#set bibliography(style: "apa")`.
                let start = scanner.location
                while let unit = scanner.peek, isIdentifier(unit) {
                    scanner.location += 1
                }
                scanner.skipSpace()
                if scanner.location > start, scanner.peek == Unit.colon {
                    continue
                }
                if scanner.location == start, scanner.peek == Unit.close {
                    continue
                }
                return .unsupported
            }
        }
    }

    private enum Unit {
        static let quote: UInt16 = 0x22
        static let open: UInt16 = 0x28
        static let close: UInt16 = 0x29
        static let comma: UInt16 = 0x2C
        static let colon: UInt16 = 0x3A
        static let underscore: UInt16 = 0x5F
        static let hyphen: UInt16 = 0x2D
        static let period: UInt16 = 0x2E
        static let backslash: UInt16 = 0x5C
    }

    /// A Typst string literal.
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func isIdentifier(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || unit == Unit.underscore || unit == Unit.hyphen || unit == Unit.period
    }

    /// Whether `location` follows `//` on its line.
    private static func inLineComment(_ text: NSString, at location: Int) -> Bool {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: location - line.location))
        return before.contains("//")
    }

    /// Reads UTF-16 code units of a source.
    private struct Scanner16 {
        let text: NSString
        var location: Int

        var peek: UInt16? {
            location < text.length ? text.character(at: location) : nil
        }

        mutating func skipSpace() {
            while let unit = peek, unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
                location += 1
            }
        }

        /// A string literal at the location, unescaped; nil if it does not
        /// close.
        mutating func string() -> String? {
            guard peek == Unit.quote else {
                return nil
            }
            location += 1
            var units: [UInt16] = []
            while let unit = peek {
                location += 1
                if unit == Unit.backslash, let next = peek {
                    location += 1
                    units.append(next)
                } else if unit == Unit.quote {
                    return String(utf16CodeUnits: units, count: units.count)
                } else {
                    units.append(unit)
                }
            }
            return nil
        }
    }
}
