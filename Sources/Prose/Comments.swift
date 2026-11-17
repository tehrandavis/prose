import AppKit
import ProseCore

/// How strongly a comment's anchor is filled (Phase 8 decision 6). The
/// active comment and a draft draw `active`.
enum CommentHighlightStrength: Int, Comparable {
    case normal
    case active

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: NSColor {
        switch self {
        case .normal: Theme.commentHighlight
        case .active: Theme.activeCommentHighlight
        }
    }
}

/// One anchor to fill, in today's text.
struct CommentHighlight: Equatable {
    let id: String
    let range: NSRange
    let strength: CommentHighlightStrength
}

/// A new comment before it is posted (decision 7): its range in today's
/// text, which follows edits.
struct CommentDraft: Equatable {
    /// The id the draft's card and highlight use; never a valid comment id.
    static let id = "draft"
    var range: NSRange
}

/// An attached comment where it is in today's text: its markers move with
/// every edit until the next index arrives.
struct PlacedComment: Equatable {
    let id: String
    var start: NSRange
    var end: NSRange
    /// Whitespace between the start marker and the anchor, and between the
    /// anchor and the end marker.
    let lead: Int
    let trail: Int
    let isResolved: Bool

    init(_ anchor: CommentIndex.Anchor) {
        id = anchor.id
        start = anchor.startMarker
        end = anchor.endMarker
        lead = anchor.range.location - NSMaxRange(anchor.startMarker)
        trail = max(0, anchor.endMarker.location - NSMaxRange(anchor.range))
        isResolved = anchor.isResolved
    }

    /// The anchor: the text between the markers, without the whitespace at
    /// its edges the index last saw.
    var anchor: NSRange {
        let lower = NSMaxRange(start) + lead
        return NSRange(location: lower, length: max(0, end.location - trail - lower))
    }

    /// A marker after one native edit, or nil when the edit touched it.
    static func moved(_ marker: NSRange, editing edit: NSRange, delta: Int) -> NSRange? {
        if NSMaxRange(edit) <= marker.location {
            return NSRange(location: marker.location + delta, length: marker.length)
        }
        return edit.location >= NSMaxRange(marker) ? marker : nil
    }
}

/// The comment index of the editor's text (Phase 8 decision 9), and what
/// the editor draws from it: the highlight of every attached comment that
/// is not resolved, the store's fold and the count in the status bar.
///
/// The index lives in `CommentIndexSource`, off the main thread: a syntax
/// tree's edit costs about 2 ms on a book. The editor sends every native
/// edit in order and never waits. Until a reply arrives, the markers and
/// anchors move with each edit here, at the cost of a pass over the
/// attached comments. A reply that arrives while text is marked is applied
/// to the views once the composition ends.
@MainActor
final class CommentController {
    private weak var editor: ManuscriptTextView?
    private let source = CommentIndexSource()
    private var generation = 0
    private var inFlight = false
    /// Edits not sent yet, and every edit made since the text `snapshot`
    /// describes.
    private var queue: [TextReplacement] = []
    private var unapplied: [TextReplacement] = []
    private(set) var snapshot: CommentIndexSource.Snapshot?
    /// Attached comments in today's text, in document order.
    private(set) var placed: [PlacedComment] = []
    /// The store in today's text.
    private(set) var store: NSRange?
    private var cachedComments: [CommentIndex.Comment]?
    private(set) var viewsWait = false
    /// What the views last drew, so a reply that changes nothing draws nothing.
    private var drawn: (highlights: [CommentHighlight], underlines: [NSRange], store: NSRange?, hidden: Int)?
    /// For tests: replies applied to the views.
    private(set) var viewUpdates = 0
    /// The active comment (decision 7): the one whose card was clicked, or
    /// whose anchor holds the caret. `CommentDraft.id` while a draft is open.
    private(set) var activeID: String?
    /// A new comment before it is posted: its range follows edits, and
    /// nothing is in the source yet.
    private(set) var draft: CommentDraft?
    /// Show Comments and Show Resolved Comments (decision 7).
    var showsComments = true {
        didSet {
            if showsComments != oldValue {
                applyToViews()
            }
        }
    }

    var showsResolved = false {
        didSet {
            if showsResolved != oldValue {
                applyToViews()
            }
        }
    }

    /// The comments as the last current index gave them, by id, for the
    /// cards while an index is on its way.
    private(set) var lastComments: [String: CommentIndex.Comment] = [:]

    init(editor: ManuscriptTextView) {
        self.editor = editor
    }

    /// Whether the index describes today's text.
    var isCurrent: Bool {
        snapshot != nil && unapplied.isEmpty
    }

