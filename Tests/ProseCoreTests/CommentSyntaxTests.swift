import Foundation
@testable import ProseCore
import Testing

/// SplitMix64: a seeded random source, so a failure reproduces from its seed.
struct CommentRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Acceptance test 4: every character of decision 3 survives a round trip,
/// and the record is one line that typst-syntax reads as one line comment.
@Test func commentTextRoundTripsThroughOneRecordLine() throws {
    let texts = [
        "A backslash \\ and two \\\\ and \\n written out",
        "Line feed\nsecond line", "Vertical\u{0B}tab", "Form\u{0C}feed", "Carriage\rreturn", "Next\u{85}line",
        "Line\u{2028}separator", "Paragraph\u{2029}separator", "Ends */ and opens /* and // too",
        "A | bar and | another |", "Emoji 😀👩🏽‍💻 and flags 🇳🇿", "中文和日本語のテキスト", "Tabs\tinside",
        "\\u{41} is not an escape when written", "",
    ]
    for text in texts {
        let escaped = CommentSyntax.escape(text)
        #expect(CommentSyntax.unescape(escaped) == text, "\(text.debugDescription)")
        #expect(!escaped.unicodeScalars.contains(where: CommentSyntax.isNewline))
        guard !text.isEmpty else {
            continue
        }
        let record = CommentSyntax.Record(
            kind: .reply,
            id: "k3f9x2",
            author: "Ada Park",
            date: "2026-11-15T15:10:40Z",
            text: text,
        )
        let line = CommentSyntax.line(record)
        #expect(CommentSyntax.parseLine(line) == .record(record), "\(line)")
        let document = "Text.\n\n" + line + "\nMore.\n"
        let nodes = try #require(SyntaxTree(document)?.nodes())
        let comments = nodes.filter { $0.kind == .lineComment }
        #expect(comments.count == 1)
        #expect(comments.first.map { (document as NSString).substring(with: $0.range) } == line)
        let erroneous = nodes.contains(where: \.isErroneous)
        #expect(!erroneous)
    }
    // CR LF is one line break, written `\n`.
    #expect(CommentSyntax.escape("a\r\nb") == "a\\nb")
    #expect(CommentSyntax.escape("\u{2028}") == "\\u{2028}")
    #expect(CommentSyntax.unescape("\\u{1F600}\\u{A}") == "😀\n")
    for invalid in ["\\t", "a\\", "\\u", "\\u{", "\\u{}", "\\u{110000}", "\\u{D800}", "\\u{1234567}", "\\u{xyz}"] {
        #expect(CommentSyntax.unescape(invalid) == nil, "\(invalid)")
    }
}

@Test func recordLinesParseInEveryFormAndRejectTheRest() {
    let comment = "// prose:comment k3f9x2 | Tehran Davis | 2026-11-15T14:02:11Z | Is \"quick\" the right word here?"
    #expect(CommentSyntax.parseLine(comment) == .record(.init(
        kind: .comment,
        id: "k3f9x2",
        author: "Tehran Davis",
        date: "2026-11-15T14:02:11Z",
        text: "Is \"quick\" the right word here?",
    )))
    #expect(CommentSyntax.parseLine("// prose:resolve k3f9x2 | Tehran Davis | 2026-11-16T10:00:03Z  ") == .record(
        .init(kind: .resolve, id: "k3f9x2", author: "Tehran Davis", date: "2026-11-16T10:00:03Z"),
    ))
    #expect(CommentSyntax.parseLine("// prose:comments 1") == .header(version: 1))
    #expect(CommentSyntax.parseLine("// prose:comments 2") == .header(version: 2))
    // Trailing whitespace an editor left, and an empty text whose space it trimmed.
    #expect(CommentSyntax.parseLine("// prose:reply k3f9x2 | A | 2026-11-15T14:02:11Z | text \t") == .record(
        .init(kind: .reply, id: "k3f9x2", author: "A", date: "2026-11-15T14:02:11Z", text: "text"),
    ))
    #expect(CommentSyntax.parseLine("// prose:reply k3f9x2 | A | 2026-11-15T14:02:11Z |") == .record(
        .init(kind: .reply, id: "k3f9x2", author: "A", date: "2026-11-15T14:02:11Z", text: ""),
    ))
    #expect(CommentSyntax.parseLine("// a source comment") == nil)
    #expect(CommentSyntax.parseLine("//prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | x") == nil)
    for unreadable in [
        "// prose:", "// prose:comments", "// prose:comments one", "// prose:comments 0", "// prose:comments 1 x",
        "// prose:note k3f9x2 | A | 2026-11-15T14:02:11Z | x",
        "// prose:comment k3f9x1 | A | 2026-11-15T14:02:11Z | x",
        "// prose:comment 3kf9x2 | A | 2026-11-15T14:02:11Z | x",
        "// prose:comment k3f9x2 | A | 2026-11-15 | x", "// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z",
        "// prose:comment k3f9x2 A 2026-11-15T14:02:11Z x", "// prose:comment k3f9x2 | A",
        "// prose:comment k3f9x2 | A | 2026-11-15T14:02:11Z | bad \\q escape",
        "// prose:resolve k3f9x2 | A | 2026-11-15T14:02:11Z | text",
    ] {
        #expect(CommentSyntax.parseLine(unreadable) == .unreadable, "\(unreadable)")
    }
}

