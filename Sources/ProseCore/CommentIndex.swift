import Foundation

/// The comments of one file (Phase 8 note, decisions 3 and 9), read from the
/// syntax tree's comment nodes and the source.
///
/// A block comment of exactly 11 characters is tested against the start
/// marker and end marker forms. A line comment is a record only when it is
/// at the top level of the file and starts a line. Everything else is a
/// source comment. Ranges are UTF-16 (`NSRange`) in the source.
///
/// The index keeps the parts it read (markers, records, headers, unreadable
/// lines, markers that never close) in source order, and derives the
/// comments and problems from them. `update` reads again only the parts the
/// edit touched and moves the later ones, and gives the same index as a full
/// build of the new text.
public struct CommentIndex: Equatable, Sendable {
    /// One entry of a comment: the first entry or a reply. A resolve event is
    /// an entry with no text.
    public struct Entry: Equatable, Sendable {
        public let kind: CommentSyntax.RecordKind
        public let author: String
        /// UTC, ISO 8601, to the second.
        public let date: String
        public let text: String
        /// The record's line comment, without its line break.
        public let range: NSRange
    }

    public enum State: Equatable, Sendable {
        /// One start marker before one end marker, and one first entry.
        case attached
        /// One first entry and only one of the two markers, or the end
        /// marker before the start marker: "The marked text is damaged".
        case damaged
        /// One first entry and no marker: "Not attached".
        case notAttached
        /// Two start markers, two end markers or two first entries.
        case usedMoreThanOnce
    }

    public struct Comment: Equatable, Sendable {
        public let id: String
        public let state: State
        /// The start marker, when the id has exactly one.
        public let startMarker: NSRange?
        /// The end marker, when the id has exactly one.
        public let endMarker: NSRange?
        /// The text between the two markers, without whitespace at its edges;
        /// nil unless the comment is attached. Empty when no text is left.
        public let anchor: NSRange?
        /// The first entry, then the replies in date order. For an id used
        /// more than once, every first entry comes before the replies.
        public let entries: [Entry]
        /// The resolve events, in source order.
        public let resolutions: [Entry]

        public var isResolved: Bool {
            !resolutions.isEmpty
        }

        public var replies: [Entry] {
            entries.filter { $0.kind == .reply }
        }

        /// Where the comment is in the document: its start marker, else its
        /// end marker, else its first entry.
        public var location: Int {
            startMarker?.location ?? endMarker?.location ?? entries.first?.range.location ?? 0
        }
    }

    public enum ProblemKind: Equatable, Sendable {
        /// Markers whose id has no first entry. Action: Remove Markers.
        case markersWithNoComment
        /// One copy of an id's start marker, end marker or first entry.
        /// Actions: Give a New Id, Remove.
        case usedMoreThanOnce
        /// A line that starts `// prose:` and does not parse.
        case unreadableLine
        /// A reply or resolve record whose id has no first entry. Action: Remove.
        case replyWithNoComment
        /// A header with a version above 1. Every comment action is unavailable.
        case newerFormat(version: Int)
        /// A start marker or end marker that never closes, so the rest of
        /// the file is a comment. The range is its first nine characters.
        case notClosed
    }

    public struct Problem: Equatable, Sendable {
        public let kind: ProblemKind
        public let id: String?
        public let ranges: [NSRange]
    }

    enum PartKind: Equatable, Sendable {
        case marker(CommentSyntax.MarkerKind, String)
        case record(CommentSyntax.Record)
        case header(Int)
        case unreadable
        case notClosed(CommentSyntax.MarkerKind, String)
    }

    /// One comment node that matters to the index. `range` is the whole node.
    struct Part: Equatable, Sendable {
        var range: NSRange
        let kind: PartKind
        /// Characters that are not whitespace, for the word count.
        let hidden: Int

        var id: String? {
            switch kind {
            case let .marker(_, id), let .notClosed(_, id): id
            case let .record(record): record.id
            case .header, .unreadable: nil
            }
        }