    /// Every comment with a first entry, in document order, while the index
    /// is current; built once per index.
    var comments: [CommentIndex.Comment] {
        guard isCurrent, let snapshot else {
            return []
        }
        if let cachedComments {
            return cachedComments
        }
        let comments = snapshot.index.comments
        cachedComments = comments
        lastComments = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return comments
    }

    // MARK: - Input from the editor

    /// The text was replaced (a file opened, switched or changed on disk):
    /// the index is built again from scratch, off the main thread.
    func open(_ text: String) {
        generation += 1
        inFlight = true
        queue = []
        unapplied = []
        snapshot = nil
        cachedComments = nil
        placed = []
        store = nil
        lastComments = [:]
        draft = nil
        activeID = nil
        applyToViews()
        let generation = generation
        Task {
            let fresh = await source.open(text)
            receive(fresh, covering: 0, generation: generation)
        }
    }

    /// One native edit: `range` in the text before it became `text`.
    func textDidChange(replacing range: NSRange, with text: String) {
        guard snapshot != nil || inFlight else {
            return
        }
        let edit = TextReplacement(range: range, text: text)
        queue.append(edit)
        unapplied.append(edit)
        cachedComments = nil
        move(through: edit)
        // The draft is in today's text only: it moves once per edit.
        if let range = draft?.range {
            let delta = (text as NSString).length - edit.range.length
            draft?.range = SourceStyling.rebase(range, editing: edit.range, delta: delta)
        }
        send()
    }

    /// A composition ended: an index that arrived during it is drawn now.
    func compositionEnded() {
        if viewsWait {
            applyToViews()
        }
    }

    private func move(through edit: TextReplacement) {
        let delta = (edit.text as NSString).length - edit.range.length
        // In place: a keystroke costs one pass over the attached comments.
        var touched = false
        for position in placed.indices {
            if let start = PlacedComment.moved(placed[position].start, editing: edit.range, delta: delta),
               let end = PlacedComment.moved(placed[position].end, editing: edit.range, delta: delta)
            {
                placed[position].start = start
                placed[position].end = end
            } else {
                placed[position].start.length = 0
                touched = true
            }
        }
        if touched {
            placed.removeAll { $0.start.length == 0 }
        }
        store = store.flatMap { CommentEdits.rebaseStore($0, editing: edit.range, delta: delta) }
    }

    private func send() {
        guard !inFlight, !queue.isEmpty else {
            return
        }
        inFlight = true
        let edits = queue, generation = generation
        queue = []
        Task {
            let fresh = await source.update(edits)
            guard generation == self.generation else {
                return
            }
            guard let fresh else {
                // The actor lost step with the editor: start again from its text.
                if let editor {
                    open(editor.string)
                }
                return
            }
            receive(fresh, covering: edits.count, generation: generation)
        }
    }

    private func receive(_ fresh: CommentIndexSource.Snapshot, covering count: Int, generation: Int) {
        guard generation == self.generation else {
            return
        }
        inFlight = false
        unapplied.removeFirst(min(count, unapplied.count))
        snapshot = fresh
        cachedComments = nil
        placed = fresh.anchors.map(PlacedComment.init)
        store = fresh.store
        for edit in unapplied {
            move(through: edit)
        }
        if let editor, editor.hasMarkedText() {
            viewsWait = true
        } else {
            applyToViews()
        }
        send()
    }

    // MARK: - What the views draw

    /// The anchors to fill, sorted by location: every attached comment that
    /// is not resolved and whose anchor holds text, the active one stronger,
    /// and the draft's range; none while comments are hidden.
    var highlights: [CommentHighlight] {
        guard showsComments else {
            return []
        }
        var highlights = placed.compactMap { comment -> CommentHighlight? in
            let anchor = comment.anchor
            guard !comment.isResolved, anchor.length > 0 else {
                return nil
            }
            return CommentHighlight(
                id: comment.id,
                range: anchor,
                strength: comment.id == activeID ? .active : .normal,
            )
        }
        if let draft, draft.range.length > 0 {
            highlights.append(CommentHighlight(id: CommentDraft.id, range: draft.range, strength: .active))
        }
        return highlights.sorted { $0.range.location < $1.range.location }
    }

    /// The anchors of resolved comments while they are shown: a 1 pt
    /// underline in the secondary text colour, no fill (decision 6).
    var resolvedUnderlines: [NSRange] {
        guard showsComments, showsResolved else {
            return []
        }
        return placed.compactMap { $0.isResolved && $0.anchor.length > 0 ? $0.anchor : nil }
    }

    /// Whether comment `id` is shown: comments are shown, and it is not
    /// resolved or resolved comments are shown.
    func isShown(_ comment: CommentIndex.Comment) -> Bool {
        showsComments && (!comment.isResolved || showsResolved)
    }

    // MARK: - The active comment and the draft (decision 7)

