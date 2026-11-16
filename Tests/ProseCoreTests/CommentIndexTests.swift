import Foundation
@testable import ProseCore
import Testing

func commentIndex(_ text: String) throws -> CommentIndex {
    let tree = try #require(SyntaxTree(text))
    return try #require(CommentIndex(source: text as NSString, tree: tree))
}

/// Applies `replacements` from the last to the first, as the editor will, and
/// keeps `tree` and `index` in step with each one.
func applyComment(
    _ replacements: [TextReplacement],
    to text: NSMutableString,
    tree: SyntaxTree,
    index: inout CommentIndex,
) throws {
    for replacement in replacements.reversed() {
        text.replaceCharacters(in: replacement.range, with: replacement.text)
        let reparsed = try #require(tree.edit(replacement.range, replacement: replacement.text))
        let updated = index.update(
            replacing: replacement.range,
            length: (replacement.text as NSString).length,
            reparsed: reparsed,
            tree: tree,
            source: text,
        )
        #expect(updated)
    }
}

func range(of part: String, in text: String) -> NSRange {
    (text as NSString).range(of: part)
}

private let entry = "// prose:comment k3f9x2 | Tehran Davis | 2026-11-15T14:02:11Z | Is \"quick\" right?"
private let reply = "// prose:reply k3f9x2 | Ada Park | 2026-11-15T15:10:40Z | Yes.\\nA second paragraph."
private let resolve = "// prose:resolve k3f9x2 | Tehran Davis | 2026-11-16T10:00:03Z"
private let s = "/*<k3f9x2*/", e = "/*k3f9x2>*/"
private let store = "\n// prose:comments 1\n\(entry)\n\(reply)\n\(resolve)\n"

@Test func theIndexReadsAWholeComment() throws {
    let text = "The \(s) quick brown fox \(e) jumps.\n" + store
    let index = try commentIndex(text)
    #expect(index.problems.isEmpty && !index.isReadOnly)
    let comment = try #require(index.comment("k3f9x2"))
    #expect(comment.state == .attached && comment.isResolved)
    #expect(comment.startMarker == range(of: s, in: text) && comment.endMarker == range(of: e, in: text))
    #expect(comment.anchor == range(of: "quick brown fox", in: text), "whitespace at the edges is left out")
    #expect(comment.entries.map(\.author) == ["Tehran Davis", "Ada Park"])
    #expect(comment.replies.first?.text == "Yes.\nA second paragraph.")
    #expect(comment.entries.first?.range == range(of: entry, in: text))
    #expect(comment.resolutions.first?.date == "2026-11-16T10:00:03Z")
    #expect(index.ids == ["k3f9x2"])
    let visible = { (value: String) in value.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) } }
    #expect(visible(text) - index.hiddenCharacterCount == visible("The quick brown fox jumps.\n"))
    // An anchor that holds only whitespace is empty, at its start.
    let empty = try commentIndex("A \(s)  \(e) b.\n" + store)
    #expect(empty.comments.first?.anchor == NSRange(location: 13, length: 0))
}

@Test func aRecordCountsOnlyAtTheTopLevelAtTheStartOfALine() throws {
    let text = "- item\n  \(entry)\n\nText \(entry)\n#emph[\n\(entry)\n]\n"
    let index = try commentIndex(text)
    #expect(index.comments.isEmpty && index.problems.isEmpty)
    // After a list, at the first column, it is at the top level.
    #expect(try commentIndex("- one\n- two\n\(entry)\n").comment("k3f9x2")?.state == .notAttached)
    // Replies come in date order, whatever their order in the file.
    let late = "// prose:reply k3f9x2 | B | 2026-11-17T00:00:00Z | late"
    let early = "// prose:reply k3f9x2 | C | 2026-11-16T00:00:00Z | early"
    let ordered = try commentIndex("\(entry)\n\(late)\n\(early)\n")
    #expect(ordered.comment("k3f9x2")?.replies.map(\.text) == ["early", "late"])
}