        var record: CommentSyntax.Record? {
            if case let .record(record) = kind {
                return record
            }
            return nil
        }

        var isLine: Bool {
            switch kind {
            case .record, .header, .unreadable: true
            case .marker, .notClosed: false
            }
        }
    }

    /// One comment as the index keeps it: positions in `parts`, so an edit
    /// that only moves text moves nothing here.
    struct Stored: Equatable, Sendable {
        let id: String
        let state: State
        let start: Int?
        let end: Int?
        /// The first entries, then the replies in date order.
        let entries: [Int]
        let resolutions: [Int]
        /// Whitespace at the anchor's two edges; nil when only whitespace
        /// is between the markers.
        var inset: (lead: Int, trail: Int)?

        static func == (lhs: Stored, rhs: Stored) -> Bool {
            lhs.id == rhs.id && lhs.state == rhs.state && lhs.start == rhs.start && lhs.end == rhs.end &&
                lhs.entries == rhs.entries && lhs.resolutions == rhs.resolutions &&
                lhs.inset?.lead == rhs.inset?.lead && lhs.inset?.trail == rhs.inset?.trail
        }
    }

    struct StoredProblem: Equatable, Sendable {
        let kind: ProblemKind
        let id: String?
        let parts: [Int]
    }

    /// The parts, in source order, as two parallel lists, so an edit moves
    /// plain ranges.
    private var storedRanges: [NSRange] = []
    private var kinds: [PartKind] = []
    private var visibleCounts: [Int] = []
    /// A move not yet written into `storedRanges`: the parts from
    /// `shiftStart` on are `shiftDelta` later than stored. Typing in one
    /// place grows the delta and writes nothing, so a keystroke costs no
    /// pass over the later parts.
    private var shiftStart = Int.max
    private var shiftDelta = 0

    /// The range of part `index`.
    private func partRange(_ index: Int) -> NSRange {
        let stored = storedRanges[index]
        return index >= shiftStart ? NSRange(location: stored.location + shiftDelta, length: stored.length) : stored
    }

    /// Moves the parts from `index` on by `delta`, writing as few stored
    /// ranges as it can.
    private mutating func shift(from index: Int, by delta: Int) {
        guard delta != 0, index < storedRanges.count else {
            return
        }
        guard shiftDelta != 0 else {
            (shiftStart, shiftDelta) = (index, delta)
            return
        }
        let (lower, upper, written) = index > shiftStart ? (shiftStart, index, shiftDelta) :
            (index, shiftStart, delta)
        storedRanges.withUnsafeMutableBufferPointer { buffer in
            for position in lower ..< upper {
                buffer[position].location += written
            }
        }
        shiftStart = max(shiftStart, index)
        shiftDelta += delta
    }

    /// Writes the pending move into `storedRanges`.
    private mutating func flushShift() {
        if shiftDelta != 0 {
            let (start, delta) = (shiftStart, shiftDelta)
            storedRanges.withUnsafeMutableBufferPointer { buffer in
                for position in start ..< buffer.count {
                    buffer[position].location += delta
                }
            }
        }
        (shiftStart, shiftDelta) = (Int.max, 0)
    }

    /// The parts, in source order.
    var parts: [Part] {
        kinds.indices.map { Part(range: partRange($0), kind: kinds[$0], hidden: visibleCounts[$0]) }
    }

    private mutating func setParts(_ parts: [Part]) {
        (shiftStart, shiftDelta) = (Int.max, 0)
        storedRanges = parts.map(\.range)
        kinds = parts.map(\.kind)
        visibleCounts = parts.map(\.hidden)
    }

    /// The comments with a first entry, in document order.
    private var stored: [Stored] = []
    private var positions: [String: Int] = [:]
    /// The start and end marker parts of each attached comment of `stored`,
    /// two numbers per comment, -1 for the others. Plain numbers, so an
    /// edit reads them cheaply.
    private var anchorParts: [Int] = []
    private var storedProblems: [StoredProblem] = []
    /// Characters that are not whitespace in all start markers, end markers,
    /// headers and records. The status bar's count leaves them out.
    public private(set) var hiddenCharacterCount = 0
    /// The newest format version a header names. Above 1, Prose makes every
    /// comment action unavailable in the file.
    public private(set) var formatVersion = CommentSyntax.formatVersion

