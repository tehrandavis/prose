import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 5 step C: the citation picker in the command panel (acceptance tests
/// 5 to 7 of `docs/plans/2026-11-09-citations.md`) and the citation-heavy
/// measurement the step A outcome left open, on the real window, Tinymist and
/// block engine.
extension WritingFlowTests {
    /// Acceptance test 5: search by author, year, title word and key; Return
    /// cites at the caret as one undoable edit, with the spacing rules; math
    /// and raw text refuse with the existing message.
    @Test func citationPickerFindsEntriesAndCitesAtTheCaret() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeCitingPaper(in: app.root)
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let original = editor.string

        try await openCitationPicker(app)
        #expect(app.workspace.bibliographyIndex.isLinked)
        #expect(app.workspace.citationResults.map(\.key) == ["a", "b", "smith2019"])
        for query in ["jon", "Smith", "2019", "quantum", "smith20", "grav 2019"] {
            app.workspace.query = query
            #expect(app.workspace.citationResults.first?.key == "smith2019", "\(query)")
        }
        app.workspace.query = "nothing like it"
        #expect(app.workspace.citationResults.isEmpty)
        // Down and Up move within the results.
        app.workspace.query = ""
        #expect(app.workspace.handlePaletteKey(app.key("", code: 125)))
        #expect(app.workspace.highlightedCitation?.key == "b")
        #expect(app.workspace.handlePaletteKey(app.key("", code: 126)))
        #expect(app.workspace.highlightedCitation?.key == "a")
        app.workspace.closePalette()

        // After a word: a space first.
        let claim = (original as NSString).range(of: "The second claim").location + 16
        try await cite(app, at: claim, query: "jon")
        let cited = (original as NSString).replacingCharacters(
            in: NSRange(location: claim, length: 0),
            with: " @smith2019",
        )
        try await app.wait { app.workspace.text == cited }
        #expect(editor.string == cited)
        #expect(!app.workspace.paletteOpen)
        #expect(editor.selectedRange() == NSRange(location: claim + 11, length: 0))
        expectPlainStorage(editor)
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == original }
        #expect(editor.string == original)

        // After an existing citation and its space: no second space, one after.
        let afterA = (original as NSString).range(of: "See @a ").location + 7
        try await cite(app, at: afterA, query: "bee")
        let both = (original as NSString).replacingCharacters(in: NSRange(location: afterA, length: 0), with: "@b ")
        try await app.wait { app.workspace.text == both }
        #expect(both.contains("See @a @b for the method."))
        expectPlainStorage(editor)
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == original }

        // In math and in raw text the command is refused and nothing changes.
        let refusal = "This command works in body text. Move out of equations, code or comments and try again. "
            + "Your text is unchanged."
        for place in ["x^2", "raw text"] {
            let offset = (original as NSString).range(of: place).location + 1
            try await cite(app, at: offset, query: "smith")
            try await app.wait { app.workspace.commandError != nil }
            #expect(app.workspace.commandError == refusal, "\(place)")
            #expect(app.workspace.paletteOpen && app.workspace.citationPicker != nil)
            #expect(editor.string == original && app.workspace.text == original)
            // Esc goes back: to the group, then the panel closes.
            #expect(app.workspace.handlePaletteKey(app.key("\u{1b}", code: 53)))
            #expect(app.workspace.citationPicker == nil && app.workspace.paletteGroup == "references")
            app.workspace.closePalette()
        }
        expectPlainStorage(editor)
    }

    /// Acceptance test 6, first part: `⌥Return` asks for a page or section and
    /// inserts it inside the brackets exactly as typed.
    @Test func optionReturnCitesWithAPageOrSection() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeCitingPaper(in: app.root)
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let original = editor.string
        let claim = (original as NSString).range(of: "The second claim").location + 16
        editor.setSelectedRange(NSRange(location: claim, length: 0))
        try await openCitationPicker(app)
        app.workspace.query = "quantum"
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36, modifiers: .option)))
        let entry = try #require(app.workspace.citationResults.first)
        #expect(app.workspace.citationPicker?.stage == .supplement(entry))
        // Esc returns to the list, keeping the query.
        #expect(app.workspace.handlePaletteKey(app.key("\u{1b}", code: 53)))
        #expect(app.workspace.citationPicker?.stage == .list && app.workspace.query == "quantum")
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36, modifiers: .option)))
        await app.layout()
        app.workspace.citationPicker?.supplement = "p. 4"
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        let expected = (original as NSString).replacingCharacters(
            in: NSRange(location: claim, length: 0),
            with: " @smith2019[p. 4]",
        )
        try await app.wait { app.workspace.text == expected }
        #expect(editor.string == expected)
        expectPlainStorage(editor)
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == original }
        #expect(editor.string == original)

        // A bibliography file changed on disk reloads the index, with no
        // edit and without opening the picker again.
        let reloads = app.workspace.bibliographyReloads
        try Data((citingBibliography + "@book{c, title={Sea Book}, author={Sea, Cy}, year={2022}}\n").utf8)
            .write(to: paper.root.appendingPathComponent("refs.bib"))
        try await app.wait { app.workspace.bibliographyIndex.entries.contains { $0.key == "c" } }
        #expect(app.workspace.bibliographyReloads > reloads)
        #expect(editor.string == original)
        expectPlainStorage(editor)
    }

    /// Acceptance test 6, second part: in a document with no `#bibliography`
    /// call whose project has an unlinked `refs.bib`, the first citation
    /// offers to add the call. Accepting adds it at the end of the main file
    /// as its own undoable edit; declining inserts only the citation and is
    /// not asked again. A YAML file that is not a bibliography shows no
    /// problem.
    @Test func citingWithoutABibliographyOffersToAddTheCall() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let root = app.root.appendingPathComponent("Draft")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = "= Draft\n\nA first claim.\n"
        try Data(original.utf8).write(to: root.appendingPathComponent("main.typ"))
        try Data(citingBibliography.utf8).write(to: root.appendingPathComponent("refs.bib"))
        try Data("title: Notes\nitems:\n  - one\n  - two\n".utf8).write(to: root.appendingPathComponent("notes.yml"))
        #expect(app.workspace.openFolder(root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        #expect(app.workspace.compilationURL.standardizedFileURL == app.workspace.documentURL.standardizedFileURL)
        let claim = (original as NSString).range(of: "claim").location + 5

        try await cite(app, at: claim, query: "smith", waitForInsertion: false)
        #expect(!app.workspace.bibliographyIndex.isLinked)
        #expect(app.workspace.citationProblems.isEmpty, "\(app.workspace.citationProblems)")
        let entry = try #require(app.workspace.bibliographyIndex.entries.first { $0.key == "smith2019" })
        #expect(app.workspace.citationPicker?.stage == .linkBibliography(entry, supplement: nil, path: "refs.bib"))
        #expect(editor.string == original)
        await app.layout()
        #expect(app.workspace.citationPickerEntry == entry)
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        let call = try TypstInsertion.make("bibliography", values: ["path": "refs.bib"]).text
        #expect(call == #"#bibliography("refs.bib", style: "apa")"#, "The offer writes APA")
        let cited = "= Draft\n\nA first claim @smith2019.\n"
        try await app.wait { app.workspace.text == cited + "\n" + call + "\n" }
        #expect(editor.string == cited + "\n" + call + "\n")
        #expect(editor.selectedRange() == NSRange(location: claim + 11, length: 0))
        expectPlainStorage(editor)
        // The edit that added the call reloads the index: the file is linked.
        try await app.wait { app.workspace.bibliographyIndex.isLinked }
        // Two edits: the call, then the citation.
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == cited }
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == original }
        #expect(editor.string == original)

        // Declining inserts only the citation, and the next citation asks
        // nothing.
        try await cite(app, at: claim, query: "smith", waitForInsertion: false)
        #expect(app.workspace.citationPicker?.stage == .linkBibliography(entry, supplement: nil, path: "refs.bib"))
        #expect(app.workspace.handlePaletteKey(app.key("n", code: 45)))
        try await app.wait { app.workspace.text == cited }
        let second = (cited as NSString).range(of: "@smith2019").location + 10
        try await cite(app, at: second, query: "bee")
        try await app.wait { app.workspace.text == "= Draft\n\nA first claim @smith2019 @b.\n" }
        #expect(editor.string == app.workspace.text)
        expectPlainStorage(editor)
    }

    /// With no bibliography file in the project, the picker says so and its
    /// action opens the `bibliography` command.
    @Test func citationPickerWithoutBibliographyFilesOffersTheBibliographyCommand() async throws {
        let app = try WritingFixture(text: "= Loose file\n\nNo sources yet.\n", startService: false)
        defer { app.close() }
        try await openCitationPicker(app)
        #expect(app.workspace.bibliographyIndex.contents.files.isEmpty)
        #expect(app.workspace.citationResults.isEmpty && app.workspace.highlightedCitation == nil)
        // Return with nothing to cite does nothing.
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        #expect(app.workspace.citationPicker?.stage == .list)
        app.workspace.createBibliographyFromPicker()
        #expect(app.workspace.citationPicker == nil)
        #expect(app.workspace.activeCommand?.id == "bibliography")
        await app.layout()
        app.workspace.closePalette()
        try expectPlainStorage(#require(app.workspace.editor))
    }

    /// Acceptance test 7: in Writing mode the block with the new citation
    /// shows its final text, with no `??`, within 2 s, after the refresh the
    /// insertion asks for at once. It never shows `??` on the way.
    @Test func writingModeShowsANewCitationAfterTheImmediateRefresh() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let paper = try makeCitingPaper(in: app.root)
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let model = try await enterWritingMode(app)
        try await app.wait { citedText(model, holding: "See @a", in: editor).contains("[1]") }
        let original = editor.string
        let claim = (original as NSString).range(of: "The second claim").location + 16
        let refreshes = model.refreshReplies

        try await cite(app, at: claim, query: "bee", waitForInsertion: false)
        let expected = (original as NSString).replacingCharacters(in: NSRange(location: claim, length: 0), with: " @b")
        try await app.wait { app.workspace.text == expected }
        let start = ContinuousClock.now
        // Leave the block, so it may render.
        let raw = (editor.string as NSString).range(of: "raw text").location + 2
        editor.setSelectedRange(NSRange(location: raw, length: 0))
        editor.prepareForPointerInteraction()
        var questionMarks = false
        func shown() -> String {
            let text = citedText(model, holding: "The second claim", in: editor)
            questionMarks = questionMarks || text.contains("??")
            return text
        }
        while !shown().contains("[2]"), ContinuousClock.now - start < .seconds(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = ContinuousClock.now - start
        print("PROSE CITATION: the new citation showed its final text after \(elapsed)")
        #expect(shown().contains("[2]"), "The new citation did not show [2] within 2 s: \(shown())")
        #expect(!questionMarks, "The citing block showed ??")
        #expect(model.refreshReplies > refreshes)
        #expect(editor.string == expected)
        expectPlainStorage(editor)
    }

    /// The open item from step A: a 1,000-entry `.bib` and 40 paragraphs
    /// with 300 citations, in Writing mode. Records the first entry, the
    /// render of a citing block (median, p95) and typing in a citing block.
    /// Prints the numbers; asserts only that the blocks render their
    /// citations.
    @Test func citationHeavyDocumentInWritingMode() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let root = app.root.appendingPathComponent("Thesis")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.typ")
        try Data(heavyBibliography(entries: 1000).utf8).write(to: root.appendingPathComponent("refs.bib"))
        try Data(heavyDocument(paragraphs: 40, citations: 300).utf8).write(to: main)
        #expect(app.workspace.openFolder(root))
        await app.layout()
        let editor = try #require(app.workspace.editor)

        // First entry: from the switch to the first renders in view.
        let entryStart = ContinuousClock.now
        app.workspace.setMode(.writing)
        try await app.wait { editor.writing.enteredWithRenders != nil }
        let firstEntry = ContinuousClock.now - entryStart
        let enteredWithRenders = editor.writing.enteredWithRenders == true
        let model = try #require(editor.writing.model)
        await model.idle()
        let renderer = try #require(app.workspace.writingEngine?.renderer)

        // Citing blocks, rendered cold at a width the view does not use.
        let file = main.standardizedFileURL
        let source = editor.string as NSString
        let citing = try await renderer.blocks(in: file).filter { source.substring(with: $0.range).contains("@ref") }
        #expect(citing.count == 40)
        var renders: [Double] = []
        for block in citing {
            let start = ContinuousClock.now
            let result = await renderer.render(
                block.range,
                in: file,
                width: 433,
                options: RenderOptions(bitmapScale: 2),
            )
            renders.append(milliseconds(ContinuousClock.now - start))
            let text = try result.get().text
            #expect(text.contains("[") && !text.contains("??"), "\(text.prefix(120))")
        }

        // Typing in a citing paragraph, as the book benchmark types.
        let target = source.range(of: "Paragraph 20 ").location + 13
        app.workspace.jump(to: target)
        await model.idle()
        await app.layout()
        var typing: [Double] = []
        for character in "Smooth typing in a citing block." {
            let start = ContinuousClock.now
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            typing.append(milliseconds(ContinuousClock.now - start))
            try await Task.sleep(for: .milliseconds(25))
        }
        await model.idle()
        let sortedRenders = renders.sorted(), sortedTyping = typing.sorted()
        let report = String(
            format: "PROSE CITATIONS: 1000 entries, 40 paragraphs, 300 citations; first entry %.0f ms (with renders: %@); "
                + "citing block render median %.1f ms, p95 %.1f ms, max %.1f ms; typing median %.2f ms, p95 %.2f ms",
            milliseconds(firstEntry), String(enteredWithRenders),
            percentile(sortedRenders, 0.5), percentile(sortedRenders, 0.95), sortedRenders.last ?? 0,
            percentile(sortedTyping, 0.5), percentile(sortedTyping, 0.95),
        )
        print(report)
        expectPlainStorage(editor)
    }
}

