import Foundation

/// The prose a spell checker reads: checkable ranges (decision 7 of the
/// Phase 4 note).
///
/// A checkable range is text of a markup node: the document's own markup and
/// the markup inside headings, list, enum and term items, strong and emphasis,
/// and content blocks (`[...]`) of function calls and other code (a footnote,
/// `#emph[...]`, a figure caption). Everything else is skipped: raw text,
/// equations and math, code (the name, arguments and strings of a call),
/// labels, references (with their supplements), links and URLs, comments,
/// escapes, shorthands, and `#set`, `#show`, `#let`, `#import` and `#include`
/// with everything inside them.
///
/// The syntax tree omits Text and Space leaves, so the text of a markup node
/// is what its children leave uncovered. Smart quotes count as text, so
/// `don't` stays one word.
///
/// **Node boundaries.** Typst does not let a strong or emphasis delimiter
/// close right before a letter, so `*bold*word` and `un_believ_able` are
/// plain text and stay one range (the checker splits them at `*` and `_` as
/// it does any punctuation). A word can still be cut at a node boundary
/// that the reader does not see: `#emph[un]believable`, or `*str*_ong_`. The
/// checker would read the pieces as separate words and report halves of a
/// word the reader sees whole. So where a range edge has a letter or digit
/// inside it and, outside it, nothing but `*`, `_` and `]` before another
/// letter or digit (or a letter or digit right away, where code abuts the
/// text), the letters touching that edge are dropped: no piece of such a
/// word is reported. Every other boundary (spaces, punctuation, `[`, `#`,
/// `$`, `@`, `<`, a backtick) ends a word, so `#footnote[text]` keeps
/// `text`. A `window` edge is taken as given; callers pass whole paragraphs.
public enum SpellCheckRanges {
    /// Node kinds whose whole range is skipped, children included.
    static let skipped: Set<SyntaxKind> = [
        .raw, .equation, .math, .str, .label, .ref, .link, .lineComment, .blockComment, .escape, .shorthand,
        .letBinding, .setRule, .showRule, .moduleImport, .moduleInclude,
    ]

    /// The checkable ranges of `source` within `window`, sorted and disjoint,
    /// from `nodes`: a pre-order list as `SyntaxTree.nodes(in:)` returns it
    /// for a window that covers `window`.
    public static func ranges(_ nodes: [SyntaxNode], source: NSString, within window: NSRange) -> [NSRange] {
        let window = NSIntersectionRange(window, NSRange(location: 0, length: source.length))
        guard window.length > 0, !nodes.isEmpty else {
            return []
        }
        let tree = SyntaxChildren(nodes)
        var excluded = [Bool](repeating: false, count: nodes.count)
        var gaps: [NSRange] = []
        for (index, node) in nodes.enumerated() {
            let parentExcluded = node.parent.map { $0 < index && excluded[$0] } ?? false
            excluded[index] = parentExcluded || skipped.contains(node.kind)
            guard node.kind == .markup, !excluded[index] else {
                continue
            }
            var cursor = node.range.location
            for child in tree.children[index].map({ nodes[$0] }) where child.kind != .smartQuote {
                if child.range.location > cursor {
                    gaps.append(NSRange(location: cursor, length: child.range.location - cursor))
                }
                cursor = max(cursor, NSMaxRange(child.range))
            }
            if NSMaxRange(node.range) > cursor {
                gaps.append(NSRange(location: cursor, length: NSMaxRange(node.range) - cursor))
            }
        }
        return merged(gaps).compactMap { gap in
            let clipped = NSIntersectionRange(gap, window)
            guard clipped.length > 0 else {
                return nil
            }
            return trimmed(clipped, in: source, gap: gap)
        }.filter { range in
            // Spaces and punctuation alone hold no word.
            (range.location ..< NSMaxRange(range)).contains { isWord(source, $0) }
        }
    }

    /// The checkable ranges of the text `tree` mirrors, within `window`.
    public static func ranges(_ tree: SyntaxTree, source: NSString, within window: NSRange) -> [NSRange] {
        ranges(tree.nodes(in: window) ?? [], source: source, within: window)
    }

    /// Whether a word the checker found misspelled is reported. Words with a
    /// digit, all-caps words of up to five letters (`NASA`, `HTML`) and words
    /// with a capital after a small letter (`camelCase`, `iPhone`,
    /// `McDonald`) are not, as NSTextView's checker leaves them by default.
    public static func reports(_ word: String) -> Bool {
        var letters = 0, lower = false, upperAfterLower = false, allUpper = true
        for character in word {
            if character.isNumber {
                return false
            }
            guard character.isLetter else {
                continue
            }
            letters += 1
            if character.isUppercase {
                upperAfterLower = upperAfterLower || lower
            } else {
                allUpper = false
                lower = lower || character.isLowercase
            }
        }
        if upperAfterLower {
            return false
        }
        return !(allUpper && letters > 0 && letters <= 5)
    }

    /// `range`, a part of the text gap `gap`, without the letters that touch
    /// a cut word at an edge of the gap; nil when nothing is left.
    private static func trimmed(_ range: NSRange, in source: NSString, gap: NSRange) -> NSRange? {
        var start = range.location, end = NSMaxRange(range)
        if start == gap.location, isWord(source, start), continuesWord(source, from: start - 1, step: -1) {
            while start < end, isWord(source, start) {
                start += 1
            }
        }
        if end == NSMaxRange(gap), isWord(source, end - 1), continuesWord(source, from: end, step: 1) {
            while end > start, isWord(source, end - 1) {
                end -= 1
            }
        }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Whether, from `offset` outward, only `*`, `_` and `]` lie before a
    /// letter or digit.
    private static func continuesWord(_ source: NSString, from offset: Int, step: Int) -> Bool {
        var offset = offset
        while offset >= 0, offset < source.length {
            let unit = source.character(at: offset)
            if unit == 0x2A || unit == 0x5F || unit == 0x5D {
                offset += step
                continue
            }
            return isWord(source, offset)
        }
        return false
    }

    /// A letter, mark or digit. Surrogates count, so a word with a letter
    /// outside the Basic Multilingual Plane is never cut by mistake.
    private static func isWord(_ source: NSString, _ offset: Int) -> Bool {
        guard offset >= 0, offset < source.length else {
            return false
        }
        let unit = source.character(at: offset)
        if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
            return true
        }
        return Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }

    /// Sorted, with touching and overlapping ranges joined.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
