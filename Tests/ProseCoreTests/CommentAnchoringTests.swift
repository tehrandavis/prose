import Foundation
@testable import ProseCore
import Testing

/// The source of a test string, and the selection marked in it with `«` and
/// `»`, or a caret with `|`.
private func selection(_ marked: String) -> (source: String, range: NSRange) {
    let text = marked as NSString
    if text.range(of: "|").location != NSNotFound, text.range(of: "«").location == NSNotFound {
        let caret = text.range(of: "|").location
        return (text.replacingOccurrences(of: "|", with: ""), NSRange(location: caret, length: 0))
    }
    let open = text.range(of: "«").location
    let close = text.range(of: "»").location - 1
    let source = text.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
    return (source, NSRange(location: open, length: close - open))
}

/// The source with the markers of comment `k3f9x2` where anchoring puts
/// them, or the refusal.
private func anchored(_ marked: String) throws -> Result<String, CommentAnchoring.Refusal> {
    let (source, range) = selection(marked)
    let tree = try #require(SyntaxTree(source))
    return CommentAnchoring.anchor(for: range, in: source as NSString, tree: tree).map { anchor in
        let text = NSMutableString(string: source)
        text.insert(CommentSyntax.endMarker("k3f9x2"), at: anchor.end)
        text.insert(CommentSyntax.startMarker("k3f9x2"), at: anchor.start)
        return text as String
    }
}

/// The whole document's tree, with the two markers left out and offsets
/// moved back, equals the tree before: the check, over the whole file.
private func sameTree(_ before: String, _ after: String) throws -> Bool {
    let old = try #require(SyntaxTree(before)?.nodes())
    let new = try #require(SyntaxTree(after)?.nodes())
    let text = after as NSString
    let markers = new.indices.filter {
        new[$0].kind == .blockComment && CommentSyntax.marker(in: text, at: new[$0].range)?.id == "k3f9x2"
    }
    let starts = markers.map { new[$0].range.location }
    func back(_ offset: Int) -> Int {
        offset - starts.filter { $0 < offset }.count * CommentSyntax.markerLength
    }
    var index = [Int?](repeating: nil, count: new.count)
    var kept: [SyntaxNode] = []
    for (position, node) in new.enumerated() where !markers.contains(position) {
        index[position] = kept.count
        let lower = back(node.range.location), upper = back(NSMaxRange(node.range))
        kept.append(SyntaxNode(
            kind: node.kind,
            range: NSRange(location: lower, length: upper - lower),
            parent: node.parent.flatMap { index[$0] },
            depth: node.depth,
            isErroneous: node.isErroneous,
        ))
    }
    return kept == old
}

private let s = "/*<k3f9x2*/", e = "/*k3f9x2>*/"

/// Acceptance test 6: each row of decision 2's table, with step A's strings
/// where step A had them.
@Test(arguments: [
    // Between words, or inside a word, in a paragraph, heading, list item or term item.
    ("The «quick brown fox» jumps over the lazy dog.\n", "The \(s)quick brown fox\(e) jumps over the lazy dog.\n"),
    ("An un«believ»able result.\n", "An un\(s)believ\(e)able result.\n"),
    ("= The «quick» heading\n", "= The \(s)quick\(e) heading\n"),
    ("«= Title»\n\nText.\n", "= \(s)Title\(e)\n\nText.\n"),
    ("- An «item» here\n- First word\n", "- An \(s)item\(e) here\n- First word\n"),
    ("- «First» word\n", "- \(s)First\(e) word\n"),
    ("«- item»\n", "- \(s)item\(e)\n"),
    ("«+ Numbered» item\n", "+ \(s)Numbered\(e) item\n"),
    ("/ Term: its «description»\n", "/ Term: its \(s)description\(e)\n"),
    ("«/ Term: more»\n", "/ \(s)Term: more\(e)\n"),
    // Across strong or emphasis, one end inside.
    ("Some *bold «text* and more» words.\n", "Some *bold \(s)text* and more\(e) words.\n"),
    ("and _emph«asis_ plain» text.\n", "and _emph\(s)asis_ plain\(e) text.\n"),
    // From one block to a later block.
    (
        "First «paragraph ends here.\n\nSecond paragraph» goes on.\n",
        "First \(s)paragraph ends here.\n\nSecond paragraph\(e) goes on.\n",
    ),
    // Around whole nodes; an end inside one moves outward.
    ("An «$x^2 + 1$» equation.\n", "An \(s)$x^2 + 1$\(e) equation.\n"),
    ("An $x^«2» + 1$ equation.\n", "An \(s)$x^2 + 1$\(e) equation.\n"),
    ("Some `ra«w co»de` here.\n", "Some \(s)`raw code`\(e) here.\n"),
    ("A #\"a«b»c\" string.\n", "A \(s)#\"abc\"\(e) string.\n"),
    ("Text <la«bel>» more.\n", "Text \(s)<label>\(e) more.\n"),
    ("See @in«tro» now.\n", "See \(s)@intro\(e) now.\n"),
    ("See @smith2020[p. «4]» now.\n", "See \(s)@smith2020[p. 4]\(e) now.\n"),
    ("See «@smith2020»[p. 4] now.\n", "See \(s)@smith2020[p. 4]\(e) now.\n"),
    ("A \\«#» sign.\n", "A \(s)\\#\(e) sign.\n"),
    ("Pages 1 -«- 2».\n", "Pages 1 \(s)-- 2\(e).\n"),
    ("A #em«ph[x]» y.\n", "A \(s)#emph[x]\(e) y.\n"),
    ("A «#emph»[x] y.\n", "A \(s)#emph[x]\(e) y.\n"),
    ("A #text(fill: «red)[x]» y.\n", "A \(s)#text(fill: red)[x]\(e) y.\n"),
    ("A «#d».y z.\n", "A \(s)#d.y\(e) z.\n"),
    ("A «#link(\"https://example.com\")[link]» b.\n", "A \(s)#link(\"https://example.com\")[link]\(e) b.\n"),
    // Inside the content blocks of calls.
    ("#emph[an «emphasised» word] and text#footnote[A «foot»note.] more.\n", nil),
    ("#figure(rect(), caption: [A «caption» here.])\n", "#figure(rect(), caption: [A \(s)caption\(e) here.])\n"),
    // Directly after a `*`: before the closing star, before an opening one.
    ("Some «*bold*» text.\n", "Some \(s)*bold\(e)* text.\n"),
    ("Some *«bold*» text.\n", "Some \(s)*bold\(e)* text.\n"),
    // Directly after a bare URL: after the next space, or before the URL.
    ("Visit «https://typst.app» now.\n", "Visit \(s)https://typst.app \(e)now.\n"),
    ("Visit https://typ«st.app» now.\n", "Visit \(s)https://typst.app \(e)now.\n"),
    ("Visit «the site https://typst.app».\n", "Visit \(s)the site \(e)https://typst.app.\n"),
    // Before a line's list, numbered or term marker, or in a list item's indent.
    ("- one\n«- two»\n", "- one\n- \(s)two\(e)\n"),
    ("- one\n  «more» text\n- two\n", "- one\(s)\n  more\(e) text\n- two\n"),
    ("- one\n«after» text\n", "- one\(s)\nafter\(e) text\n"),
    // At the end of a statement's line.
    ("«A #let x = 1»\nb\n", "\(s)A \(e)#let x = 1\nb\n"),
] as [(String, String?)])
func anchoringFollowsDecisionTwo(_ marked: String, _ expected: String?) throws {
    let result = try anchored(marked)
    let (source, _) = selection(marked)
    guard case let .success(text) = result else {
        Issue.record("refused: \(marked.debugDescription)")
        return
    }
    if let expected {
        #expect(text == expected, "\(marked.debugDescription)")
    }
    #expect(try sameTree(source, text), "\(marked.debugDescription)")
}

