import Foundation

public struct InsertionPlan: Sendable {
    public let snippet: Snippet
    public let range: NSRange

    public init(command: WritingCommand, snippet: Snippet, text: String, selection: NSRange) {
        let source = text as NSString
        if command.placement == .preamble {
            let offset = Self.preambleEnd(text)
            range = NSRange(location: offset, length: 0)
            let before = offset > 0 && source
                .substring(with: NSRange(location: offset - 1, length: 1)) != "\n" ? "\n" : ""
            self.snippet = snippet.padded(before: before, after: "\n")
        } else {
            if command.placement == .block {
                let before = source.substring(to: selection.location)
                let after = source.substring(from: NSMaxRange(selection))
                // Include the existing separator in this undoable replacement,
                // so the caret lands in body text beyond the inserted block.
                let separator = String(after.prefix(while: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).prefix(2))
                range = NSRange(location: selection.location, length: selection.length + separator.utf16.count)
                self.snippet = snippet.padded(
                    before: before.isEmpty || before.hasSuffix("\n") ? "" : "\n\n",
                    after: "\n\n",
                )
            } else {
                range = selection
                self.snippet = snippet
            }
        }
    }

    /// Place document settings after the existing initial set rules, so they take effect.
    public static func preambleEnd(_ text: String) -> Int {
        let units = Array(text.utf16)
        var cursor = 0
        var lastRule = 0
        while cursor < units.count {
            while cursor < units.count, [9, 10, 13, 32].contains(units[cursor]) {
                cursor += 1
            }
            if cursor + 1 < units.count, units[cursor] == 47, units[cursor + 1] == 47 {
                while cursor < units.count, units[cursor] != 10 {
                    cursor += 1
                }
                continue
            }
            guard String(decoding: units[cursor...].prefix(5), as: UTF16.self) == "#set " else {
                break
            }
            var depth = 0, sawOpen = false, inString = false, escaped = false
            while cursor < units.count {
                let c = units[cursor]
                cursor += 1
                if escaped {
                    escaped = false
                    continue
                }
                if inString, c == 92 {
                    escaped = true
                    continue
                }
                if c == 34 {
                    inString.toggle()
                    continue
                }
                if inString {
                    continue
                }
                if c == 40 {
                    depth += 1
                    sawOpen = true
                }
                if c == 41 {
                    depth -= 1
                }
                if sawOpen, depth == 0 {
                    lastRule = cursor
                    break
                }
                if !sawOpen, c == 10 {
                    return lastRule
                }
            }
            if depth != 0 || !sawOpen {
                break
            }
        }
        return lastRule
    }
}
