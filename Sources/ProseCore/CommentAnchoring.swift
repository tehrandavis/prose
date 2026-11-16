import Foundation

/// Where a new comment's start marker and end marker go (Phase 8 note,
/// decision 2, as step A corrected it).
///
/// A marker may stand only in markup: between two children of a markup node
/// or inside plain text, including the markup of content blocks. The
/// selection is trimmed of whitespace, then each end moves to the nearest
/// allowed place, outward, so the anchor only grows. An end marker after a
/// `*` moves inside it, and an end marker after a bare URL goes after the
/// next space or before the URL. Last, the check: the text around the anchor
/// is parsed with both markers in place, and its flattened tree, without the
/// two new comment nodes and with offsets moved back, must equal the tree
/// before. Any other difference, or a new error, is a refusal.
public enum CommentAnchoring {
    /// The offsets in the source where the start marker and the end marker
    /// go. `start < end`.
    public struct Anchor: Equatable, Sendable {
        public let start: Int
        public let end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// A caret with no word at it: Add Comment does nothing.
        case noWord
        /// The selection holds only whitespace.
        case empty
        /// No safe place: "Prose cannot attach a comment to this selection".
        case unsafe
    }

    /// Nodes whose inside is never a place for a marker.
    static let opaque: Set<SyntaxKind> = [
        .equation, .math, .raw, .str, .label, .ref, .link, .escape, .shorthand, .linebreak, .lineComment,
        .blockComment, .error, .smartQuote,
    ]
    /// Nodes that hold markup and delimiters around it.
    static let containers: Set<SyntaxKind> = [
        .markup, .strong, .emph, .heading, .listItem, .enumItem, .termItem, .contentBlock,
    ]
    static let items: Set<SyntaxKind> = [.listItem, .enumItem, .termItem]
    static let lineMarkers: Set<SyntaxKind> = [.headingMarker, .listMarker, .enumMarker, .termMarker]
    static let statements: Set<SyntaxKind> = [.letBinding, .setRule, .showRule, .moduleImport, .moduleInclude]

    /// The anchor for `selection` in `source`, which `tree` mirrors.
    public static func anchor(
        for selection: NSRange,
        in source: NSString,
        tree: SyntaxTree,
    ) -> Result<Anchor, Refusal> {
        let lower = min(max(0, selection.location), source.length)
        let upper = min(max(lower, NSMaxRange(selection)), source.length)
        var range = NSRange(location: lower, length: upper - lower)
        if range.length == 0 {
            guard let word = word(at: lower, in: source) else {
                return .failure(.noWord)
            }
            range = word
        }
        let trimmed = CommentIndex.trimmed(range, in: source)
        guard trimmed.length > 0 else {
            return .failure(.empty)
        }
        guard var start = snap(trimmed.location, isStart: true, source: source, tree: tree),
              var end = snap(NSMaxRange(trimmed), isStart: false, source: source, tree: tree)
        else {
            return .failure(.unsafe)
        }
        // A snap of one end can make the other's place unsafe only through
        // the check, so one more pass settles both.
        guard let settledStart = snap(start, isStart: true, source: source, tree: tree),
              let settledEnd = snap(end, isStart: false, source: source, tree: tree)
        else {
            return .failure(.unsafe)
        }
        (start, end) = (settledStart, settledEnd)
        guard start < end, isSafe(start: start, end: end, source: source, tree: tree) else {
            return .failure(.unsafe)
        }
        return .success(Anchor(start: start, end: end))
    }

    // MARK: The word at the caret

