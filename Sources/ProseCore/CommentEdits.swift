import Foundation

/// The replacements each comment action makes (Phase 8 note, decisions 1, 3,
/// 4 and 8). Pure functions of the source and its `CommentIndex`.
///
/// **Order.** Every action returns its replacements sorted by location.
/// Every range refers to the original text, and no two ranges overlap or
/// touch. Apply them from the last to the first, as `TextEditing.applying`
/// does, so each range is still valid when it is applied; in the editor, make
/// them in that order inside one undo group.
///
/// **The store.** Records go into the store: the last run of record lines in
/// the file. It keeps the records in id order, one comment's records
/// together, the first entry first, then the replies in date order, then the
/// resolve events. A file with no store gets one at its end: one blank line,
/// the header and the records.
public enum CommentEdits {
    public enum Failure: Error, Equatable, Sendable {
        /// A newer Prose wrote this file's comments.
        case newerFormat
        /// No comment, entry or part is at the given place.
        case notFound
        /// The text is empty after trimming.
        case emptyText
        /// More than 4,000 characters of text.
        case textTooLong
        /// The comment already has 200 replies.
        case tooManyReplies
        /// The id is not a valid id, or the file already uses it.
        case invalidID
    }

    /// What a copy puts on Prose's private pasteboard type: the exact source
    /// of the selection, without the markers of comments that are not wholly
    /// inside it, and the record lines of the comments that are.
    public struct Clipboard: Equatable, Sendable {
        public let text: String
        public let records: [String]

        public init(text: String, records: [String]) {
            self.text = text
            self.records = records
        }
    }

    // MARK: Actions

    /// Adds comment `id` with its first entry: the two markers at `anchor`
    /// and the record in the store.
    public static func add(
        id: String,
        anchor: CommentAnchoring.Anchor,
        author: String,
        date: Date,
        text: String,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard CommentSyntax.isID(id), !index.ids.contains(id) else {
            throw Failure.invalidID
        }
        guard anchor.start >= 0, anchor.start < anchor.end, anchor.end <= source.length else {
            throw Failure.notFound
        }
        let record = try record(.comment, id: id, author: author, date: date, text: text)
        return normalized([
            TextReplacement(range: NSRange(location: anchor.start, length: 0), text: CommentSyntax.startMarker(id)),
            TextReplacement(range: NSRange(location: anchor.end, length: 0), text: CommentSyntax.endMarker(id)),
        ] + insert([record], index: index, source: source), source: source)
    }

    /// Adds a reply to comment `id`.
    public static func reply(
        to id: String,
        author: String,
        date: Date,
        text: String,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard let comment = index.comment(id) else {
            throw Failure.notFound
        }
        guard comment.replies.count < CommentSyntax.maximumReplies else {
            throw Failure.tooManyReplies
        }
        let record = try record(.reply, id: id, author: author, date: date, text: text)
        return normalized(insert([record], index: index, source: source), source: source)
    }

    /// Changes the text of `entry`: its record line is written again.
    public static func edit(
        _ entry: CommentIndex.Entry,
        text: String,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard let part = index.parts.first(where: { $0.range == entry.range }), var record = part.record,
              record.kind != .resolve
        else {
            throw Failure.notFound
        }
        record.text = try checked(text)
        return [TextReplacement(range: part.range, text: CommentSyntax.line(record))]
    }

    /// Adds a resolve record to comment `id`.
    public static func resolve(
        _ id: String,
        author: String,
        date: Date,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard index.comment(id) != nil else {
            throw Failure.notFound
        }
        let record = CommentSyntax.Record(
            kind: .resolve,
            id: id,
            author: CommentSyntax.author(author) ?? "Author",
            date: CommentSyntax.timestamp(date),
        )
        return normalized(insert([record], index: index, source: source), source: source)
    }

    /// Removes every resolve record of comment `id`.
    public static func reopen(_ id: String, index: CommentIndex, source: NSString) throws -> [TextReplacement] {
        try writable(index)
        let resolutions = index.parts.filter { $0.record?.id == id && $0.record?.kind == .resolve }
        guard index.comment(id) != nil, !resolutions.isEmpty else {
            throw Failure.notFound
        }
        return removing(resolutions, index: index, source: source)
    }

