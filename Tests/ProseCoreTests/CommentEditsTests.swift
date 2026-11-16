import Foundation
@testable import ProseCore
import Testing

private let s = "/*<k3f9x2*/", e = "/*k3f9x2>*/"
private let day = Date(timeIntervalSince1970: 1_794_751_331) // 2026-11-15T14:02:11Z

private func apply(_ replacements: [TextReplacement], _ text: String) throws -> String {
    try TextEditing.applying(replacements, to: text)
}

@Test func addingTheFirstCommentCreatesTheStoreAndDeletingTheLastRemovesIt() throws {
    let original = "The quick brown fox.\n"
    let source = original as NSString
    let tree = try #require(SyntaxTree(original))
    let anchor = try CommentAnchoring.anchor(for: source.range(of: "quick"), in: source, tree: tree).get()
    let edits = try CommentEdits.add(
        id: "k3f9x2",
        anchor: anchor,
        author: "Tehran Davis",
        date: day,
        text: "Is \"quick\" right?  ",
        index: commentIndex(original),
        source: source,
    )
    #expect(edits == edits.sorted { $0.range.location < $1.range.location })
    let added = try apply(edits, original)
    #expect(added == """
    The \(s)quick\(e) brown fox.

    // prose:comments 1
    // prose:comment k3f9x2 | Tehran Davis | 2026-11-15T14:02:11Z | Is "quick" right?

    """)
    let index = try commentIndex(added)
    let deleted = try apply(CommentEdits.delete("k3f9x2", index: index, source: added as NSString), added)
    #expect(deleted == original)
    // A file with no final line break gets one before the blank line.
    let bare = "Text"
    let stored = try apply(CommentEdits.add(
        id: "k3f9x2",
        anchor: .init(start: 0, end: 4),
        author: "A",
        date: day,
        text: "x",
        index: commentIndex(bare),
        source: bare as NSString,
    ), bare)
    #expect(stored == "\(s)Text\(e)\n\n// prose:comments 1\n// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x\n")
}

@Test func theStoreKeepsIdOrderAndRepliesInDateOrder() throws {
    var text = "One two three four five.\n"
    var index = try commentIndex(text)
    for (id, word) in [("m4n5p6", "two"), ("a2b3c4", "four"), ("t2u3v4", "one")] {
        let range = (text as NSString).range(of: word, options: .caseInsensitive)
        text = try apply(CommentEdits.add(
            id: id,
            anchor: .init(start: range.location, end: NSMaxRange(range)),
            author: "A",
            date: day,
            text: word,
            index: index,
            source: text as NSString,
        ), text)
        index = try commentIndex(text)
    }
    func ids(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("// prose:") && !$0.hasPrefix("// prose:comments") }
            .map { String($0.split(separator: " ")[2]) }
    }
    #expect(ids(text) == ["a2b3c4", "m4n5p6", "t2u3v4"])
    // Replies: a later one after an earlier one, before the resolve record.
    text = try apply(
        CommentEdits.resolve("m4n5p6", author: "B", date: day, index: index, source: text as NSString),
        text,
    )
    for offset in [7200.0, 3600.0, 10800.0] {
        index = try commentIndex(text)
        text = try apply(CommentEdits.reply(
            to: "m4n5p6",
            author: "B",
            date: day.addingTimeInterval(offset),
            text: "at \(Int(offset))",
            index: index,
            source: text as NSString,
        ), text)
    }
    let lines = text.components(separatedBy: "\n").filter { $0.contains("m4n5p6 |") }
    #expect(lines.map { $0.components(separatedBy: " ")[1] } == [
        "prose:comment", "prose:reply", "prose:reply", "prose:reply", "prose:resolve",
    ])
    #expect(lines[1 ... 3].map { $0.components(separatedBy: " | ").last } == ["at 3600", "at 7200", "at 10800"])
    index = try commentIndex(text)
    #expect(index.comment("m4n5p6")?.isResolved == true && index.problems.isEmpty)
    // Reopen removes the resolve record; Resolve and Reopen are lines, not changes.
    let reopened = try apply(CommentEdits.reopen("m4n5p6", index: index, source: text as NSString), text)
    #expect(try commentIndex(reopened).comment("m4n5p6")?.isResolved == false)
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.reopen("m4n5p6", index: commentIndex(reopened), source: reopened as NSString)
    }
}

@Test func editAndDeleteChangeOnlyTheirLine() throws {
    let text = """
    A \(s)b\(e) c.

    // prose:comments 1
    // prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | first
    // prose:reply k3f9x2 | B | 2026-11-15T15:00:00Z | second

    """
    let index = try commentIndex(text)
    let comment = try #require(index.comment("k3f9x2"))
    let edited = try apply(
        CommentEdits.edit(comment.entries[1], text: "changed\nover two lines", index: index, source: text as NSString),
        text,
    )
    #expect(edited.contains("// prose:reply k3f9x2 | B | 2026-11-15T15:00:00Z | changed\\nover two lines\n"))
    #expect(try commentIndex(edited).comment("k3f9x2")?.replies.first?.text == "changed\nover two lines")
    let without = try apply(
        CommentEdits.deleteReply(comment.entries[1], index: index, source: text as NSString),
        text,
    )
    #expect(!without.contains("second") && without.contains("first"))
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.deleteReply(comment.entries[0], index: index, source: text as NSString)
    }
    #expect(throws: CommentEdits.Failure.emptyText) {
        try CommentEdits.edit(comment.entries[0], text: " \n ", index: index, source: text as NSString)
    }
    #expect(throws: CommentEdits.Failure.textTooLong) {
        try CommentEdits.edit(
            comment.entries[0],
            text: String(repeating: "x", count: 4001),
            index: index,
            source: text as NSString,
        )
    }
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.reply(to: "aaaaaa", author: "A", date: day, text: "x", index: index, source: text as NSString)
    }
    #expect(throws: CommentEdits.Failure.invalidID) {
        try CommentEdits.add(
            id: "k3f9x2",
            anchor: .init(start: 0, end: 1),
            author: "A",
            date: day,
            text: "x",
            index: index,
            source: text as NSString,
        )
    }
}

@Test func aCommentHasAtMost200Replies() throws {
    let replies = (0 ..< 200).map { "// prose:reply k3f9x2 | B | 2026-11-15T15:00:00Z | r\($0)" }
    let text = "A \(s)b\(e) c.\n\n// prose:comments 1\n// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x\n" +
        replies.joined(separator: "\n") + "\n"
    let index = try commentIndex(text)
    #expect(index.comment("k3f9x2")?.replies.count == 200)
    #expect(throws: CommentEdits.Failure.tooManyReplies) {
        try CommentEdits.reply(to: "k3f9x2", author: "A", date: day, text: "x", index: index, source: text as NSString)
    }
}

@Test func copyAndPasteCarryComments() throws {
    let text = """
    One \(s)two\(e) three /*<m4n5p6*/four.

    Five/*m4n5p6>*/ six.

    // prose:comments 1
    // prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | on two
    // prose:reply k3f9x2 | B | 2026-11-15T15:00:00Z | a reply
    // prose:comment m4n5p6 | A | 2026-11-15T14:02:11Z | on four

    """
    let source = text as NSString
    let index = try commentIndex(text)
    let sentence = source.range(of: "One \(s)two\(e) three /*<m4n5p6*/four.")
    #expect(CommentEdits.plainText(of: sentence, index: index, source: source) == "One two three four.")
    let clipboard = CommentEdits.clipboard(of: sentence, index: index, source: source)
    #expect(clipboard.text == "One \(s)two\(e) three four.", "a marker whose partner is outside is left out")
    #expect(clipboard.records.count == 2 && clipboard.records.allSatisfy { $0.contains("k3f9x2") })
    // After a copy the id is in the file: the paste gets a new id and a copy of the records.
    var random = CommentRandom(state: 3)
    let end = source.range(of: " six.").location + 5
    let pasted = try apply(CommentEdits.paste(
        clipboard,
        replacing: NSRange(location: end, length: 0),
        index: index,
        source: source,
        using: &random,
    ), text)
    let after = try commentIndex(pasted)
    #expect(after.problems.isEmpty && after.comments.count == 3)
    let copy = try #require(after.comments.first { !["k3f9x2", "m4n5p6"].contains($0.id) })
    #expect(copy.state == .attached && copy.entries.map(\.text) == ["on two", "a reply"])
    // After a cut the id is gone: the paste keeps it.
    let cutEdits = try CommentEdits.delete("k3f9x2", index: index, source: source)
    let cut = try apply(cutEdits, text)
    let back = try apply(CommentEdits.paste(
        clipboard,
        replacing: NSRange(location: 0, length: 0),
        index: commentIndex(cut),
        source: cut as NSString,
        using: &random,
    ), cut)
    #expect(back.hasPrefix("One \(s)two\(e) three four."))
    #expect(try commentIndex(back).comment("k3f9x2")?.entries.count == 2)
}

@Test func copySourceWithoutCommentsKeepsSourceCommentsAndRemovesFormatterSpaces() throws {
    let text = """
    = /*<k3f9x2*/ Title/*k3f9x2>*/

    - /*<a2b3c4*/ /*<m4n5p6*/ item/*m4n5p6>*//*a2b3c4>*/ // a source comment
    + /*<q7r8s9*/ two/*q7r8s9>*/
    Text /*<t2u3v4*/ spaced/*t2u3v4>*/ /* kept */ end.
    /*<note*/ stays.

    // prose:comments 1
    // prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x
    // prose:comment a2b3c4 | A | 2026-11-15T14:02:11Z | x
    // prose:x unreadable line stays
    """
    let index = try commentIndex(text)
    #expect(CommentEdits.withoutComments(text as NSString, index: index) == """
    = Title

    - item // a source comment
    + two
    Text  spaced /* kept */ end.
    /*<note*/ stays.
    // prose:x unreadable line stays
    """)
}

// MARK: Acceptance test 5

private let blocks = [
    "The quick brown fox jumps over the lazy dog.", "= A heading with words", "== Another *strong* heading",
    "- a list item\n- another item\n  continued here", "+ numbered one\n+ numbered two", "/ Term: its description",
    "Some *bold text* and _emphasis_ in a line.", "An equation $x^2 + 1$ and `raw code` and @key[p. 4] here.",
    "Visit https://typst.app now, or #link(\"https://example.com\")[a link].", "#let x = 1",
    "A #emph[content block] with a footnote#footnote[A note.] in it.", "Words, words, words. 中文字 and émigré.",
    "// a source comment", "Under_scored and 2*3 and wait... and 1--2.",
]

private func randomDocument(_ random: inout CommentRandom) -> String {
    (0 ..< Int.random(in: 1 ... 6, using: &random)).map { _ in
        blocks[Int.random(in: 0 ..< blocks.count, using: &random)]
    }.joined(separator: Bool.random(using: &random) ? "\n\n" : "\n") + "\n"
}

/// For random documents and random sequences of actions, the index after
/// each action equals a full build of the new text, and the text without
/// comments equals the original document.
@Test func randomActionsKeepTheIndexAndTheDocument() throws {
    var actions = 0, added = 0
    for seed: UInt64 in 1 ... 1000 {
        var random = CommentRandom(state: seed)
        let original = randomDocument(&random)
        let text = NSMutableString(string: original)
        let tree = try #require(SyntaxTree(original))
        var index = try commentIndex(original)
        for step in 0 ..< 8 {
            let date = day.addingTimeInterval(Double(Int.random(in: 0 ..< 100, using: &random)) * 60)
            let comment = index.comments.randomElement(using: &random)
            var edits: [TextReplacement] = []
            switch Int.random(in: 0 ..< 6, using: &random) {
            case 0, 1:
                let start = Int.random(in: 0 ... text.length, using: &random)
                let length = Int.random(in: 0 ... min(40, text.length - start), using: &random)
                let selection = NSRange(location: start, length: length)
                guard let anchor = try? CommentAnchoring.anchor(for: selection, in: text, tree: tree).get() else {
                    continue
                }
                edits = try CommentEdits.add(
                    id: CommentSyntax.newID(avoiding: index.ids, using: &random),
                    anchor: anchor,
                    author: "Author \(step)",
                    date: date,
                    text: "Comment | */ /* \\ \n line \(step)",
                    index: index,
                    source: text,
                )
                added += 1
            case 2:
                guard let comment else {
                    continue
                }
                edits = try CommentEdits.reply(
                    to: comment.id, author: "B", date: date, text: "reply", index: index, source: text,
                )
            case 3:
                guard let entry = comment?.entries.randomElement(using: &random) else {
                    continue
                }
                edits = try CommentEdits.edit(entry, text: "edited \(step)", index: index, source: text)
            case 4:
                guard let comment else {
                    continue
                }
                edits = try comment.isResolved ?
                    CommentEdits.reopen(comment.id, index: index, source: text) :
                    CommentEdits.resolve(comment.id, author: "C", date: date, index: index, source: text)
            default:
                guard let comment else {
                    continue
                }
                if let reply = comment.replies.randomElement(using: &random), Bool.random(using: &random) {
                    edits = try CommentEdits.deleteReply(reply, index: index, source: text)
                } else {
                    edits = try CommentEdits.delete(comment.id, index: index, source: text)
                }
            }
            actions += 1
            try applyComment(edits, to: text, tree: tree, index: &index)
            let fresh = try commentIndex(text as String)
            #expect(index == fresh, "seed \(seed) step \(step)")
            #expect(fresh.problems.isEmpty, "seed \(seed) step \(step)")
            #expect(fresh.comments.allSatisfy { $0.state == .attached }, "seed \(seed) step \(step)")
            #expect(CommentEdits.withoutComments(text, index: fresh) == original, "seed \(seed) step \(step)")
            let visible = { (value: String) in value.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) } }
            #expect(visible(text as String) - fresh.hiddenCharacterCount == visible(original), "seed \(seed)")
        }
        // Deleting every comment gives back the original exactly.
        while let comment = index.comments.first {
            try applyComment(
                CommentEdits.delete(comment.id, index: index, source: text),
                to: text,
                tree: tree,
                index: &index,
            )
        }
        #expect(text as String == original, "seed \(seed)")
    }
    #expect(actions > 4000 && added > 1000)
}

@Test func editsHandleCRLFLinesEndMarkerCopiesAndBadInput() throws {
    // A store with CR LF line breaks, at the end of a file with no final break.
    let text = "A \(s)b\(e) c.\r\n\r\n// prose:comments 1\r\n// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x"
    let index = try commentIndex(text)
    #expect(index.commentCount == 1 && index.comment("k3f9x2")?.state == .attached)
    let replied = try apply(
        CommentEdits.reply(to: "k3f9x2", author: "B", date: day, text: "y", index: index, source: text as NSString),
        text,
    )
    #expect(replied.hasSuffix("| x\n// prose:reply k3f9x2 | B | 2026-11-15T14:02:11Z | y"))
    let deleted = try apply(CommentEdits.delete("k3f9x2", index: index, source: text as NSString), text)
    #expect(deleted == "A b c.\r\n")
    // Give a New Id on an end marker copy renames its start marker too.
    let copied = "One \(s)two\(e) and \(s)three\(e).\n\n// prose:comments 1\n" +
        "// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x\n"
    let copies = try commentIndex(copied)
    let lastEnd = (copied as NSString).range(of: e, options: .backwards)
    let renamed = try apply(
        CommentEdits.giveNewID("m4n5p6", at: lastEnd, index: copies, source: copied as NSString),
        copied,
    )
    #expect(renamed.hasPrefix("One \(s)two\(e) and /*<m4n5p6*/three/*m4n5p6>*/."))
    #expect(try commentIndex(renamed).problems.isEmpty)
    // With a marker of the same kind between, a copy has no plain partner.
    let crossed = "A \(s)b \(s)c\(e) d\(e).\n\n// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x\n"
    let crossedIndex = try commentIndex(crossed)
    let first = (crossed as NSString).range(of: s)
    let alone = try apply(CommentEdits.remove(at: first, index: crossedIndex, source: crossed as NSString), crossed)
    #expect(alone.hasPrefix("A b \(s)c\(e) d\(e)."))
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.giveNewID(
            "m4n5p6",
            at: NSRange(location: 0, length: 1),
            index: crossedIndex,
            source: crossed as NSString,
        )
    }
    // Bad input to Add.
    let plain = "Words here.\n"
    let empty = try commentIndex(plain)
    for (text, failure) in [(" ", CommentEdits.Failure.emptyText), (
        String(repeating: "y", count: 4001),
        .textTooLong,
    )] {
        #expect(throws: failure) {
            try CommentEdits.add(
                id: "k3f9x2", anchor: .init(start: 0, end: 5), author: "A", date: day, text: text, index: empty,
                source: plain as NSString,
            )
        }
    }
    #expect(throws: CommentEdits.Failure.notFound) {
        try CommentEdits.add(
            id: "k3f9x2", anchor: .init(start: 5, end: 5), author: "A", date: day, text: "x", index: empty,
            source: plain as NSString,
        )
    }
    #expect(throws: CommentEdits.Failure.invalidID) {
        try CommentEdits.add(
            id: "bad", anchor: .init(start: 0, end: 5), author: "A", date: day, text: "x", index: empty,
            source: plain as NSString,
        )
    }
    // An empty author is written as "Author".
    let authored = try apply(CommentEdits.add(
        id: "k3f9x2", anchor: .init(start: 0, end: 5), author: " | ", date: day, text: "x", index: empty,
        source: plain as NSString,
    ), plain)
    #expect(authored.contains("k3f9x2 | Author | "))
    for action in [
        { try CommentEdits.resolve("aaaaaa", author: "A", date: day, index: empty, source: plain as NSString) },
        { try CommentEdits.delete("aaaaaa", index: empty, source: plain as NSString) },
        { try CommentEdits.reopen("aaaaaa", index: empty, source: plain as NSString) },
    ] {
        #expect(throws: CommentEdits.Failure.notFound) { try action() }
    }
}