    /// The word at `location`: letters, digits and marks, with an apostrophe
    /// between two letters; nil when neither side of the caret is a word.
    static func word(at location: Int, in source: NSString) -> NSRange? {
        func character(_ range: NSRange) -> Character {
            Character(source.substring(with: range))
        }
        func isWord(_ range: NSRange) -> Bool {
            let value = character(range)
            return value.isLetter || value.isNumber
        }
        func isApostrophe(_ range: NSRange) -> Bool {
            ["'", "\u{2019}"].contains(character(range))
        }
        var start = location, end = location
        while start > 0 {
            let previous = source.rangeOfComposedCharacterSequence(at: start - 1)
            if isWord(previous) {
                start = previous.location
            } else if isApostrophe(previous), previous.location > 0, start < source.length,
                      isWord(source.rangeOfComposedCharacterSequence(at: previous.location - 1)),
                      isWord(source.rangeOfComposedCharacterSequence(at: start))
            {
                start = previous.location
            } else {
                break
            }
        }
        while end < source.length {
            let next = source.rangeOfComposedCharacterSequence(at: end)
            if isWord(next) {
                end = NSMaxRange(next)
            } else if isApostrophe(next), end > 0, NSMaxRange(next) < source.length,
                      isWord(source.rangeOfComposedCharacterSequence(at: end - 1)),
                      isWord(source.rangeOfComposedCharacterSequence(at: NSMaxRange(next)))
            {
                end = NSMaxRange(next)
            } else {
                break
            }
        }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: Snapping

    /// `offset` moved to an allowed place; nil when there is none.
    static func snap(_ offset: Int, isStart: Bool, source: NSString, tree: SyntaxTree) -> Int? {
        var offset = offset
        for _ in 0 ..< 64 {
            guard let moved = step(offset, isStart: isStart, source: source, tree: tree) else {
                return nil
            }
            if moved == offset {
                return offset
            }
            offset = moved
        }
        return nil
    }

    /// One move toward an allowed place: `offset` itself when it is one,
    /// nil when there is none.
    private static func step(_ offset: Int, isStart: Bool, source: NSString, tree: SyntaxTree) -> Int? {
        guard let nodes = tree.nodes(in: NSRange(location: offset, length: 0)), !nodes.isEmpty else {
            return nil
        }
        // The nodes that hold `offset` inside them, outermost first.
        let chain = nodes.indices.filter { nodes[$0].range.location < offset && offset < NSMaxRange(nodes[$0].range) }
        if let outer = chain.first(where: { opaque.contains(nodes[$0].kind) }) {
            return isStart ? nodes[outer].range.location : NSMaxRange(nodes[outer].range)
        }
        // The markup node whose children `offset` lies between.
        var markup = 0
        if let deepest = chain.last {
            let node = nodes[deepest]
            if node.kind == .markup {
                markup = deepest
            } else if containers.contains(node.kind) {
                let inner = nodes.indices.filter { nodes[$0].parent == deepest && nodes[$0].kind == .markup }
                if let edge = inner.first(where: {
                    nodes[$0].range.location == offset || NSMaxRange(nodes[$0].range) == offset
                }) {
                    markup = edge
                } else if let next = inner.first(where: { nodes[$0].range.location > offset }),
                          node.kind == .heading || items.contains(node.kind)
                {
                    // Between a line's marker and its text.
                    return nodes[next].range.location
                } else {
                    return isStart ? node.range.location : NSMaxRange(node.range)
                }
            } else {
                // Code: a call's name or arguments, a code block, a field.
                return isStart ? node.range.location : NSMaxRange(node.range)
            }
        }
        let siblings = nodes.indices.filter { nodes[$0].parent == markup }
        let previous = siblings.last { NSMaxRange(nodes[$0].range) == offset && nodes[$0].range.length > 0 }
        let next = siblings.first { nodes[$0].range.location == offset && nodes[$0].range.length > 0 }

        if isStart, let moved = lineStart(offset, nodes: nodes, chain: chain, source: source, tree: tree) {
            return moved
        }
        // Directly after a `*`: a stray end of comment (fact 11).
        if offset > 0, source.character(at: offset - 1) == 0x2A {
            return offset - 1
        }
        if let previous, nodes[previous].kind == .hash {
            if isStart {
                return nodes[previous].range.location
            }
            return next.map { NSMaxRange(nodes[$0].range) } ?? nodes[previous].range.location
        }
        if let previous, nodes[previous].kind == .link {
            // A bare URL reads a following comment into itself (fact 4).
            if isStart {
                return nodes[previous].range.location
            }
            if offset < source.length, [0x20, 0x09].contains(source.character(at: offset)) {
                return offset + 1
            }
            return nodes[previous].range.location
        }
        if endsStatementLine(offset, source: source, tree: tree, markup: nodes[markup]) {
            // A comment there keeps the line break that Typst drops (fact 12).
            guard !isStart else {
                return nil
            }
            var hash = offset
            while hash > 0, [0x20, 0x09].contains(source.character(at: hash - 1)) {
                hash -= 1
            }
            guard let statement = (tree.nodes(in: NSRange(location: hash, length: 0)) ?? []).last(where: {
                statements.contains($0.kind) && NSMaxRange($0.range) == hash
            }), statement.range.location > 0 else {
                return nil
            }
            return statement.range.location - 1
        }
        return offset
    }

    /// The rules for a start marker at the first character of a line: after
    /// a heading, list, numbered or term marker and its space; and, where the
    /// line continues a list, numbered or term item or follows one, at the
    /// end of the line before, since a comment moves the column (fact 10).
    private static func lineStart(
        _ offset: Int,
        nodes: [SyntaxNode],
        chain: [Int],
        source: NSString,
        tree: SyntaxTree,
    ) -> Int? {
        var lineStart = offset
        while lineStart > 0, !CommentSyntax.isNewline(unit: source.character(at: lineStart - 1)) {
            guard [0x20, 0x09].contains(source.character(at: lineStart - 1)) else {
                return nil
            }
            lineStart -= 1
        }
        if let marker = nodes.first(where: { lineMarkers.contains($0.kind) && $0.range.location == offset }) {
            var after = NSMaxRange(marker.range)
            while after < source.length, [0x20, 0x09].contains(source.character(at: after)) {
                after += 1
            }
            return after
        }
        guard lineStart > 0 else {
            return nil
        }
        // The end of the previous line's text.
        var previousEnd = lineStart - 1
        if previousEnd > 0, source.character(at: previousEnd) == 0x0A, source.character(at: previousEnd - 1) == 0x0D {
            previousEnd -= 1
        }
        while previousEnd > 0, [0x20, 0x09].contains(source.character(at: previousEnd - 1)) {
            previousEnd -= 1
        }
        guard previousEnd > 0, !CommentSyntax.isNewline(unit: source.character(at: previousEnd - 1)) else {
            return nil
        }
        let insideItem = chain.contains { items.contains(nodes[$0].kind) }
        let afterItem = (tree.nodes(in: NSRange(location: previousEnd, length: 0)) ?? []).contains {
            items.contains($0.kind) && $0.range.location < previousEnd && previousEnd <= NSMaxRange($0.range)
        }
        return insideItem || afterItem ? previousEnd : nil
    }

    /// Whether `offset` is at the end of a line whose last expression is a
    /// `#let`, `#set`, `#show`, `#import` or `#include` statement.
    private static func endsStatementLine(
        _ offset: Int,
        source: NSString,
        tree: SyntaxTree,
        markup: SyntaxNode,
    ) -> Bool {
        var after = offset
        while after < source.length, [0x20, 0x09].contains(source.character(at: after)) {
            after += 1
        }
        guard after == source.length || CommentSyntax.isNewline(unit: source.character(at: after)) else {
            return false
        }
        var before = offset
        while before > 0, [0x20, 0x09].contains(source.character(at: before - 1)) {
            before -= 1
        }
        guard before > 0 else {
            return false
        }
        return (tree.nodes(in: NSRange(location: before, length: 0)) ?? []).contains {
            statements.contains($0.kind) && NSMaxRange($0.range) == before && markup.range.location <= $0.range.location
        }
    }

    // MARK: The check

    /// Whether markers at `start` and `end` leave the tree as it was: the
    /// top-level blocks around them, parsed alone with and without the two,
    /// have the same flattened tree once the two comment nodes are left out
    /// and offsets are moved back, and no new error.
    static func isSafe(start: Int, end: Int, source: NSString, tree: SyntaxTree) -> Bool {
        guard start >= 0, start < end, end <= source.length else {
            return false
        }
        let region = blocks(around: NSRange(location: start, length: end - start), source: source, tree: tree)
        let text = source.substring(with: region)
        let marked = NSMutableString(string: text)
        let (localStart, localEnd) = (start - region.location, end - region.location)
        marked.insert(CommentSyntax.endMarker("aaaaaa"), at: localEnd)
        marked.insert(CommentSyntax.startMarker("aaaaaa"), at: localStart)
        guard let before = SyntaxTree(text)?.nodes(), let after = SyntaxTree(marked as String)?.nodes() else {
            return false
        }
        let length = CommentSyntax.markerLength
        let inserted = [
            NSRange(location: localStart, length: length),
            NSRange(location: localEnd + length, length: length),
        ]
        let removed = after.indices.filter { after[$0].kind == .blockComment && inserted.contains(after[$0].range) }
        guard removed.count == 2 else {
            return false
        }
        // Offsets in the marked text back to the text before; nil inside a marker.
        func back(_ offset: Int) -> Int? {
            if offset <= localStart {
                return offset
            }
            if offset < localStart + length {
                return nil
            }
            if offset <= localEnd + length {
                return offset - length
            }
            if offset < localEnd + 2 * length {
                return nil
            }
            return offset - 2 * length
        }
        var newIndex = [Int?](repeating: nil, count: after.count)
        var kept: [SyntaxNode] = []
        for (index, node) in after.enumerated() where !removed.contains(index) {
            guard let lower = back(node.range.location), let upper = back(NSMaxRange(node.range)) else {
                return false
            }
            newIndex[index] = kept.count
            kept.append(SyntaxNode(
                kind: node.kind,
                range: NSRange(location: lower, length: upper - lower),
                parent: node.parent.flatMap { newIndex[$0] },
                depth: node.depth,
                isErroneous: node.isErroneous,
            ))
        }
        return kept == before
    }

    /// The top-level blocks that hold `range`: from the blank line at the top
    /// level before it to the one after it, or the file's edges.
    static func blocks(around range: NSRange, source: NSString, tree: SyntaxTree) -> NSRange {
        func isBreak(_ offset: Int) -> NSRange? {
            (tree.nodes(in: NSRange(location: offset, length: 0)) ?? []).first {
                $0.kind == .parbreak && $0.depth == 1 && $0.range.location <= offset && offset <= NSMaxRange($0.range)
            }?.range
        }
        var lower = 0
        var cursor = range.location
        while cursor > 0 {
            cursor -= 1
            if source.character(at: cursor) == 0x0A, let parbreak = isBreak(cursor),
               NSMaxRange(parbreak) <= range.location
            {
                lower = NSMaxRange(parbreak)
                break
            }
        }
        var upper = source.length
        cursor = NSMaxRange(range)
        while cursor < source.length {
            if source.character(at: cursor) == 0x0A, let parbreak = isBreak(cursor),
               parbreak.location >= NSMaxRange(range)
            {
                upper = parbreak.location
                break
            }
            cursor += 1
        }
        return NSRange(location: lower, length: upper - lower)
    }
}
