import Foundation
@testable import ProseCore
import Testing

// Phase 8 step C: the rules for the writer's edits near a comment's markers
// (decision 4), the index's anchors and the actor that keeps the index off
// the main thread.

private let ruled = """
The /*<k3f9x2*/quick brown fox/*k3f9x2>*/ jumps.

Next /*<m4pq7r*/line/*m4pq7r>*/ here.

// prose:comments 1
// prose:comment k3f9x2 | Ada | 2026-11-15T14:02:11Z | One.
// prose:reply k3f9x2 | Bo | 2026-11-15T15:02:11Z | Two.
// prose:comment m4pq7r | Ada | 2026-11-15T14:02:11Z | Three.

"""

private func ruledIndex(_ text: String) throws -> CommentIndex {
    let tree = try #require(SyntaxTree(text))
    return try #require(CommentIndex(source: text as NSString, tree: tree))
}

/// The text after `plan`, or after the edit itself when no rule applies.
private func edited(
    _ text: String,
    _ range: NSRange,
    _ replacement: String,
    selection: NSRange? = nil,
) throws -> (text: String, plan: CommentEditRules.Plan?) {
    let plan = try CommentEditRules.plan(
        replacing: range,
        with: replacement,
        selection: selection ?? range,
        index: ruledIndex(text),
        source: text as NSString,
    )
    let edits = plan?.replacements ?? [TextReplacement(range: range, text: replacement)]
    return try (TextEditing.applying(edits, to: text), plan)
}

@Test func anEditAwayFromEveryMarkerStands() throws {
    let text = ruled as NSString
    #expect(try edited(ruled, text.range(of: "jumps"), "runs").plan == nil)
    // All the text between the two, but neither: no rule, an empty anchor.
    let between = text.range(of: "quick brown fox")
    let result = try edited(ruled, between, "")
    #expect(result.plan == nil)
    let anchor = try #require(ruledIndex(result.text).anchors.first { $0.id == "k3f9x2" })
    #expect(anchor.range.length == 0)
    // An empty edit at a marker's edge touches nothing.
    #expect(try edited(ruled, NSRange(location: text.range(of: "/*<k3f9x2*/").location, length: 0), "x")
        .plan == nil)
}

@Test func removingBothMarkersRemovesTheRecordsInTheSameEdit() throws {
    let text = ruled as NSString
    let line = text.range(of: "The /*<k3f9x2*/quick brown fox/*k3f9x2>*/ jumps.")
    let result = try edited(ruled, line, "")
    let plan = try #require(result.plan)
    #expect(!result.text.contains("k3f9x2"))
    #expect(result.text.contains("// prose:comment m4pq7r"))
    #expect(plan.selection == NSRange(location: line.location, length: 0))
    // The new text puts a marker back: it moved, and the records stay.
    let moved = try edited(ruled, line, "Moved /*<k3f9x2*/quick/*k3f9x2>*/.")
    #expect(moved.text.contains("// prose:comment k3f9x2"))
    // Both comments' markers and all their records: the store goes too.
    let all = NSRange(location: 0, length: text.range(of: " here.").location + 6)
    let emptied = try edited(ruled, all, "")
    #expect(!emptied.text.contains("prose:"))
}

@Test func removingOneMarkerKeepsItWhereTheRemovalWas() throws {
    let text = ruled as NSString
    // The end marker's side: it stays before any new text.
    let tail = text.range(of: "fox/*k3f9x2>*/ jum")
    let result = try edited(ruled, tail, "X")
    #expect(result.text.hasPrefix("The /*<k3f9x2*/quick brown /*k3f9x2>*/Xps."))
    #expect(result.plan?.selection == NSRange(location: tail.location + 12, length: 0))
    let anchor = try #require(ruledIndex(result.text).comments.first { $0.id == "k3f9x2" }?.anchor)
    #expect((result.text as NSString).substring(with: anchor) == "quick brown")
    // The start marker's side: it stays after any new text.
    let head = text.range(of: "The /*<k3f9x2*/qu")
    #expect(try edited(ruled, head, "A").text.hasPrefix("A/*<k3f9x2*/ick brown"))
    // A cut into the middle of a marker takes the whole marker.
    let partial = NSRange(location: text.range(of: "/*<k3f9x2*/").location + 3, length: 10)
    #expect(try edited(ruled, partial, "").text.hasPrefix("The /*<k3f9x2*/ick brown"))
}

