import Foundation

/// A single index per text revision; cursor movement never rescans the manuscript.
public struct DocumentMetrics: Sendable {
    public private(set) var wordCount: Int
    private var lines: TextLineIndex

    public init(_ text: String) {
        wordCount = Self.count(text)
        lines = TextLineIndex(text)
    }

    /// Native character edits update only their surrounding lines. Expanding
    /// the range preserves grapheme counts for combining marks, ZWJ emoji and
    /// newline joins; counting only inserted/deleted Characters would be wrong.
    @discardableResult public mutating func apply(_ edit: TextReplacement, to original: String) -> Bool {
        let source = original as NSString
        guard source.length == lines.length, edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= source.length,
              edit.range.length <= source.length - edit.range.location
        else {
            return false
        }
        let range = lines.rescanRange(for: edit.range)
        let before = source.substring(with: range)
        let after = NSMutableString(string: before)
        after.replaceCharacters(
            in: NSRange(location: edit.range.location - range.location, length: edit.range.length),
            with: edit.text,
        )
        let changed = after as String
        wordCount += Self.count(changed) - Self.count(before)
        lines.replaceLines(in: range, with: changed)
        return true
    }

    private static func count(_ text: String) -> Int {
        // AppKit strings may use foreign UTF-16 storage. Materialize Swift's
        // native representation once, rather than bridging per grapheme.
        var value = text
        value.makeContiguousUTF8()
        return value.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    public func position(at offset: Int) -> TextPosition {
        lines.position(at: offset)
    }

    public func offset(at position: TextPosition) -> Int {
        lines.offset(at: position)
    }
}