/// Acceptance test 7, and the unit tests for decision 3's table: each row
/// gives its state and its problem, and the index changes no character.
@Test func aBlockCommentThatIsNotAMarkerIsASourceComment() throws {
    for text in ["/*<note*/ a", "/*<k3f9x1*/ b", "/* k3f9x2 */ c", "/*<k3f9x2 */ d", "/*<k3f9x2>*/ e"] {
        let index = try commentIndex(text)
        #expect(index.comments.isEmpty && index.problems.isEmpty && index.hiddenCharacterCount == 0, "\(text)")
    }
}

@Test func markersWithNoFirstEntryAreAProblemWithRemoveMarkers() throws {
    let text = "The \(s)quick\(e) fox.\n"
    let index = try commentIndex(text)
    #expect(index.comments.isEmpty)
    #expect(index.problems == [.init(
        kind: .markersWithNoComment,
        id: "k3f9x2",
        ranges: [range(of: s, in: text), range(of: e, in: text)],
    )])
    let fixed = try TextEditing.applying(
        CommentEdits.removeMarkers("k3f9x2", index: index, source: text as NSString),
        to: text,
    )
    #expect(fixed == "The quick fox.\n")
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.removeMarkers("aaaaaa", index: index, source: text as NSString)
    }
}

@Test func aFirstEntryWithOneMarkerOrTheWrongOrderIsDamaged() throws {
    for body in ["The \(s)quick fox.\n", "The quick\(e) fox.\n", "The \(e)quick\(s) fox.\n"] {
        let text = body + "\n// prose:comments 1\n\(entry)\n"
        let index = try commentIndex(text)
        let comment = try #require(index.comment("k3f9x2"))
        #expect(comment.state == .damaged && comment.anchor == nil, "\(body)")
        #expect(index.problems.isEmpty)
        // Attach to Selection: the old marker goes, new ones go round the selection.
        let source = text as NSString
        let tree = try #require(SyntaxTree(text))
        let anchor = try CommentAnchoring.anchor(for: source.range(of: "fox"), in: source, tree: tree).get()
        let attached = try TextEditing.applying(
            CommentEdits.attach("k3f9x2", anchor: anchor, index: index, source: source),
            to: text,
        )
        #expect(attached.hasPrefix("The quick \(s)fox\(e).\n"), "\(attached)")
        #expect(try commentIndex(attached).comment("k3f9x2")?.state == .attached)
        // Delete removes what exists, and the store with the last record.
        let deleted = try TextEditing.applying(CommentEdits.delete("k3f9x2", index: index, source: source), to: text)
        #expect(deleted == "The quick fox.\n")
    }
}

@Test func aFirstEntryWithNeitherMarkerIsNotAttached() throws {
    let text = "Text.\n\n// prose:comments 1\n\(entry)\n"
    let index = try commentIndex(text)
    #expect(index.comment("k3f9x2")?.state == .notAttached)
    #expect(index.comment("k3f9x2")?.location == range(of: entry, in: text).location)
    #expect(index.problems.isEmpty)
    let source = text as NSString
    let attached = try TextEditing.applying(
        CommentEdits.attach("k3f9x2", anchor: .init(start: 0, end: 4), index: index, source: source),
        to: text,
    )
    #expect(attached.hasPrefix("\(s)Text\(e).\n"))
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.attach("aaaaaa", anchor: .init(start: 0, end: 4), index: index, source: source)
    }
}

