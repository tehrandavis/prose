import Foundation

/// The comment index of one open file, kept off the main thread (Phase 8
/// decision 9). A syntax tree's edit costs about 2 ms on a book, too much
/// for a keystroke on the main thread, so this actor owns its own text and
/// tree, as the spelling and styling actors do. The editor sends each
/// native edit in order and never waits; each reply describes the text
/// after every edit sent with it.
public actor CommentIndexSource {
    /// What the editor needs from the index for one text.
    public struct Snapshot: Sendable {
        public let index: CommentIndex
        /// Every attached comment's markers and anchor, in document order.
        public let anchors: [CommentIndex.Anchor]
        /// The store (`CommentEdits.storeRange`).
        public let store: NSRange?

        public init(index: CommentIndex, source: NSString) {
            self.index = index
            anchors = index.anchors
            store = CommentEdits.storeRange(index: index, source: source)
        }
    }

    private let text = NSMutableString()
    private var tree: SyntaxTree?
    private var index = CommentIndex()
    /// Full builds made, for tests: one on open, then one per failed update.
    public private(set) var builds = 0

    public init() {}

    /// Builds the index of `source` from scratch.
    public func open(_ source: String) -> Snapshot {
        text.setString(source)
        rebuild()
        return Snapshot(index: index, source: text)
    }

    /// Applies `edits` in order: each replaces a range of the text before it.
    /// Returns nil when an edit does not fit the text held; open the
    /// editor's text again then.
    public func update(_ edits: [TextReplacement]) -> Snapshot? {
        var fresh = false
        for edit in edits {
            guard edit.range.location >= 0, edit.range.length >= 0, NSMaxRange(edit.range) <= text.length else {
                return nil
            }
            text.replaceCharacters(in: edit.range, with: edit.text)
            guard !fresh, let tree, let reparsed = tree.edit(edit.range, replacement: edit.text) else {
                fresh = true
                continue
            }
            let updated = index.update(
                replacing: edit.range,
                length: (edit.text as NSString).length,
                reparsed: reparsed,
                tree: tree,
                source: text,
            )
            if !updated {
                fresh = true
            }
        }
        if fresh {
            rebuild()
        }
        return Snapshot(index: index, source: text)
    }

    private func rebuild() {
        builds += 1
        tree = SyntaxTree(text as String)
        index = tree.flatMap { CommentIndex(source: text, tree: $0) } ?? CommentIndex()
    }
}