    /// Every comment with a first entry, in document order. It is built on
    /// each call, in time linear in the number of comments; use
    /// `comment(_:)` for one.
    public var comments: [Comment] {
        stored.map(comment)
    }

    /// The number of comments with a first entry.
    public var commentCount: Int {
        stored.count
    }

    /// Where an attached comment is: its two markers and its anchor.
    public struct Anchor: Equatable, Sendable {
        public let id: String
        public let startMarker: NSRange
        public let endMarker: NSRange
        /// The text between the two markers, without whitespace at its edges.
        public let range: NSRange
        public let isResolved: Bool

        public init(id: String, startMarker: NSRange, endMarker: NSRange, range: NSRange, isResolved: Bool) {
            self.id = id
            self.startMarker = startMarker
            self.endMarker = endMarker
            self.range = range
            self.isResolved = isResolved
        }
    }

    /// Every attached comment's markers and anchor, in document order. It
    /// reads no record, so it costs much less than `comments`.
    public var anchors: [Anchor] {
        stored.compactMap { comment in
            guard comment.state == .attached, let startPart = comment.start, let endPart = comment.end else {
                return nil
            }
            let start = partRange(startPart), end = partRange(endPart)
            let lower = NSMaxRange(start) + (comment.inset?.lead ?? 0)
            let upper = comment.inset.map { end.location - $0.trail } ?? lower
            return Anchor(
                id: comment.id,
                startMarker: start,
                endMarker: end,
                range: NSRange(location: lower, length: max(0, upper - lower)),
                isResolved: !comment.resolutions.isEmpty,
            )
        }
    }

    /// Every problem, in source order.
    public var problems: [Problem] {
        storedProblems.map { problem in
            Problem(kind: problem.kind, id: problem.id, ranges: problem.parts.map { part in
                problem.kind == .notClosed ? NSRange(location: partRange(part).location, length: 9) : partRange(part)
            })
        }
    }

    public static func == (lhs: CommentIndex, rhs: CommentIndex) -> Bool {
        lhs.parts == rhs.parts && lhs.stored == rhs.stored && lhs.storedProblems == rhs.storedProblems &&
            lhs.hiddenCharacterCount == rhs.hiddenCharacterCount && lhs.formatVersion == rhs.formatVersion
    }

    /// Whether a newer Prose wrote this file's comments.
    public var isReadOnly: Bool {
        formatVersion > CommentSyntax.formatVersion
    }

    /// Every id that a marker or record of the file uses.
    public var ids: Set<String> {
        Set(kinds.compactMap { Part(range: NSRange(), kind: $0, hidden: 0).id })
    }

    /// The comment with `id`, if it has a first entry.
    public func comment(_ id: String) -> Comment? {
        positions[id].map { comment(stored[$0]) }
    }

    private func comment(_ comment: Stored) -> Comment {
        func entry(_ position: Int) -> Entry {
            guard case let .record(record) = kinds[position] else {
                return Entry(kind: .comment, author: "", date: "", text: "", range: partRange(position))
            }
            return Entry(
                kind: record.kind,
                author: record.author,
                date: record.date,
                text: record.text,
                range: partRange(position),
            )
        }
        let start = comment.start.map { partRange($0) }
        let end = comment.end.map { partRange($0) }
        var anchor: NSRange?
        if comment.state == .attached, let start, let end {
            if let inset = comment.inset {
                let lower = NSMaxRange(start) + inset.lead
                anchor = NSRange(location: lower, length: end.location - inset.trail - lower)
            } else {
                anchor = NSRange(location: NSMaxRange(start), length: 0)
            }
        }
        return Comment(
            id: comment.id,
            state: comment.state,
            startMarker: start,
            endMarker: end,
            anchor: anchor,
            entries: comment.entries.map(entry),
            resolutions: comment.resolutions.map(entry),
        )
    }