@Test func anIdUsedMoreThanOnceHasAProblemOnEachCopy() throws {
    // A sentence copied in another editor: two anchors, one thread.
    let text = "One \(s)two\(e) three. Four \(s)five\(e) six.\n\n// prose:comments 1\n\(entry)\n\(reply)\n"
    let index = try commentIndex(text)
    let comment = try #require(index.comment("k3f9x2"))
    #expect(comment.state == .usedMoreThanOnce && comment.anchor == nil && comment.startMarker == nil)
    let source = text as NSString
    let copies = index.problems.filter { $0.kind == .usedMoreThanOnce }.flatMap(\.ranges)
    #expect(copies.count == 4)
    let second = source.range(of: s, options: .backwards)
    #expect(copies.contains(second))
    // Give a New Id: the second anchor and a copy of the thread.
    let renamed = try TextEditing.applying(
        CommentEdits.giveNewID("m4n5p6", at: second, index: index, source: source),
        to: text,
    )
    let after = try commentIndex(renamed)
    #expect(after.problems.isEmpty)
    #expect(after.comments.map(\.id) == ["k3f9x2", "m4n5p6"])
    #expect(after.comments.allSatisfy { $0.state == .attached && $0.entries.count == 2 })
    #expect(renamed.contains("Four /*<m4n5p6*/five/*m4n5p6>*/ six."))
    // Remove: the first copy and its end marker go.
    let removed = try TextEditing.applying(
        CommentEdits.remove(at: copies[0], index: index, source: source),
        to: text,
    )
    #expect(removed.hasPrefix("One two three. Four \(s)five\(e) six."))
    #expect(try commentIndex(removed).comment("k3f9x2")?.state == .attached)
    #expect(throws: CommentEdits.Failure.invalidID) {
        try CommentEdits.giveNewID("k3f9x2", at: second, index: index, source: source)
    }

    // Two first entries: each is a copy, and a new id renames that line only.
    let twice = "A \(s)b\(e) c.\n\n// prose:comments 1\n\(entry)\n\(entry)\n"
    let twiceIndex = try commentIndex(twice)
    let lines = twiceIndex.problems.flatMap(\.ranges)
    #expect(lines.count == 2 && twiceIndex.comment("k3f9x2")?.state == .usedMoreThanOnce)
    let split = try TextEditing.applying(
        CommentEdits.giveNewID("m4n5p6", at: lines[1], index: twiceIndex, source: twice as NSString),
        to: twice,
    )
    let splitIndex = try commentIndex(split)
    #expect(splitIndex.comment("k3f9x2")?.state == .attached)
    #expect(splitIndex.comment("m4n5p6")?.state == .notAttached)
    let dropped = try TextEditing.applying(
        CommentEdits.remove(at: lines[1], index: twiceIndex, source: twice as NSString),
        to: twice,
    )
    #expect(try commentIndex(dropped).comment("k3f9x2")?.state == .attached)
    // Two end markers and one start marker.
    let ends = try commentIndex("A \(s)b\(e) c\(e).\n\n\(entry)\n")
    #expect(ends.problems.count == 2 && ends.problems.allSatisfy { $0.kind == .usedMoreThanOnce })
}

@Test func anUnreadableLineIsAProblemAndStaysAsItIs() throws {
    let bad = "// prose:comment k3f9x2 | A | yesterday | x"
    let text = "A \(s)b\(e) c.\n\n// prose:comments 1\n\(bad)\n"
    let index = try commentIndex(text)
    #expect(index.problems.contains { $0 == .init(kind: .unreadableLine, id: nil, ranges: [range(of: bad, in: text)]) })
    #expect(index.comments.isEmpty)
    // Adding a comment leaves the line untouched; so does the copy without comments.
    let tree = try #require(SyntaxTree(text))
    let source = text as NSString
    let anchor = try CommentAnchoring.anchor(for: source.range(of: "c."), in: source, tree: tree).get()
    let added = try TextEditing.applying(CommentEdits.add(
        id: "m4n5p6",
        anchor: anchor,
        author: "A",
        date: Date(timeIntervalSince1970: 0),
        text: "x",
        index: index,
        source: source,
    ), to: text)
    #expect(added.contains("\n" + bad + "\n"))
    #expect(CommentEdits.withoutComments(source, index: index).contains(bad))
}

@Test func aReplyWithNoCommentIsAProblemWithRemove() throws {
    let text = "Text.\n\n// prose:comments 1\n\(reply)\n\(resolve)\n"
    let index = try commentIndex(text)
    #expect(index.comments.isEmpty)
    #expect(index.problems.map(\.kind) == [.replyWithNoComment, .replyWithNoComment])
    let source = text as NSString
    let once = try TextEditing.applying(
        CommentEdits.remove(at: range(of: reply, in: text), index: index, source: source),
        to: text,
    )
    #expect(once == "Text.\n\n// prose:comments 1\n\(resolve)\n")
    let twice = try TextEditing.applying(
        CommentEdits.remove(at: range(of: resolve, in: once), index: commentIndex(once), source: once as NSString),
        to: once,
    )
    #expect(twice == "Text.\n", "the last record takes the store with it")
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.remove(at: NSRange(location: 0, length: 4), index: index, source: source)
    }
}