@Test func backspaceAndForwardDeleteBesideAMarkerPassOverIt() throws {
    let text = ruled as NSString
    let start = text.range(of: "/*<k3f9x2*/"), end = text.range(of: "/*k3f9x2>*/")
    // Backspace after the start marker removes the space before it.
    let back = try edited(
        ruled,
        NSRange(location: NSMaxRange(start) - 1, length: 1),
        "",
        selection: NSRange(location: NSMaxRange(start), length: 0),
    )
    #expect(back.text.hasPrefix("The/*<k3f9x2*/quick"))
    #expect(back.plan?.selection == NSRange(location: NSMaxRange(start) - 1, length: 0))
    // Forward Delete before the end marker removes the space after it.
    let forward = try edited(
        ruled,
        NSRange(location: end.location, length: 1),
        "",
        selection: NSRange(location: end.location, length: 0),
    )
    #expect(forward.text.hasPrefix("The /*<k3f9x2*/quick brown fox/*k3f9x2>*/jumps."))
    #expect(forward.plan?.selection == NSRange(location: end.location, length: 0))
    // At the very start or end of the text there is nothing to remove.
    let first = "/*<a2b3c4*/x/*a2b3c4>*/\n\n// prose:comments 1\n// prose:comment a2b3c4 | A | 2026-11-15T14:02:11Z | T.\n"
    let atStart = try edited(first, NSRange(location: 10, length: 1), "", selection: NSRange(location: 11, length: 0))
    #expect(atStart.plan?.replacements.isEmpty == true && atStart.text == first)
    let last = "// prose:comment a2b3c4 | A | 2026-11-15T14:02:11Z | T.\nx/*<a2b3c4*/y/*a2b3c4>*/"
    let atEnd = try CommentEditRules.plan(
        replacing: NSRange(location: (last as NSString).length - 11, length: 1),
        with: "",
        selection: NSRange(location: (last as NSString).length - 11, length: 0),
        index: ruledIndex(last),
        source: last as NSString,
    )
    #expect(atEnd?.replacements.isEmpty == true)
    // A word deleted with the marker is a removal, not a pass.
    let word = try edited(
        ruled,
        NSRange(location: text.range(of: "fox").location, length: NSMaxRange(end) - text.range(of: "fox").location),
        "",
        selection: NSRange(location: NSMaxRange(end), length: 0),
    )
    #expect(word.text.hasPrefix("The /*<k3f9x2*/quick brown /*k3f9x2>*/ jumps."))
    // An edit outside the text is not ruled.
    #expect(try CommentEditRules.plan(
        replacing: NSRange(location: text.length + 1, length: 0),
        with: "x",
        selection: NSRange(),
        index: ruledIndex(ruled),
        source: text,
    ) == nil)
}

@Test func theIndexsAnchorsAndTheStoreFollowEdits() throws {
    let index = try ruledIndex(ruled)
    #expect(index.anchors.map(\.id) == ["k3f9x2", "m4pq7r"])
    let text = ruled as NSString
    let store = try #require(CommentEdits.storeRange(index: index, source: text))
    #expect(store.location == text.range(of: "// prose:comments 1").location)
    #expect(NSMaxRange(store) == NSMaxRange(text.range(of: "| Three.")))
    #expect(CommentEdits.deleteRecords(of: [], index: index, source: text).isEmpty)
    #expect(try CommentEdits.storeRange(index: ruledIndex("No comments."), source: "No comments.") == nil)
    // Moving the store: before it, at its end, across its start, over all of it.
    #expect(CommentEdits.rebaseStore(store, editing: NSRange(location: 0, length: 0), delta: 2)?.location ==
        store.location + 2)
    #expect(CommentEdits.rebaseStore(store, editing: NSRange(location: NSMaxRange(store), length: 0), delta: 5)?
        .length == store.length + 5)
    #expect(CommentEdits.rebaseStore(store, editing: NSRange(location: NSMaxRange(store) + 1, length: 0), delta: 5) ==
        store)
    #expect(CommentEdits.rebaseStore(store, editing: NSRange(location: store.location - 2, length: 4), delta: -4)?
        .location == store.location - 2)
    #expect(CommentEdits.rebaseStore(store, editing: store, delta: -store.length) == nil)
}

@Test func theIndexSourceFollowsEditsAndStartsAgainWhenTheyDoNotFit() async throws {
    let source = CommentIndexSource()
    let opened = await source.open(ruled)
    #expect(opened.anchors.count == 2 && opened.store != nil)
    let text = NSMutableString(string: ruled)
    let edits = [
        TextReplacement(range: NSRange(location: 0, length: 3), text: "A"),
        TextReplacement(range: NSRange(location: text.length - 2, length: 0), text: "x"),
    ]
    for edit in edits {
        text.replaceCharacters(in: edit.range, with: edit.text)
    }
    let updated = try #require(await source.update(edits))
    #expect(try updated.index == ruledIndex(text as String))
    #expect(await source.builds == 1)
    // An edit that unbalances a comment: the index is still the text's.
    let open = TextReplacement(range: NSRange(location: 1, length: 0), text: "/*")
    text.replaceCharacters(in: open.range, with: open.text)
    let unbalanced = try #require(await source.update([open]))
    #expect(try unbalanced.index == ruledIndex(text as String))
    // An edit past the end does not fit.
    #expect(await source.update([TextReplacement(range: NSRange(location: 99999, length: 0), text: "x")]) == nil)
}