// MARK: - Helpers

private let citingBibliography = """
@book{a, title={Old Title}, author={Writer, Ann}, year={2020}}
@book{b, title={Bee Book}, author={Bee, Bob}, year={2021}}
@article{smith2019, title={Quantum Gravity Notes}, author={Smith, Jane and Jones, Tom},
  journal={Journal of Notes}, year={2019}}

"""

private struct CitingPaper {
    let root: URL
    let main: URL
}

/// `main.typ` cites `a`, holds math and raw text, and names `refs.bib`, which
/// has `a`, `b` and `smith2019`.
@MainActor
private func makeCitingPaper(in folder: URL) throws -> CitingPaper {
    let root = folder.appendingPathComponent("Paper")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let main = root.appendingPathComponent("main.typ")
    let source = """
    = Paper

    See @a for the method.

    The second claim.

    $ x^2 + y^2 $

    ```
    raw text
    ```

    #bibliography("refs.bib")

    """
    try Data(source.utf8).write(to: main)
    try Data(citingBibliography.utf8).write(to: root.appendingPathComponent("refs.bib"))
    return CitingPaper(root: root, main: main.standardizedFileURL)
}

/// Opens the panel and the picker by keys (`⌘J`, then `R`, then `S`) and
/// waits for the index.
@MainActor
private func openCitationPicker(_ app: WritingFixture) async throws {
    if !app.workspace.paletteOpen {
        app.workspace.togglePalette()
    }
    #expect(app.workspace.handlePaletteKey(app.key("r", code: 15)))
    #expect(app.workspace.handlePaletteKey(app.key("s", code: 1)))
    #expect(app.workspace.citationPicker != nil)
    try await app.wait { app.workspace.citationPicker?.loading == false }
    await app.layout()
}

