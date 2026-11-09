import AppKit
import Foundation
import PDFKit
@testable import ProseApp
import ProseCore
import Testing

/// Phase 5 step A: a bibliography changed on disk reaches Writing mode and the
/// PDF with no edit (acceptance tests 1 to 3 of
/// `docs/plans/2026-11-09-citations.md`), on the real window, engines and
/// FSEvents.
extension WritingFlowTests {
    /// Acceptance test 1, the file written in place (same inode).
    @Test func writingModeShowsABibliographyRewrittenInPlace() async throws {
        try await expectWritingModeFollowsTheBibliography(.inPlace)
    }

    /// Acceptance test 1, the file replaced by a rename (a new inode), as Better
    /// BibTeX may write it.
    @Test func writingModeShowsABibliographyReplacedByARename() async throws {
        try await expectWritingModeFollowsTheBibliography(.replace)
    }

    /// Acceptance test 2: Tinymist reads the changed file by itself. An export
    /// after each change, with no edit in between, holds the new texts: in
    /// place, then replaced by a rename, then in place again (its watcher still
    /// follows the file after the rename).
    @Test func pdfExportFollowsTheBibliographyOnDisk() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makePaper(in: app.root, citing: "See @a for the method.\n")
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let first = try await app.exportedText(containing: ["Old Title"])
        #expect(first.contains("Old Title"))

        // Cite `b`, which the file does not have yet: the compile fails.
        let editor = try #require(app.workspace.editor)
        let end = (editor.string as NSString).range(of: "#bibliography").location
        editor.insertText("And @b agrees.\n\n", replacementRange: NSRange(location: end, length: 0))
        try await app.wait { app.workspace.diagnostics.contains { $0.message.contains("<b>") } }
        let text = app.workspace.text
        let rounds: [(BibliographyWrite, String, String)] = [
            (.inPlace, "New Title", "Bee Book"),
            (.replace, "Renamed Title", "Bee Book Two"),
            (.inPlace, "Final Title", "Bee Book Three"),
        ]
        for (kind, title, bee) in rounds {
            let inode = try fileNumber(paper.bibliography)
            try rewrite(paper.bibliography, bibliography(a: title, b: bee), kind)
            #expect(try (fileNumber(paper.bibliography) == inode) == (kind == .inPlace))
            let start = ContinuousClock.now
            let exported = try await exportedTextAfterChange(app, containing: [title, bee])
            print("Bibliography reload (\(kind)) reached the PDF in \(ContinuousClock.now - start)")
            #expect(exported.contains(title), "\(kind): the export kept the old title")
            #expect(exported.contains(bee), "\(kind): the export lacks the new entry")
            #expect(app.workspace.text == text, "The document was edited")
        }
    }

    /// Acceptance test 3: ten writes within 200 ms cause one refresh; a change
    /// to a file the document does not read causes none and re-renders no block.
    @Test func aBurstOfWritesRefreshesOnceAndUnreadFilesRefreshNothing() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let paper = try makePaper(in: app.root, citing: "See @a for the method.\n")
        try Data("Notes the document never reads.\n".utf8).write(to: paper.root.appendingPathComponent("notes.txt"))
        #expect(app.workspace.openFolder(paper.root))
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let model = try await enterWritingMode(app)
        let renderer = try #require(app.workspace.writingEngine?.renderer)
        try await app.wait { shownText(model, holding: "#bibliography", in: editor).contains("Old Title") }
        await model.idle()

        let reports = app.workspace.writingChangeReports
        let refreshes = app.workspace.writingExternalRefreshes
        let replies = model.refreshReplies
        for index in 1 ... 10 {
            try rewrite(paper.bibliography, bibliography(a: "Burst Title \(index)", b: "Bee"), .inPlace)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await app.wait { shownText(model, holding: "#bibliography", in: editor).contains("Burst Title 10") }
        // Longer than the FSEvents latency and the pause together.
        try await Task.sleep(for: .milliseconds(800))
        await model.idle()
        #expect(app.workspace.writingChangeReports == reports + 1)
        #expect(app.workspace.writingExternalRefreshes == refreshes + 1)
        #expect(model.refreshReplies == replies + 1)

        // A file the document does not read: reported, but nothing refreshes
        // and no block renders again.
        let renders = model.renderReplies
        let stats = await renderer.cacheStats()
        try Data("Changed notes.\n".utf8).write(to: paper.root.appendingPathComponent("notes.txt"))
        try await app.wait { app.workspace.writingChangeReports == reports + 2 }
        try await Task.sleep(for: .milliseconds(300))
        await model.idle()
        #expect(app.workspace.writingExternalRefreshes == refreshes + 1)
        #expect(model.refreshReplies == replies + 1)
        #expect(model.renderReplies == renders)
        let after = await renderer.cacheStats()
        #expect(after.misses == stats.misses && after.hits == stats.hits)
        expectPlainStorage(editor)
    }

    private func expectWritingModeFollowsTheBibliography(_ kind: BibliographyWrite) async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        // `b` is cited but not in the file yet.
        let paper = try makePaper(in: app.root, citing: "See @a for the method.\n\nAnd @b agrees.\n")
        #expect(app.workspace.openFolder(paper.root))
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let model = try await enterWritingMode(app)
        try await app.wait { shownText(model, holding: "And @b", in: editor).contains("agrees") }
        #expect(!shownText(model, holding: "#bibliography", in: editor).contains("Old Title"))
        let text = editor.string
        let undo = editor.undoManager?.canUndo

        let inode = try fileNumber(paper.bibliography)
        let start = ContinuousClock.now
        try rewrite(paper.bibliography, bibliography(a: "New Title", b: "Bee Book"), kind)
        #expect(try (fileNumber(paper.bibliography) == inode) == (kind == .inPlace))
        func current() -> Bool {
            let list = shownText(model, holding: "#bibliography", in: editor)
            return list.contains("New Title") && list.contains("Bee Book")
                && shownText(model, holding: "And @b", in: editor).contains("[2]")
                && shownText(model, holding: "See @a", in: editor).contains("[1]")
        }
        while !current(), ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = ContinuousClock.now - start
        #expect(current(), "\(kind): Writing mode did not show the new entries within 2 s")
        print("Bibliography reload (\(kind)) reached Writing mode in \(elapsed)")
        #expect(editor.string == text && editor.undoManager?.canUndo == undo, "The document was edited")
        #expect(!model.stale)
        expectPlainStorage(editor)
    }
}