    /// Makes `id` the active comment; nil for none.
    func setActive(_ id: String?) {
        guard id != activeID else {
            return
        }
        activeID = id
        applyToViews()
    }

    /// The selection changed: the comment whose anchor holds it becomes
    /// active, the innermost when anchors nest; with none there, no comment
    /// is active. A draft stays active until it is posted or cancelled.
    func selectionDidChange(_ selection: NSRange) {
        guard draft == nil else {
            return
        }
        setActive(innermost(holding: selection)?.id)
    }

    /// The attached comment whose anchor holds `selection`, the shortest
    /// when anchors nest. Hidden comments are never found.
    func innermost(holding selection: NSRange) -> PlacedComment? {
        guard showsComments else {
            return nil
        }
        return placed.filter { comment in
            let anchor = comment.anchor
            return (showsResolved || !comment.isResolved) && anchor.location <= selection.location &&
                NSMaxRange(selection) <= NSMaxRange(anchor)
        }.min { $0.anchor.length < $1.anchor.length }
    }

    /// Opens a draft at `range` and makes it active.
    func openDraft(_ range: NSRange) {
        draft = CommentDraft(range: range)
        activeID = CommentDraft.id
        applyToViews()
    }

    /// Ends the draft, posted or cancelled; `active` is the comment to make
    /// active after it.
    func closeDraft(active: String? = nil) {
        guard draft != nil else {
            return
        }
        draft = nil
        activeID = active
        applyToViews()
    }

    /// The anchors to fill that share characters with `range`.
    func highlights(intersecting range: NSRange) -> [CommentHighlight] {
        highlights.filter { NSIntersectionRange($0.range, range).length > 0 }
    }

    /// `highlights` as disjoint runs, each in the strongest colour of the
    /// anchors over it, for the source's rendering attributes.
    static func runs(_ highlights: [CommentHighlight]) -> [(range: NSRange, color: PlatformColor)] {
        var edges = Set<Int>()
        for highlight in highlights {
            edges.insert(highlight.range.location)
            edges.insert(NSMaxRange(highlight.range))
        }
        let points = edges.sorted()
        var runs: [(range: NSRange, strength: CommentHighlightStrength)] = []
        for (lower, upper) in zip(points, points.dropFirst()) {
            let strongest = highlights.filter { $0.range.location <= lower && NSMaxRange($0.range) >= upper }
                .map(\.strength).max()
            guard let strongest else {
                continue
            }
            if let last = runs.last, NSMaxRange(last.range) == lower, last.strength == strongest {
                runs[runs.count - 1].range.length += upper - lower
            } else {
                runs.append((NSRange(location: lower, length: upper - lower), strongest))
            }
        }
        return runs.map { ($0.range, $0.strength.color) }
    }

    private func applyToViews() {
        viewsWait = false
        guard let editor else {
            return
        }
        let highlights = highlights, underlines = resolvedUnderlines
        let hidden = snapshot?.index.hiddenCharacterCount ?? 0
        let changed = drawn.map {
            $0.highlights != highlights || $0.underlines != underlines || $0.store != store || $0.hidden != hidden
        } ?? true
        defer { editor.commentOverlay?.setNeedsRefresh() }
        if changed {
            if drawn.map({ $0.underlines != underlines }) ?? !underlines.isEmpty {
                editor.setNeedsDisplay(editor.visibleRect)
            }
            drawn = (highlights, underlines, store, hidden)
            viewUpdates += 1
            if let colors = editor.styler?.colors {
                colors.setBackgrounds(Self.runs(highlights))
                colors.commit()
            }
            editor.writing.model?.setCommentStore(store)
            if let workspace = editor.workspace, workspace.commentHiddenCharacters != hidden {
                workspace.commentHiddenCharacters = hidden
            }
            editor.writing.commentHighlightsChanged()
        }
    }

    // MARK: - The writer's edits (decision 4)

    /// Whether an edit of `range` touches a marker of an attached comment,
    /// as far as the markers in today's text are known.
    func mayTouchMarker(_ range: NSRange) -> Bool {
        func touches(_ marker: NSRange) -> Bool {
            range.length > 0 ? marker.location < NSMaxRange(range) && range.location < NSMaxRange(marker) :
                marker.location < range.location && range.location < NSMaxRange(marker)
        }
        return placed.contains { touches($0.start) || touches($0.end) }
    }

    /// The index of `text`, today's text: the reply's when it is current,
    /// else one built here from a fresh parse (about 50 ms on a book; only
    /// for an edit that touches a marker before the reply arrived).
    func index(of text: NSString) -> CommentIndex? {
        if isCurrent, let snapshot {
            return snapshot.index
        }
        return SyntaxTree(text as String).flatMap { CommentIndex(source: text, tree: $0) }
    }
}