@Test func anchoringRefusesWhatHasNoSafePlace() throws {
    for marked in [
        // A start marker between a digit and a star makes strong text.
        "2«*3» is six.\n",
        // Between a letter and an underscore: emphasis.
        "A snake«_case» name.\n",
        // Only a bare URL: its end goes before it, so nothing is left.
        "Visit «https://typst.app».\n",
        // Only a statement: its end goes before it.
        "A «#let x = 1»\nb\n",
    ] {
        #expect(try anchored(marked) == .failure(.unsafe), "\(marked.debugDescription)")
    }
    #expect(try anchored("Some «   » text.\n") == .failure(.empty))
    #expect(try anchored("Two  |  spaces.\n") == .failure(.noWord))
    #expect(try anchored("A . | , b\n") == .failure(.noWord))
}

@Test func anEmptySelectionAnchorsTheWordAtTheCaret() throws {
    #expect(try anchored("The qu|ick fox.\n") == .success("The \(s)quick\(e) fox.\n"))
    #expect(try anchored("The quick| fox.\n") == .success("The \(s)quick\(e) fox.\n"))
    #expect(try anchored("The |quick fox.\n") == .success("The \(s)quick\(e) fox.\n"))
    #expect(try anchored("It do|esn't matter.\n") == .success("It \(s)doesn't\(e) matter.\n"))
    #expect(try anchored("中文|字 here.\n") == .success("\(s)中文字\(e) here.\n"))
}

@Test func anchorsMayOverlapAndNest() throws {
    let source = "One \(s)two three\(e) four.\n"
    let (text, range) = selection("One /*<k3f9x2*/«two» three/*k3f9x2>*/ four.\n")
    #expect(text == source)
    let tree = try #require(SyntaxTree(text))
    let anchor = try CommentAnchoring.anchor(for: range, in: text as NSString, tree: tree).get()
    #expect(anchor == CommentAnchoring.Anchor(start: 15, end: 18))
}

@Test func theCheckComparesTheBlocksAroundTheAnchor() throws {
    let text = "First paragraph.\n\n```\nraw\n\nwith a blank line\n```\n\nThird «para»graph.\n\nLast.\n"
    let (source, range) = selection(text)
    let tree = try #require(SyntaxTree(source))
    let blocks = CommentAnchoring.blocks(around: range, source: source as NSString, tree: tree)
    #expect((source as NSString).substring(with: blocks) == "Third paragraph.")
    let whole = try CommentAnchoring.blocks(
        around: NSRange(location: 3, length: 1),
        source: "abc\ndef" as NSString,
        tree: #require(SyntaxTree("abc\ndef")),
    )
    #expect(whole == NSRange(location: 0, length: 7))
    #expect(!CommentAnchoring.isSafe(start: 4, end: 2, source: source as NSString, tree: tree))
}