// MARK: - Fixture

private enum BibliographyWrite {
    /// Truncate and write the same file.
    case inPlace
    /// Write a temporary file beside it and rename it over the file.
    case replace
}

private struct Paper {
    let root: URL
    let main: URL
    let bibliography: URL
}

/// A project folder with `main.typ`, which cites `body`, and `refs.bib` with
/// only the entry `a`.
@MainActor
private func makePaper(in folder: URL, citing body: String) throws -> Paper {
    let root = folder.appendingPathComponent("Paper")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let main = root.appendingPathComponent("main.typ")
    let refs = root.appendingPathComponent("refs.bib")
    try Data("= Paper\n\n\(body)\n#bibliography(\"refs.bib\")\n".utf8).write(to: main)
    try Data("@book{a, title={Old Title}, author={Writer, Ann}, year={2020}}\n".utf8).write(to: refs)
    return Paper(root: root, main: main.standardizedFileURL, bibliography: refs)
}

private func bibliography(a title: String, b bee: String) -> String {
    "@book{a, title={\(title)}, author={Writer, Ann}, year={2020}}\n"
        + "@book{b, title={\(bee)}, author={Bee, Bob}, year={2021}}\n"
}

private func rewrite(_ url: URL, _ text: String, _ kind: BibliographyWrite) throws {
    switch kind {
    case .inPlace:
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    case .replace:
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func fileNumber(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1
}

/// The text the rendered block whose source starts with `prefix` shows, or ""
/// while it draws source.
@MainActor
private func shownText(_ model: WritingLayout, holding prefix: String, in editor: ManuscriptTextView) -> String {
    let source = editor.string as NSString
    guard let index = model.blocks.firstIndex(where: { source.substring(with: $0.range).hasPrefix(prefix) }) else {
        return ""
    }
    guard case let .rendered(rendering) = model.state(ofBlockAt: index) else {
        return ""
    }
    return rendering.text
}

/// Exports until the PDF holds `expected`, for at most 10 s. No edit is made,
/// so only Tinymist's own reading of the file can bring the new text.
@MainActor
private func exportedTextAfterChange(_ app: WritingFixture, containing expected: [String]) async throws -> String {
    let destination = app.root.appendingPathComponent("export-\(UUID().uuidString).pdf")
    let deadline = ContinuousClock.now + .seconds(10)
    var text = ""
    repeat {
        let exported: Void? = try? await app.workspace.exportPDF(to: destination)
        if exported != nil {
            text = PDFDocument(url: destination)?.string ?? ""
            if expected.allSatisfy(text.contains) {
                break
            }
        }
        try await Task.sleep(for: .milliseconds(200))
    } while ContinuousClock.now < deadline
    return text
}