    public init() {}

    /// The index of `source` from `nodes`, a pre-order list of the whole
    /// tree as `SyntaxTree.nodes()` returns it.
    public init(source: NSString, nodes: [SyntaxNode]) {
        setParts(Self.parts(nodes, source: source, within: nil))
        derive(source: source)
    }

    /// The index of the text `tree` mirrors; nil after a failed edit.
    public init?(source: NSString, tree: SyntaxTree) {
        guard let nodes = tree.nodes() else {
            return nil
        }
        self.init(source: source, nodes: nodes)
    }

    /// Brings the index up to date after one replacement. `range` is the
    /// replaced range in the old text, `replacementLength` the UTF-16 length
    /// of the new text, `reparsed` what `SyntaxTree.edit` returned, and
    /// `tree` and `source` are already edited. Returns false, and leaves the
    /// index as it was, when the tree has no nodes (after a failed edit);
    /// build the index again then.
    @discardableResult
    public mutating func update(
        replacing range: NSRange,
        length replacementLength: Int,
        reparsed: NSRange,
        tree: SyntaxTree,
        source: NSString,
    ) -> Bool {
        let delta = replacementLength - range.length
        let edited = NSRange(location: range.location, length: replacementLength)
        // One character more on each side: whether a line comment starts a
        // line depends on the character before it.
        let union = NSUnionRange(edited, reparsed)
        let first = max(0, union.location - 1)
        let last = min(source.length, NSMaxRange(union) + 1)
        let window = NSRange(location: first, length: max(0, last - first))
        guard let nodes = tree.nodes(in: window) else {
            return false
        }
        let oldWindow = NSRange(location: window.location, length: window.length - delta)
        // The parts overlapping the old window are one run, since parts are
        // sorted and never overlap.
        let lower = firstPart { NSMaxRange(partRange($0)) > oldWindow.location }
        var end = lower
        while end < kinds.count, partRange(end).location < NSMaxRange(oldWindow) {
            end += 1
        }
        let fresh = Self.parts(nodes, source: source, within: window)
        let editEnd = NSMaxRange(range)
        // Whether the parts read again are the parts dropped, moved by the
        // edit: then no comment changed but its offsets.
        let moved = end - lower == fresh.count && fresh.indices.allSatisfy { offset in
            kinds[lower + offset] == fresh[offset].kind &&
                Self.shifted(partRange(lower + offset), after: editEnd, by: delta) == fresh[offset].range
        }
        guard moved else {
            flushShift()
            storedRanges.replaceSubrange(lower ..< end, with: fresh.map(\.range))
            kinds.replaceSubrange(lower ..< end, with: fresh.map(\.kind))
            visibleCounts.replaceSubrange(lower ..< end, with: fresh.map(\.hidden))
            shift(from: lower + fresh.count, by: delta)
            derive(source: source)
            return true
        }
        // The same parts in the same places: move the later ones, write the
        // new ranges of the parts read again, and trim again the anchors
        // the edit is inside.
        let before = firstPart { partRange($0).location >= range.location }
        shift(from: lower + fresh.count, by: delta)
        for (offset, part) in fresh.enumerated() {
            let position = lower + offset
            storedRanges[position] = position >= shiftStart ?
                NSRange(location: part.range.location - shiftDelta, length: part.range.length) : part.range
        }
        let around = anchorParts.withUnsafeBufferPointer { pairs in
            (0 ..< pairs.count / 2).filter { position in
                let start = pairs[2 * position], end = pairs[2 * position + 1]
                return start >= 0 && start < before && end >= before
            }
        }
        for position in around {
            let start = partRange(anchorParts[2 * position]), end = partRange(anchorParts[2 * position + 1])
            stored[position].inset = Self.inset(
                NSRange(location: NSMaxRange(start), length: end.location - NSMaxRange(start)),
                in: source,
            )
        }
        return true
    }

