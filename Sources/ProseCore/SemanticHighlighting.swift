import Foundation

public struct HighlightToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: String
    public let modifiers: [String]

    public init(range: NSRange, kind: String, modifiers: [String] = []) {
        self.range = range
        self.kind = kind
        self.modifiers = modifiers
    }
}

public enum SemanticHighlighting {
    public static let tokenTypes = [
        "comment",
        "string",
        "keyword",
        "operator",
        "number",
        "function",
        "decorator",
        "type",
        "namespace",
        "bool",
        "punct",
        "escape",
        "link",
        "raw",
        "label",
        "ref",
        "heading",
        "marker",
        "term",
        "delim",
        "pol",
        "error",
        "text",
    ]
    public static let tokenModifiers = ["strong", "emph", "math", "readonly", "static", "defaultLibrary"]

    /// Decode LSP's relative positions against the exact requested UTF-16 buffer.
    /// Reject malformed responses rather than applying clamped, unrelated ranges.
    public static func decode(_ data: [Int], source: String, types: [String], modifiers: [String]) -> [HighlightToken] {
        guard data.count.isMultiple(of: 5) else {
            return []
        }
        let units = Array(source.utf16)
        var starts = [0], ends: [Int] = [], cursor = 0
        while cursor < units.count {
            if units[cursor] == 10 || units[cursor] == 13 {
                ends.append(cursor)
                if units[cursor] == 13, cursor + 1 < units.count, units[cursor + 1] == 10 {
                    cursor += 1
                }
                starts.append(cursor + 1)
            }
            cursor += 1
        }
        ends.append(units.count)
        var line = 0, column = 0, tokens: [HighlightToken] = []
        for index in stride(from: 0, to: data.count, by: 5) {
            let deltaLine = data[index], deltaColumn = data[index + 1], length = data[index + 2]
            let type = data[index + 3], bits = data[index + 4]
            guard deltaLine >= 0, deltaLine < starts.count - line,
                  deltaColumn >= 0, deltaColumn <= units.count, length > 0,
                  types.indices.contains(type), bits >= 0
            else {
                return []
            }
            line += deltaLine
            column = deltaLine == 0 ? column + deltaColumn : deltaColumn
            // Tinymist emits an explicit newline token even with multiline
            // tokens disabled. It may include this line's terminator, not the next line.
            let lineEnd = line + 1 < starts.count ? starts[line + 1] : units.count
            guard column <= ends[line] - starts[line], length <= lineEnd - starts[line] - column else {
                return []
            }
            let range = NSRange(location: starts[line] + column, length: length)
            func splitsSurrogate(_ offset: Int) -> Bool {
                offset > 0 && offset < units.count && (0xD800 ... 0xDBFF)
                    .contains(units[offset - 1]) && (0xDC00 ... 0xDFFF).contains(units[offset])
            }
            guard !splitsSurrogate(range.location), !splitsSurrogate(NSMaxRange(range)) else {
                return []
            }
            let flags = modifiers.enumerated().compactMap { index, name in
                index < 32 && bits & (1 << index) != 0 ? name : nil
            }
            tokens.append(.init(range: range, kind: types[type], modifiers: flags))
        }
        return tokens
    }
}