    /// Removes comment `id`: its markers and every record.
    public static func delete(_ id: String, index: CommentIndex, source: NSString) throws -> [TextReplacement] {
        try writable(index)
        let parts = index.parts.filter { $0.id == id && $0.kind != .unreadable }
        guard !parts.isEmpty else {
            throw Failure.notFound
        }
        return removing(parts, index: index, source: source)
    }

    /// Removes one reply.
    public static func deleteReply(
        _ entry: CommentIndex.Entry,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard entry.kind == .reply, let part = index.parts.first(where: { $0.range == entry.range }),
              part.record?.kind == .reply
        else {
            throw Failure.notFound
        }
        return removing([part], index: index, source: source)
    }

    /// Remove Markers, for "Markers with no comment": every marker of `id`.
    public static func removeMarkers(_ id: String, index: CommentIndex, source: NSString) throws -> [TextReplacement] {
        try writable(index)
        let markers = index.parts.filter {
            if case let .marker(_, markerID) = $0.kind {
                return markerID == id
            }
            return false
        }
        guard !markers.isEmpty else {
            throw Failure.notFound
        }
        return removing(markers, index: index, source: source)
    }

    /// Remove, for one copy of an id used more than once or for a reply with
    /// no comment: the marker or record at `range`. A marker goes with its
    /// partner when the pair is plain: the nearest marker of the other kind
    /// with the same id, with no marker of the first kind between.
    public static func remove(at range: NSRange, index: CommentIndex, source: NSString) throws -> [TextReplacement] {
        try writable(index)
        guard let part = index.parts.first(where: { $0.range == range }), part.id != nil else {
            throw Failure.notFound
        }
        return removing([part] + partner(of: part, index: index), index: index, source: source)
    }

    /// Give a New Id, for one copy of an id used more than once. A marker is
    /// renamed with its partner (see `remove(at:)`), and gets a copy of the
    /// id's records when the id has exactly one first entry. A first entry
    /// is renamed alone.
    public static func giveNewID(
        _ newID: String,
        at range: NSRange,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard CommentSyntax.isID(newID), !index.ids.contains(newID) else {
            throw Failure.invalidID
        }
        guard let part = index.parts.first(where: { $0.range == range }), let oldID = part.id else {
            throw Failure.notFound
        }
        switch part.kind {
        case var .record(record):
            record.id = newID
            return [TextReplacement(range: part.range, text: CommentSyntax.line(record))]
        case .marker:
            var replacements = ([part] + partner(of: part, index: index)).compactMap { marker in
                if case let .marker(kind, _) = marker.kind {
                    return TextReplacement(
                        range: marker.range,
                        text: kind == .start ? CommentSyntax.startMarker(newID) : CommentSyntax.endMarker(newID),
                    )
                }
                return nil
            }
            let records = index.parts.compactMap(\.record).filter { $0.id == oldID }
            if records.count(where: { $0.kind == .comment }) == 1 {
                replacements += insert(records.map { record in
                    var copy = record
                    copy.id = newID
                    return copy
                }, index: index, source: source)
            }
            return normalized(replacements, source: source)
        default:
            throw Failure.notFound
        }
    }

    /// Attach to Selection, for a damaged or unattached comment: its markers
    /// are removed and new ones go at `anchor`.
    public static func attach(
        _ id: String,
        anchor: CommentAnchoring.Anchor,
        index: CommentIndex,
        source: NSString,
    ) throws -> [TextReplacement] {
        try writable(index)
        guard index.comment(id) != nil, anchor.start >= 0, anchor.start < anchor.end, anchor.end <= source.length
        else {
            throw Failure.notFound
        }
        let old = index.parts.filter {
            if case let .marker(_, markerID) = $0.kind {
                return markerID == id
            }
            return false
        }
        return normalized(old.map { TextReplacement(range: $0.range, text: "") } + [
            TextReplacement(range: NSRange(location: anchor.start, length: 0), text: CommentSyntax.startMarker(id)),
            TextReplacement(range: NSRange(location: anchor.end, length: 0), text: CommentSyntax.endMarker(id)),
        ], source: source)
    }

    // MARK: Copy and paste

    /// The plain text of `range` for the general pasteboard: no start marker
    /// and no end marker.
    public static func plainText(of range: NSRange, index: CommentIndex, source: NSString) -> String {
        let markers = index.parts.filter {
            if case .marker = $0.kind {
                return NSIntersectionRange($0.range, range) == $0.range
            }
            return false
        }
        return excerpt(range, without: markers.map(\.range), source: source)
    }

