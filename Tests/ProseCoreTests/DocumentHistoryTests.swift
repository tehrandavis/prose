import Foundation
import ProseCore
import ProseTestSupport
import Testing

@Test func documentHistoryKeepsSevenEditedCheckpointsAndSurvivesRestart() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentHistory(root: root), start = Date(timeIntervalSince1970: 1_000_000)
    #expect(try await store.revisions(for: "book").isEmpty)
    #expect(try await store
        .recordEdit(key: "book", previous: "same", current: "same", at: start, interval: .hourly) == nil)
    let first = try #require(try await store.recordEdit(
        key: "book",
        previous: "draft 0",
        current: "draft 1",
        at: start,
        interval: .hourly,
    ))
    #expect(try await store.source(for: first, key: "book") == "draft 0")
    #expect(try await store.recordEdit(
        key: "book",
        previous: "draft 1",
        current: "draft 2",
        at: start.addingTimeInterval(100),
        interval: .hourly,
    ) == nil)
    for hour in 1 ... 10 {
        try await store.recordEdit(
            key: "book",
            previous: "draft \(hour)",
            current: "draft \(hour + 1)",
            at: start.addingTimeInterval(Double(hour) * 3600),
            interval: .hourly,
        )
    }
    let restarted = DocumentHistory(root: root)
    let revisions = try await restarted.revisions(for: "book")
    #expect(revisions.count == 7)
    #expect(try await restarted.source(for: revisions[0], key: "book") == "draft 10")
    #expect(try await restarted.source(for: revisions[6], key: "book") == "draft 4")
    let contents = try FileManager.default.subpathsOfDirectory(atPath: root.path)
    #expect(contents.filter { $0.hasSuffix(".typ") }.count == 7)
    #expect(try await restarted.revisions(for: "different").isEmpty)
    await #expect(throws: HistoryError.unavailable) { try await restarted.source(for: first, key: "book") }
}

@Test func historyDailyCadenceAndRestorationSafety() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("history-daily-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DocumentHistory(root: root), start = Date(timeIntervalSince1970: 1_000_000)
    try await store.recordEdit(key: "book", previous: "α 😀", current: "after", at: start, interval: .daily)
    #expect(try await store.recordEdit(
        key: "book",
        previous: "after",
        current: "later",
        at: start.addingTimeInterval(3600),
        interval: .daily,
    ) == nil)
    try await store.recordEdit(
        key: "book",
        previous: "later",
        current: "today",
        at: start.addingTimeInterval(86400),
        interval: .daily,
    )
    #expect(try await store.revisions(for: "book").count == 2)
    let safety = try await store.preserveBeforeRestore(
        "unsaved today",
        key: "book",
        at: start.addingTimeInterval(86500),
    )
    #expect(safety.reason == .beforeRestore)
    #expect(try await store.source(for: safety, key: "book") == "unsaved today")
    #expect(try await store
        .preserveBeforeRestore("unsaved today", key: "book", at: start.addingTimeInterval(86501)) == safety)
    #expect(try await store.revisions(for: "book").count == 3)
    let payload = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects
        .compactMap { $0 as? URL }.first { $0.lastPathComponent == "\(safety.id).typ" })
    try Data("corrupted".utf8).write(to: payload)
    await #expect(throws: HistoryError.damaged) { try await store.source(for: safety, key: "book") }
    let repaired = try await store.preserveBeforeRestore(
        "unsaved today",
        key: "book",
        at: start.addingTimeInterval(86502),
    )
    #expect(repaired.id != safety.id)
    #expect(try await store.source(for: repaired, key: "book") == "unsaved today")
    let repairedPayload = payload.deletingLastPathComponent().appendingPathComponent("\(repaired.id).typ")
    try FileManager.default.removeItem(at: repairedPayload)
    let recreated = try await store.preserveBeforeRestore(
        "unsaved today",
        key: "book",
        at: start.addingTimeInterval(86503),
    )
    #expect(recreated.id != repaired.id)
    #expect(try await store.source(for: recreated, key: "book") == "unsaved today")
}

@Test func historyWriteFailureDoesNotPublishAnIncompleteSnapshot() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("history-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("blocked".utf8).write(to: root)
    let store = DocumentHistory(root: root)
    await #expect(throws: (any Error).self) {
        try await store.recordEdit(key: "book", previous: "original", current: "changed", at: Date(), interval: .hourly)
    }
    try FileManager.default.removeItem(at: root)
    #expect(try await store.revisions(for: "book").isEmpty)
    try await store.recordEdit(key: "book", previous: "original", current: "changed", at: Date(), interval: .hourly)
    #expect(try await store.revisions(for: "book").count == 1)
}