@Test func writtenRecordsTrimTextAndCleanTheAuthor() {
    let record = CommentSyntax.Record(
        kind: .comment,
        id: "k3f9x2",
        author: "  Ada | Park\nSecond line ",
        date: "2026-11-15T14:02:11Z",
        text: "Trailing spaces and a newline  \n\t",
    )
    #expect(CommentSyntax.line(record) ==
        "// prose:comment k3f9x2 | Ada  Park Second line | 2026-11-15T14:02:11Z | Trailing spaces and a newline")
    #expect(CommentSyntax.author(String(repeating: "x", count: 80))?.count == 64)
    #expect(CommentSyntax.author(" | \n ") == nil)
    #expect(CommentSyntax.author("Tehran Davis") == "Tehran Davis")
    #expect(CommentSyntax.trimmedText("  keep leading  \u{2028}") == "  keep leading")
    #expect(CommentSyntax.maximumTextLength == 4000 && CommentSyntax.maximumReplies == 200)
}

@Test func idsMarkersAndDatesFollowTheFormat() throws {
    #expect(CommentSyntax.isID("k3f9x2"))
    for bad in ["k3f9x1", "3kf9x2", "k3f9x", "k3f9x22", "K3F9X2", "k3f9o2", "k3f9 2"] {
        #expect(!CommentSyntax.isID(bad), "\(bad)")
    }
    var generator = CommentRandom(state: 42)
    var used: Set<String> = []
    for _ in 0 ..< 500 {
        let id = CommentSyntax.newID(avoiding: used, using: &generator)
        #expect(CommentSyntax.isID(id) && !used.contains(id))
        used.insert(id)
    }
    let source = "/*<k3f9x2*/ /*k3f9x2>*/ /*<note22*/ /*<k3f9x1*/ /* k3f9x */ /*<k3f9x2>*/ /*k3f9x2*/" as NSString
    let start = try #require(CommentSyntax.marker(in: source, at: NSRange(location: 0, length: 11)))
    let end = try #require(CommentSyntax.marker(in: source, at: NSRange(location: 12, length: 11)))
    #expect(start == (.start, "k3f9x2") && end == (.end, "k3f9x2"))
    for text in ["/*<note22*/", "/*<k3f9x1*/", "/* k3f9x */"] {
        #expect(CommentSyntax.marker(in: source, at: source.range(of: text)) == nil, "\(text)")
    }
    #expect(CommentSyntax.marker(in: source, at: source.range(of: "/*<k3f9x2>*/")) == nil)
    #expect(CommentSyntax.marker(in: source, at: source.range(of: "/*k3f9x2*/")) == nil)
    #expect(CommentSyntax.marker(in: source, at: NSRange(location: 0, length: 10)) == nil)
    #expect(CommentSyntax.startMarker("k3f9x2").utf16.count == 11 && CommentSyntax.endMarker("k3f9x2") == "/*k3f9x2>*/")
    let date = try #require(CommentSyntax.date("2026-11-15T14:02:11Z"))
    #expect(CommentSyntax.timestamp(date) == "2026-11-15T14:02:11Z")
    #expect(CommentSyntax.date("2026-11-15 14:02:11") == nil)
}