    /// The private pasteboard contents for `range`: its source, with the
    /// markers of every comment wholly inside it and no other marker, and
    /// the records of those comments.
    public static func clipboard(of range: NSRange, index: CommentIndex, source: NSString) -> Clipboard {
        let inside = Set(index.comments.filter { comment in
            guard let start = comment.startMarker, let end = comment.endMarker, comment.state == .attached else {
                return false
            }
            return NSIntersectionRange(start, range) == start && NSIntersectionRange(end, range) == end
        }.map(\.id))
        let dropped = index.parts.filter {
            if case let .marker(_, id) = $0.kind {
                return !inside.contains(id) && NSIntersectionRange($0.range, range) == $0.range
            }
            return false
        }
        let records = index.parts.compactMap(\.record).filter { inside.contains($0.id) }.map(CommentSyntax.line)
        return Clipboard(text: excerpt(range, without: dropped.map(\.range), source: source), records: records)
    }

    /// A paste of `clipboard` over `range`. A comment whose id the file
    /// already uses gets a new id from `generator`; the records go into the
    /// store.
    public static func paste(
        _ clipboard: Clipboard,
        replacing range: NSRange,
        index: CommentIndex,
        source: NSString,
        using generator: inout some RandomNumberGenerator,
    ) throws -> [TextReplacement] {
        try writable(index)
        var records = clipboard.records.compactMap { line -> CommentSyntax.Record? in
            if case let .record(record) = CommentSyntax.parseLine(line) {
                return record
            }
            return nil
        }
        var used = index.ids
        var renamed: [String: String] = [:]
        for id in Set(records.map(\.id)).sorted() where index.ids.contains(id) {
            let fresh = CommentSyntax.newID(avoiding: used.union(records.map(\.id)), using: &generator)
            used.insert(fresh)
            renamed[id] = fresh
        }
        var text = clipboard.text
        for (old, new) in renamed {
            text = text.replacingOccurrences(of: CommentSyntax.startMarker(old), with: CommentSyntax.startMarker(new))
                .replacingOccurrences(of: CommentSyntax.endMarker(old), with: CommentSyntax.endMarker(new))
        }
        for position in records.indices {
            records[position].id = renamed[records[position].id] ?? records[position].id
        }
        return normalized(
            [TextReplacement(range: range, text: text)] + insert(records, index: index, source: source),
            source: source,
        )
    }

    // MARK: Copy Source Without Comments

    /// The source with every start marker, end marker, record and header
    /// removed, with the blank line before the store, and with one space a
    /// formatter left after a start marker that opens a heading, list,
    /// numbered or term item. Source comments stay, and so do unreadable
    /// `// prose:` lines, which are source comments.
    public static func withoutComments(_ source: NSString, index: CommentIndex) -> String {
        var removals: [TextReplacement] = []
        for part in index.parts {
            switch part.kind {
            case let .marker(kind, _):
                var range = part.range
                if kind == .start, opensItem(part.range, index: index, source: source),
                   NSMaxRange(range) < source.length, source.character(at: NSMaxRange(range)) == 0x20
                {
                    range.length += 1
                }
                removals.append(TextReplacement(range: range, text: ""))
            case .record, .header:
                removals.append(TextReplacement(range: lineRange(part.range, source: source), text: ""))
            case .unreadable, .notClosed:
                continue
            }
        }
        if let blank = blankLineBeforeStore(index: index, source: source) {
            removals.append(TextReplacement(range: blank, text: ""))
        }
        return (try? TextEditing.applying(normalized(removals, source: source), to: source as String)) ??
            source as String
    }

    // MARK: Helpers

    private static func writable(_ index: CommentIndex) throws {
        if index.isReadOnly {
            throw Failure.newerFormat
        }
    }

    /// The text of an entry, trimmed and within the limit.
    private static func checked(_ text: String) throws -> String {
        let trimmed = CommentSyntax.trimmedText(text)
        guard !trimmed.isEmpty else {
            throw Failure.emptyText
        }
        guard trimmed.count <= CommentSyntax.maximumTextLength else {
            throw Failure.textTooLong
        }
        return trimmed
    }