@Test func aNewerHeaderMakesEveryActionUnavailable() throws {
    let text = "A \(s)b\(e) c.\n\n// prose:comments 2\n\(entry)\n"
    let index = try commentIndex(text)
    #expect(index.isReadOnly && index.formatVersion == 2)
    #expect(index.comment("k3f9x2")?.state == .attached)
    #expect(index.problems.map(\.kind) == [.newerFormat(version: 2)])
    let source = text as NSString
    let date = Date(timeIntervalSince1970: 0)
    let actions: [() throws -> [TextReplacement]] = [
        { try CommentEdits.add(
            id: "m4n5p6",
            anchor: .init(start: 0, end: 1),
            author: "A",
            date: date,
            text: "x",
            index: index,
            source: source,
        ) },
        { try CommentEdits.reply(to: "k3f9x2", author: "A", date: date, text: "x", index: index, source: source) },
        { try CommentEdits.resolve("k3f9x2", author: "A", date: date, index: index, source: source) },
        { try CommentEdits.reopen("k3f9x2", index: index, source: source) },
        { try CommentEdits.delete("k3f9x2", index: index, source: source) },
        { try CommentEdits.removeMarkers("k3f9x2", index: index, source: source) },
        { try CommentEdits.remove(at: range(of: s, in: text), index: index, source: source) },
        { try CommentEdits.attach("k3f9x2", anchor: .init(start: 0, end: 1), index: index, source: source) },
        { try CommentEdits.giveNewID("m4n5p6", at: range(of: s, in: text), index: index, source: source) },
        { try CommentEdits.edit(
            #require(index.comment("k3f9x2")?.entries.first),
            text: "y",
            index: index,
            source: source,
        ) },
        { try CommentEdits.deleteReply(
            #require(index.comment("k3f9x2")?.entries.first),
            index: index,
            source: source,
        ) },
    ]
    for action in actions {
        #expect(throws: CommentEdits.Failure.newerFormat) { try action() }
    }
}

@Test func aMarkerThatNeverClosesIsReportedNotClosed() throws {
    for (text, location) in [
        ("A /*<k3f9x2* b c.\n\nMore text.\n", 2),
        ("A /*<k3f9x2*/b/*k3f9x2> c.\n", 14),
        ("A /*<k3f9x2 /*k3f9x2>*/ c.\n", 2),
    ] {
        let index = try commentIndex(text)
        #expect(index.problems.contains {
            $0.kind == .notClosed && $0.ranges == [NSRange(location: location, length: 9)] && $0.id == "k3f9x2"
        }, "\(text)")
    }
    // Closed by a later `*/`, it is a source comment.
    #expect(try commentIndex("A /*<k3f9x2 b */ c.\n").problems.isEmpty)
}

// MARK: Incremental updates

/// Edits that touch markers, records and their line starts.
private let editPieces = [
    "", "x", " ", "\n", "\n\n", "/*", "*/", "*", "$", "`", "\"", "#emph[", "]", "- ", "= ",
    "/*<k3f9x2*/", "/*k3f9x2>*/", "/*<m4n5p6*/", "/*m4n5p6>*/", "// prose:", "// prose:comments 1\n",
    "\(entry)\n", "// prose:reply m4n5p6 | B | 2026-11-17T00:00:00Z | r\n", "// note\n", "中😀",
]

@Test func incrementalUpdatesMatchAFullBuildOnSmallFiles() throws {
    let base = "The \(s)quick\(e) brown /*<m4n5p6*/fox.\n\n- an item/*m4n5p6>*/\n\n= Head\n" + store +
        "// prose:comment m4n5p6 | B | 2026-11-15T14:02:11Z | x\n"
    for seed: UInt64 in 1 ... 40 {
        var random = CommentRandom(state: seed)
        let text = NSMutableString(string: base)
        let tree = try #require(SyntaxTree(base))
        var index = try commentIndex(base)
        for step in 0 ..< 60 {
            let start = Int.random(in: 0 ... text.length, using: &random)
            let end = min(text.length, start + Int.random(in: 0 ... 12, using: &random))
            var range = NSRange(location: start, length: end - start)
            if start < text.length {
                range = text.rangeOfComposedCharacterSequences(for: range)
            }
            let piece = editPieces[Int.random(in: 0 ..< editPieces.count, using: &random)]
            try applyComment([TextReplacement(range: range, text: piece)], to: text, tree: tree, index: &index)
            #expect(try index == commentIndex(text as String), "seed \(seed) step \(step)")
        }
    }
}