    /// The first part for which `test` holds; `test` must be false and then
    /// true along the parts.
    private func firstPart(where test: (Int) -> Bool) -> Int {
        var lower = 0, upper = kinds.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if test(middle) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }

    private static func shifted(_ range: NSRange, after offset: Int, by delta: Int) -> NSRange {
        range.location >= offset ? NSRange(location: range.location + delta, length: range.length) : range
    }

    private static func overlaps(_ range: NSRange, _ window: NSRange) -> Bool {
        range.location < NSMaxRange(window) && NSMaxRange(range) > window.location
    }

    /// The parts read from `nodes`, in source order; only those overlapping
    /// `window` when one is given.
    private static func parts(_ nodes: [SyntaxNode], source: NSString, within window: NSRange?) -> [Part] {
        var parts: [Part] = []
        for node in nodes where node.kind == .blockComment || node.kind == .lineComment {
            if let window, !overlaps(node.range, window) {
                continue
            }
            if node.kind == .blockComment {
                if let marker = CommentSyntax.marker(in: source, at: node.range) {
                    parts.append(Part(
                        range: node.range,
                        kind: .marker(marker.kind, marker.id),
                        hidden: CommentSyntax.markerLength,
                    ))
                } else if NSMaxRange(node.range) == source.length,
                          let marker = CommentSyntax.markerPrefix(in: source, at: node.range.location),
                          !closes(source, node.range)
                {
                    parts.append(Part(range: node.range, kind: .notClosed(marker.kind, marker.id), hidden: 0))
                }
                continue
            }
            guard node.depth == 1, startsLine(source, node.range.location) else {
                continue
            }
            let text = source.substring(with: node.range)
            switch CommentSyntax.parseLine(text) {
            case nil:
                continue
            case .unreadable:
                parts.append(Part(range: node.range, kind: .unreadable, hidden: 0))
            case let .header(version):
                parts.append(Part(range: node.range, kind: .header(version), hidden: visible(text)))
            case let .record(record):
                parts.append(Part(range: node.range, kind: .record(record), hidden: visible(text)))
            }
        }
        return parts
    }

    /// Whether a block comment at `range` closes, by Typst's rule: block
    /// comments nest.
    private static func closes(_ source: NSString, _ range: NSRange) -> Bool {
        var depth = 0, previous: unichar = 0
        for offset in range.location ..< NSMaxRange(range) {
            let unit = source.character(at: offset)
            if previous == 0x2F, unit == 0x2A { // /*
                depth += 1
                previous = 0
            } else if previous == 0x2A, unit == 0x2F { // */
                depth -= 1
                previous = 0
                if depth == 0 {
                    return true
                }
            } else {
                previous = unit
            }
        }
        return false
    }

    static func startsLine(_ source: NSString, _ location: Int) -> Bool {
        location == 0 || CommentSyntax.isNewline(unit: source.character(at: location - 1))
    }

    private static func visible(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
    }

    // MARK: Comments and problems

    private struct Group {
        var starts: [Int] = []
        var ends: [Int] = []
        var firsts: [Int] = []
        var replies: [Int] = []
        var resolutions: [Int] = []
    }