    private static func record(
        _ kind: CommentSyntax.RecordKind,
        id: String,
        author: String,
        date: Date,
        text: String,
    ) throws -> CommentSyntax.Record {
        try CommentSyntax.Record(
            kind: kind,
            id: id,
            author: CommentSyntax.author(author) ?? "Author",
            date: CommentSyntax.timestamp(date),
            text: checked(text),
        )
    }

    /// The other marker of a plain pair (see `remove(at:)`).
    private static func partner(of part: CommentIndex.Part, index: CommentIndex) -> [CommentIndex.Part] {
        guard case let .marker(kind, id) = part.kind else {
            return []
        }
        let markers = index.parts.filter {
            if case let .marker(_, other) = $0.kind {
                return other == id
            }
            return false
        }
        guard let position = markers.firstIndex(of: part) else {
            return []
        }
        let other: CommentSyntax.MarkerKind = kind == .start ? .end : .start
        let candidates = kind == .start ? Array(markers[(position + 1)...]) : markers[..<position].reversed()
        for candidate in candidates {
            guard case let .marker(candidateKind, _) = candidate.kind else {
                continue
            }
            if candidateKind == other {
                return [candidate]
            }
            return []
        }
        return []
    }

    /// Removes `parts`: a marker's range, a record's whole line. When no
    /// record is left in the file, the store's headers and the blank line
    /// before the store go too.
    private static func removing(
        _ parts: [CommentIndex.Part],
        index: CommentIndex,
        source: NSString,
    ) -> [TextReplacement] {
        var removals = parts.map { part in
            TextReplacement(range: part.isLine ? lineRange(part.range, source: source) : part.range, text: "")
        }
        let removed = Set(parts.map(\.range.location))
        let left = index.parts.contains {
            switch $0.kind {
            case .record, .unreadable: !removed.contains($0.range.location)
            default: false
            }
        }
        if !left, parts.contains(where: { $0.record != nil }) {
            for header in index.parts where !removed.contains(header.range.location) {
                if case .header = header.kind {
                    removals.append(TextReplacement(range: lineRange(header.range, source: source), text: ""))
                }
            }
            if let blank = blankLineBeforeStore(index: index, source: source) {
                removals.append(TextReplacement(range: blank, text: ""))
            }
        }
        return normalized(removals, source: source)
    }

    /// The store: the parts of the last run of record lines, each on the
    /// line after the one before.
    static func store(_ index: CommentIndex, source: NSString) -> [CommentIndex.Part] {
        let lines = index.parts.filter(\.isLine)
        guard var first = lines.indices.last else {
            return []
        }
        while first > 0 {
            let previous = lines[first - 1]
            let between = NSRange(
                location: NSMaxRange(previous.range),
                length: lines[first].range.location - NSMaxRange(previous.range),
            )
            let gap = source.substring(with: between)
            guard gap == "\n" || gap == "\r\n" else {
                break
            }
            first -= 1
        }
        return Array(lines[first...])
    }

    /// The blank line directly before the store, if there is one.
    private static func blankLineBeforeStore(index: CommentIndex, source: NSString) -> NSRange? {
        guard let first = store(index, source: source).first, first.range.location > 0 else {
            return nil
        }
        let previousLine = source.lineRange(for: NSRange(location: first.range.location - 1, length: 0))
        let text = source.substring(with: previousLine)
        guard text.allSatisfy(\.isWhitespace), previousLine.location < first.range.location else {
            return nil
        }
        return previousLine
    }

    /// The canonical order of records within a store.
    private static func key(_ record: CommentSyntax.Record) -> (String, Int, String) {
        let rank = switch record.kind {
        case .comment: 0
        case .reply: 1
        case .resolve: 2
        }
        return (record.id, rank, record.date)
    }