@Test func anEditThatFailsLeavesTheIndexAsItWas() throws {
    let text = NSMutableString(string: "a😀b")
    let tree = try #require(SyntaxTree(text as String))
    var index = try commentIndex(text as String)
    _ = tree.edit(NSRange(location: 2, length: 0), replacement: "x")
    let updated = index.update(
        replacing: NSRange(location: 2, length: 0),
        length: 1,
        reparsed: NSRange(location: 0, length: 0),
        tree: tree,
        source: text,
    )
    #expect(!updated)
    #expect(CommentIndex(source: text, tree: tree) == nil)
    #expect(index == CommentIndex())
}

// MARK: Books

/// A book with `count` comments: anchors of a few words on plain lines,
/// spread through the book, and a store with a first entry and a reply each.
func bookWithComments(_ path: String, count: Int) throws -> String {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let book = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    var lines = book.components(separatedBy: "\n")
    // Places for an anchor of four words: every sixth word of a plain line.
    var slots: [(line: Int, word: Int)] = []
    for (index, line) in lines.enumerated() where line.count > 40 && line.first?.isLetter == true &&
        !line.contains(where: { "#$@*_<>[]`\\/{}~=".contains($0) })
    {
        let words = line.components(separatedBy: " ").count
        slots += stride(from: 1, to: words - 4, by: 6).map { (index, $0) }
    }
    var random = CommentRandom(state: 0x5EED)
    var used: Set<String> = []
    var records: [CommentSyntax.Record] = []
    let step = max(1, slots.count / count)
    for (number, slot) in stride(from: 0, to: slots.count, by: step).map({ slots[$0] }).prefix(count).enumerated() {
        var words = lines[slot.line].components(separatedBy: " ")
        let id = CommentSyntax.newID(avoiding: used, using: &random)
        used.insert(id)
        words[slot.word] = CommentSyntax.startMarker(id) + words[slot.word]
        words[slot.word + 3] += CommentSyntax.endMarker(id)
        lines[slot.line] = words.joined(separator: " ")
        let date = String(format: "2026-11-%02dT10:00:00Z", 1 + number % 28)
        records.append(.init(kind: .comment, id: id, author: "Reader", date: date, text: "Comment \(number)."))
        records.append(.init(kind: .reply, id: id, author: "Writer", date: date, text: "Reply \(number)."))
    }
    let store = ([CommentSyntax.header] + records.sorted { $0.id < $1.id }.map(CommentSyntax.line))
        .joined(separator: "\n")
    return lines.joined(separator: "\n") + "\n\n" + store + "\n"
}