/// Puts the caret at `offset`, opens the picker, searches and presses Return.
@MainActor
private func cite(
    _ app: WritingFixture,
    at offset: Int,
    query: String,
    waitForInsertion: Bool = true,
) async throws {
    let editor = try #require(app.workspace.editor)
    editor.setSelectedRange(NSRange(location: offset, length: 0))
    try await openCitationPicker(app)
    app.workspace.query = query
    #expect(!app.workspace.citationResults.isEmpty, "Nothing found for \(query)")
    let version = app.workspace.revision
    #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
    if waitForInsertion {
        try await app.wait {
            app.workspace.revision != version || app.workspace.commandError != nil
        }
    }
}

/// The text the rendered block whose source starts with `prefix` shows, or ""
/// while it draws source.
@MainActor
private func citedText(_ model: WritingLayout, holding prefix: String, in editor: ManuscriptTextView) -> String {
    let source = editor.string as NSString
    guard let index = model.blocks.firstIndex(where: { source.substring(with: $0.range).hasPrefix(prefix) }),
          case let .rendered(rendering) = model.state(ofBlockAt: index)
    else {
        return ""
    }
    return rendering.text
}

/// `count` BibLaTeX entries, `ref0001` and on, with two authors, a title, a
/// journal and a year each.
private func heavyBibliography(entries count: Int) -> String {
    (1 ... count).map { index in
        let key = String(format: "ref%04d", index)
        return """
        @article{\(key),
          author = {Family\(index), Given and Other\(index), Second},
          title = {A study of topic \(index) and its consequences for practice},
          journal = {Journal of Studies \(index % 40)},
          year = {\(1980 + index % 45)},
          volume = {\(index % 30 + 1)},
          pages = {\(index)--\(index + 12)},
        }

        """
    }.joined()
}

/// `paragraphs` paragraphs citing `citations` keys spread through them, then
/// the bibliography call.
private func heavyDocument(paragraphs: Int, citations: Int) -> String {
    var body = "#set heading(numbering: \"1.\")\n\n= Chapter\n\n"
    for paragraph in 0 ..< paragraphs {
        var sentence = "Paragraph \(paragraph) opens with a claim that the literature supports"
        for citation in stride(from: paragraph, to: citations, by: paragraphs) {
            let key = String(format: "ref%04d", citation * 3 % 1000 + 1)
            sentence += " in part @\(key), and further"
        }
        body += sentence + " until it ends.\n\n"
    }
    return body + "#bibliography(\"refs.bib\")\n"
}

private func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}

private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else {
        return 0
    }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
}