@Test func wholeBookHistoryComparisonIsBoundedAndPreservesUnicode() {
    let book = (1 ... 30000).map { "Line \($0): 中文 and equations α 😀" }.joined(separator: "\n")
    let changed = book.replacingOccurrences(of: "Line 28000:", with: "Edited line 28000:")
    let comparison = HistoryComparison(before: book, after: changed)
    #expect(comparison.firstLine == 27998)
    #expect(comparison.before.contains("Line 28000"))
    #expect(comparison.after.contains("Edited line 28000"))
    #expect(comparison.abbreviated)
    #expect(comparison.before.utf8.count < 1000)
    let large = HistoryComparison(before: book, after: String(repeating: "汉字😀\n", count: 40000))
    #expect(large.before.utf8.count <= 24000)
    #expect(large.after.utf8.count <= 24000)
    #expect(large.abbreviated)
    #expect(HistoryComparison(before: book, after: book).identical)
    #expect(HistoryComparison(before: "", after: "x").after.contains("x"))
}

@Test func historyHighlightsSeparateIndependentEditsAndKeepContextUnmarked() {
    let before = "= Notes\n\nHello world.\n\nKeep this paragraph.\n\nDelete me.\n"
    let after = "= Notes\n\nHello brave world.\n\nKeep this paragraph.\n\n"
    let comparison = HistoryComparison(before: before, after: after)
    let added = comparison.addedRanges.map { (comparison.after as NSString).substring(with: $0) }.joined()
    let removed = comparison.removedRanges.map { (comparison.before as NSString).substring(with: $0) }.joined()
    #expect(added == "brave ")
    #expect(removed.contains("Delete me."))
    #expect(!removed.contains("Keep"))
    #expect(!removed.contains("Hello"))
    #expect(comparison.before.contains("Keep this paragraph."))
    #expect(comparison.after.contains("Keep this paragraph."))
}

@Test func historyHighlightsTypstPunctuationAndWholeUnicodeCharacters() {
    let before = "#set text(size: 11pt)\n$alpha + beta$\n\n思考😀Cafe\u{301}👨‍👩‍👧‍👦"
    let after = "#set text(size: 12pt)\n$alpha - beta$\n\n思考😀Café👩‍💻"
    let comparison = HistoryComparison(before: before, after: after)
    let removed = comparison.removedRanges.map { (comparison.before as NSString).substring(with: $0) }.joined()
    let added = comparison.addedRanges.map { (comparison.after as NSString).substring(with: $0) }.joined()
    #expect(removed.contains("1"))
    #expect(removed.contains("+"))
    #expect(added.contains("2"))
    #expect(added.contains("-"))
    #expect(removed.contains("👨‍👩‍👧‍👦"))
    #expect(added.contains("👩‍💻"))
    #expect(!removed.contains("思考😀"))
    #expect(!added.contains("思考😀"))
    for range in comparison.removedRanges {
        #expect(Range(range, in: comparison.before) != nil)
    }
    for range in comparison.addedRanges {
        #expect(Range(range, in: comparison.after) != nil)
    }
}

@Test func historyHighlightsBoundExtensiveRewritesAndEmptyDocuments() {
    let start = ContinuousClock.now
    let rewritten = HistoryComparison(
        before: String(repeating: "old content\n", count: 40000),
        after: String(repeating: "new words\n", count: 40000),
    )
    #expect(rewritten.abbreviated)
    #expect(rewritten.removedRanges.count == 1)
    #expect(rewritten.addedRanges.count == 1)
    let longLine = HistoryComparison(
        before: String(repeating: "a", count: 24000),
        after: String(repeating: "b", count: 24000),
    )
    #expect(longLine.removedRanges.count == 1)
    #expect(longLine.addedRanges.count == 1)
    #expect(HistoryComparison(before: "", after: "😀").removedRanges.isEmpty)
    #expect(HistoryComparison(before: "😀", after: "").addedRanges.isEmpty)
    // A rewrite must take the bounded path, not diff tens of thousands of tokens.
    #expect(start.duration(to: .now) < .seconds(2))
}