    private mutating func derive(source: NSString) {
        flushShift()
        var groups: [String: Group] = [:]
        var problems: [StoredProblem] = []
        var hidden = 0, version = CommentSyntax.formatVersion
        for position in kinds.indices {
            hidden += visibleCounts[position]
            switch kinds[position] {
            case let .marker(kind, id):
                if kind == .start {
                    groups[id, default: Group()].starts.append(position)
                } else {
                    groups[id, default: Group()].ends.append(position)
                }
            case let .record(record):
                switch record.kind {
                case .comment: groups[record.id, default: Group()].firsts.append(position)
                case .reply: groups[record.id, default: Group()].replies.append(position)
                case .resolve: groups[record.id, default: Group()].resolutions.append(position)
                }
            case let .header(headerVersion):
                if headerVersion > CommentSyntax.formatVersion {
                    problems.append(StoredProblem(
                        kind: .newerFormat(version: headerVersion),
                        id: nil,
                        parts: [position],
                    ))
                }
                version = max(version, headerVersion)
            case .unreadable:
                problems.append(StoredProblem(kind: .unreadableLine, id: nil, parts: [position]))
            case let .notClosed(_, id):
                problems.append(StoredProblem(kind: .notClosed, id: id, parts: [position]))
            }
        }
        var comments: [Stored] = []
        for (id, group) in groups {
            guard !group.firsts.isEmpty else {
                let markers = (group.starts + group.ends).sorted()
                if !markers.isEmpty {
                    problems.append(StoredProblem(kind: .markersWithNoComment, id: id, parts: markers))
                }
                for record in (group.replies + group.resolutions).sorted() {
                    problems.append(StoredProblem(kind: .replyWithNoComment, id: id, parts: [record]))
                }
                continue
            }
            let replies = group.replies.sorted {
                let left = Self.date(kinds[$0]), right = Self.date(kinds[$1])
                return left != right ? left < right : $0 < $1
            }
            let duplicated = group.starts.count > 1 || group.ends.count > 1 || group.firsts.count > 1
            if duplicated {
                for copies in [group.starts, group.ends, group.firsts] where copies.count > 1 {
                    for copy in copies {
                        problems.append(StoredProblem(kind: .usedMoreThanOnce, id: id, parts: [copy]))
                    }
                }
            }
            let start = group.starts.count == 1 ? group.starts.first : nil
            let end = group.ends.count == 1 ? group.ends.first : nil
            let state: State
            var inset: (lead: Int, trail: Int)?
            if duplicated {
                state = .usedMoreThanOnce
            } else if let start, let end, NSMaxRange(storedRanges[start]) <= storedRanges[end].location {
                state = .attached
                let lower = NSMaxRange(storedRanges[start])
                inset = Self.inset(NSRange(location: lower, length: storedRanges[end].location - lower), in: source)
            } else if start == nil, end == nil {
                state = .notAttached
            } else {
                state = .damaged
            }
            comments.append(Stored(
                id: id,
                state: state,
                start: start,
                end: end,
                entries: group.firsts + replies,
                resolutions: group.resolutions,
                inset: inset,
            ))
        }
        // Document order: the start marker, else the end marker, else the first entry.
        comments.sort { left, right in
            let one = left.start ?? left.end ?? left.entries[0], two = right.start ?? right.end ?? right.entries[0]
            return one != two ? one < two : left.id < right.id
        }
        problems.sort { ($0.parts.first ?? 0) < ($1.parts.first ?? 0) }
        stored = comments
        positions = Dictionary(uniqueKeysWithValues: comments.enumerated().map { ($1.id, $0) })
        anchorParts = comments.flatMap { comment in
            comment.state == .attached ? [comment.start ?? -1, comment.end ?? -1] : [-1, -1]
        }
        storedProblems = problems
        hiddenCharacterCount = hidden
        formatVersion = version
    }

    private static func date(_ kind: PartKind) -> String {
        if case let .record(record) = kind {
            return record.date
        }
        return ""
    }

    /// The whitespace at the two edges of `range`; nil when it is all
    /// whitespace.
    static func inset(_ range: NSRange, in source: NSString) -> (lead: Int, trail: Int)? {
        let trimmed = trimmed(range, in: source)
        guard trimmed.length > 0 else {
            return nil
        }
        return (trimmed.location - range.location, NSMaxRange(range) - NSMaxRange(trimmed))
    }

    /// `range` without whitespace at its edges; empty, at its start, when
    /// nothing else is left.
    static func trimmed(_ range: NSRange, in source: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, isSpace(source.character(at: start)) {
            start += 1
        }
        while end > start, isSpace(source.character(at: end - 1)) {
            end -= 1
        }
        return start == end ? NSRange(location: range.location, length: 0) :
            NSRange(location: start, length: end - start)
    }

    static func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return scalar.properties.isWhitespace || CommentSyntax.isNewline(scalar)
    }
}