    /// Insertions that put `records` into the store in canonical order, or
    /// a new store at the end of the file.
    private static func insert(
        _ records: [CommentSyntax.Record],
        index: CommentIndex,
        source: NSString,
    ) -> [TextReplacement] {
        guard !records.isEmpty else {
            return []
        }
        let sorted = records.enumerated().sorted {
            key($0.element) != key($1.element) ? key($0.element) < key($1.element) : $0.offset < $1.offset
        }.map(\.element)
        let store = store(index, source: source)
        guard let last = store.last else {
            let endsLine = source.length == 0 || CommentSyntax.isNewline(unit: source.character(at: source.length - 1))
            let lines = ([CommentSyntax.header] + sorted.map(CommentSyntax.line)).map { $0 + "\n" }.joined()
            return [TextReplacement(
                range: NSRange(location: source.length, length: 0),
                text: (endsLine ? "" : "\n") + "\n" + lines,
            )]
        }
        var before: [Int: [String]] = [:]
        var after: [String] = []
        for record in sorted {
            if let next = store.first(where: { part in
                part.record.map { key($0) > key(record) } ?? false
            }) {
                before[next.range.location, default: []].append(CommentSyntax.line(record))
            } else {
                after.append(CommentSyntax.line(record))
            }
        }
        var insertions = before.map { location, lines in
            TextReplacement(range: NSRange(location: location, length: 0), text: lines.map { $0 + "\n" }.joined())
        }
        if !after.isEmpty {
            let end = lineRange(last.range, source: source)
            if NSMaxRange(end) > NSMaxRange(last.range) {
                insertions.append(TextReplacement(
                    range: NSRange(location: NSMaxRange(end), length: 0),
                    text: after.map { $0 + "\n" }.joined(),
                ))
            } else {
                insertions.append(TextReplacement(
                    range: NSRange(location: NSMaxRange(last.range), length: 0),
                    text: after.map { "\n" + $0 }.joined(),
                ))
            }
        }
        return insertions
    }

    /// A line comment's whole line: with its line break, or with the break
    /// before it when it is the file's last line.
    static func lineRange(_ range: NSRange, source: NSString) -> NSRange {
        var end = NSMaxRange(range)
        if end < source.length {
            end += source.character(at: end) == 0x0D && end + 1 < source.length &&
                source.character(at: end + 1) == 0x0A ? 2 : 1
            return NSRange(location: range.location, length: end - range.location)
        }
        var start = range.location
        if start > 0, CommentSyntax.isNewline(unit: source.character(at: start - 1)) {
            start -= 1
            if start > 0, source.character(at: start) == 0x0A, source.character(at: start - 1) == 0x0D {
                start -= 1
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// Whether the start marker at `range` comes first in a heading, list,
    /// numbered or term item's text: before it on its line are only the
    /// line's marker, its space and other markers.
    private static func opensItem(_ range: NSRange, index: CommentIndex, source: NSString) -> Bool {
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let markers = index.parts.filter {
            if case .marker = $0.kind {
                return $0.range.location >= line.location && NSMaxRange($0.range) <= range.location
            }
            return false
        }
        let prefix = excerpt(
            NSRange(location: line.location, length: range.location - line.location),
            without: markers.map(\.range),
            source: source,
        )
        let body = prefix.drop { $0 == " " || $0 == "\t" }
        guard body.hasSuffix(" ") || body.hasSuffix("\t") else {
            return false
        }
        let marker = body.trimmingCharacters(in: .whitespaces)
        if marker == "-" || marker == "+" || marker == "/" || (!marker.isEmpty && marker.allSatisfy { $0 == "=" }) {
            return true
        }
        return marker.hasSuffix(".") && marker.dropLast().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The text of `range` without the ranges in `removed`.
    private static func excerpt(_ range: NSRange, without removed: [NSRange], source: NSString) -> String {
        var result = "", cursor = range.location
        for cut in removed.sorted(by: { $0.location < $1.location }) where cut.location >= cursor {
            result += source.substring(with: NSRange(location: cursor, length: cut.location - cursor))
            cursor = NSMaxRange(cut)
        }
        return result + source.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
    }

    /// `replacements` sorted by location, with replacements that overlap or
    /// touch joined into one. At one location, the earlier in the list comes
    /// first.
    static func normalized(_ replacements: [TextReplacement], source: NSString) -> [TextReplacement] {
        let sorted = replacements.enumerated().sorted {
            ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset)
        }.map(\.element)
        var result: [TextReplacement] = []
        for replacement in sorted {
            guard let last = result.last, replacement.range.location <= NSMaxRange(last.range) else {
                result.append(replacement)
                continue
            }
            let end = max(NSMaxRange(last.range), NSMaxRange(replacement.range))
            result[result.count - 1] = TextReplacement(
                range: NSRange(location: last.range.location, length: end - last.range.location),
                text: last.text + replacement.text,
            )
        }
        return result
    }
}