/// Acceptance test 8: the index after an edit equals an index built from
/// the whole new text, on a book with 500 comments.
///
/// Scaled down for the default run: 2,000 edits, each compared with a full
/// build of the tree's nodes every 25 edits and with a fresh parse at the
/// end, so the core suite stays fast. `PROSE_COMMENT_STRESS=1` runs the
/// note's 10,000 edits and compares after every one, with a fresh parse
/// every 1,000.
@Test func incrementalUpdatesMatchAFullBuildOnABook() throws {
    let stress = ProcessInfo.processInfo.environment["PROSE_COMMENT_STRESS"] == "1"
    let book = try bookWithComments("Examples/Books/SICP/main.typ", count: 500)
    let text = NSMutableString(string: book)
    let tree = try #require(SyntaxTree(book))
    var index = try commentIndex(book)
    #expect(index.comments.count == 500 && index.comments.allSatisfy { $0.state == .attached })
    #expect(index.problems.isEmpty)
    // No piece opens something that runs to the end of the book: that is
    // tested on small files, and here it would make every edit reparse it.
    // `#` and a stray `*/` are left out too: over thousands of edits they
    // turn the book into code and errors, and Typst's reparse grows slow.
    let pieces = ["", "x", " ", "\n", "\n\n", "word ", "/*<a2b3c4*/", "/*a2b3c4>*/",
                  "// prose:reply a2b3c4 | B | 2026-11-17T00:00:00Z | r\n", "\(entry)\n", "// prose:x\n"]
    var random = CommentRandom(state: 0xB00C)
    let edits = stress ? 10000 : 2000
    for step in 0 ..< edits {
        // Half the edits land next to a comment part.
        let parts = index.parts
        var start = Int.random(in: 0 ... text.length, using: &random)
        if Bool.random(using: &random), let part = parts.randomElement(using: &random) {
            start = max(0, min(text.length, part.range.location + Int.random(in: -3 ... 3, using: &random)))
        }
        var range = NSRange(location: start, length: min(text.length - start, Int.random(in: 0 ... 14, using: &random)))
        if start < text.length {
            range = text.rangeOfComposedCharacterSequences(for: range)
        }
        // Never leave part of a marker: a lost `*/` comments out the rest.
        for part in parts where !part.isLine && NSIntersectionRange(part.range, range).length > 0 {
            range = NSUnionRange(range, part.range)
        }
        let piece = pieces[Int.random(in: 0 ..< pieces.count, using: &random)]
        try applyComment([TextReplacement(range: range, text: piece)], to: text, tree: tree, index: &index)
        if stress {
            #expect(try index == CommentIndex(source: text, nodes: #require(tree.nodes())), "step \(step)")
            if (step + 1).isMultiple(of: 1000) {
                #expect(try index == commentIndex(text as String), "step \(step)")
                print("PROSE COMMENT STRESS step \(step + 1)")
            }
        } else if (step + 1).isMultiple(of: 25) {
            #expect(try index == CommentIndex(source: text, nodes: #require(tree.nodes())), "step \(step)")
        }
    }
    #expect(try index == commentIndex(text as String))
}

/// The cost of the index on both books with 500 comments: a full build, and
/// 1,000 updates while typing. A measurement, not a gate; it prints with
/// `PROSE_COMMENT_COST=1`.
@Test func commentIndexCostOnBooks() throws {
    guard ProcessInfo.processInfo.environment["PROSE_COMMENT_COST"] == "1" else {
        return
    }
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    let clock = ContinuousClock()
    for (name, path) in [
        ("war-and-peace", "Examples/Books/WarAndPeace/war-and-peace-highlighted.typ"),
        ("sicp", "Examples/Books/SICP/main.typ"),
    ] {
        let book = try bookWithComments(path, count: 500)
        let tree = try #require(SyntaxTree(book))
        var started = clock.now
        let nodes = try #require(tree.nodes())
        let convert = milliseconds(started.duration(to: clock.now))
        started = clock.now
        var index = CommentIndex(source: book as NSString, nodes: nodes)
        let build = milliseconds(started.duration(to: clock.now))
        #expect(index.comments.count == 500)
        let text = NSMutableString(string: book)
        var random = CommentRandom(state: 7)
        var updates: [Double] = [], windows: [Double] = []
        var cursor = text.length / 3
        for step in 0 ..< 1000 {
            if step.isMultiple(of: 50) {
                cursor = Int.random(in: 0 ..< text.length / 2, using: &random)
                cursor = NSMaxRange(text.lineRange(for: NSRange(location: cursor, length: 0)))
            }
            let range = NSRange(location: cursor, length: 0)
            text.replaceCharacters(in: range, with: "x")
            let reparsed = try #require(tree.edit(range, replacement: "x"))
            started = clock.now
            _ = tree.nodes(in: reparsed)
            windows.append(milliseconds(started.duration(to: clock.now)))
            started = clock.now
            index.update(replacing: range, length: 1, reparsed: reparsed, tree: tree, source: text)
            updates.append(milliseconds(started.duration(to: clock.now)))
            cursor += 1
        }
        updates.sort()
        windows.sort()
        let median = updates[updates.count / 2], p95 = updates[updates.count * 95 / 100]
        let total = updates.reduce(0, +)
        print("PROSE COMMENT INDEX \(name): \(nodes.count) nodes in \(convert) ms, full build \(build) ms, " +
            "1,000 updates \(total) ms (median \(median), p95 \(p95), max \(updates.last ?? 0) ms); " +
            "for comparison, the reparsed range's nodes alone: median \(windows[windows.count / 2]) ms")
    }
}
