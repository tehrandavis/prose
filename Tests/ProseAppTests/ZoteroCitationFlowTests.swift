import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 5 step E: the citation picker's Zotero tab (acceptance tests 8 and 9
/// of `docs/plans/2026-11-09-citations.md`), on the real window, Tinymist and
/// block engine. Zotero is never contacted: the workspace gets a scripted
/// source, or a client pointed at a loopback port nothing listens on.
extension WritingFlowTests {
    /// Acceptance test 8: a search returns items; choosing one whose key is
    /// already in `refs.bib` inserts only the citation and changes no file.
    @Test func zoteroItemAlreadyInTheProjectInsertsOnlyTheCitation() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeZoteroPaper(in: app.root)
        let source = ScriptedZoteroSource(items: [
            zoteroItem("smith2019", item: "SMITHKEY", family: "Smith", title: "Quantum Gravity Notes", year: 2019),
            zoteroItem("smithson2020", item: "SMITHSON", family: "Smithson", title: "Other Notes", year: 2020),
        ])
        app.workspace.zoteroSource = source
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let original = editor.string
        let bibliography = try Data(contentsOf: paper.bibliography)

        try await openZoteroTab(app)
        // One or two characters search nothing.
        app.workspace.query = "sm"
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.workspace.zotero.results.isEmpty && app.workspace.zotero.searchedQuery == nil)
        #expect(await source.searches.isEmpty)
        app.workspace.query = "smith 2019"
        try await app.wait { app.workspace.zotero.searchedQuery == "smith 2019" }
        #expect(await source.searches == ["smith"])
        #expect(app.workspace.zotero.results.map(\.item.key) == ["smith2019"])
        #expect(app.workspace.zotero.results.first?.inProject == true)
        await app.layout()

        let claim = (original as NSString).range(of: "The second claim").location + 16
        editor.setSelectedRange(NSRange(location: claim, length: 0))
        let version = app.workspace.revision
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        try await app.wait { app.workspace.revision != version || app.workspace.commandError != nil }
        let cited = (original as NSString).replacingCharacters(
            in: NSRange(location: claim, length: 0),
            with: " @smith2019",
        )
        try await app.wait { app.workspace.text == cited }
        #expect(editor.string == cited)
        #expect(!app.workspace.paletteOpen)
        #expect(try Data(contentsOf: paper.bibliography) == bibliography)
        #expect(!FileManager.default.fileExists(atPath: paper.prose.path))
        #expect(await source.exports.isEmpty)
        #expect(app.workspace.messageAction == nil)
        expectPlainStorage(editor)
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == original }
    }

    /// Acceptance test 9: a new item goes into `references-prose.bib`, which
    /// joins the `#bibliography` call as an array with its other arguments
    /// kept, and the document compiles. When `refs.bib` then gains the key on
    /// disk, the copy leaves `references-prose.bib` and it still compiles.
    @Test func zoteroItemNewToTheProjectGoesIntoReferencesProseUntilTheExportHasIt() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeZoteroPaper(in: app.root)
        let source = ScriptedZoteroSource(items: [newItem], exports: [newItem.key: newEntry(title: "Quokka")])
        app.workspace.zoteroSource = source
        var opened: [URL] = []
        app.workspace.openExternalURL = { opened.append($0) }
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let original = editor.string
        let bibliography = try Data(contentsOf: paper.bibliography)

        try await openZoteroTab(app)
        app.workspace.query = "furmanek joint"
        try await app.wait { app.workspace.zotero.searchedQuery == "furmanek joint" }
        #expect(app.workspace.zotero.results.map(\.item.key) == [newItem.key])
        #expect(app.workspace.zotero.results.first?.inProject == false)
        let claim = (original as NSString).range(of: "The second claim").location + 16
        editor.setSelectedRange(NSRange(location: claim, length: 0))
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        let call = #"#bibliography(("refs.bib", "references-prose.bib"), style: "apa")"#
        try await app.wait { app.workspace.text.contains(call) || app.workspace.commandError != nil }
        #expect(app.workspace.commandError == nil)
        #expect(await source.exports == [[newItem.key]])
        let expected = (original as NSString)
            .replacingCharacters(in: NSRange(location: claim, length: 0), with: " @\(newItem.key)")
            .replacingOccurrences(of: #"#bibliography("refs.bib", style: "apa")"#, with: call)
        #expect(app.workspace.text == expected && editor.string == expected)
        // Only `references-prose.bib` was written, and nothing else.
        #expect(try Data(contentsOf: paper.bibliography) == bibliography)
        let prose = try String(contentsOf: paper.prose, encoding: .utf8)
        #expect(prose == newEntry(title: "Quokka").trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: paper.root.path).sorted()
            == ["main.typ", "references-prose.bib", "refs.bib"])
        // The confirmation line says the file change is not undone and offers
        // "Show in Zotero".
        let message = try #require(app.workspace.message)
        #expect(message.contains("references-prose.bib") && message.contains("not undone"))
        #expect(app.workspace.messageAction?.url.absoluteString == "zotero://select/library/items/NSPZRSQM")
        app.workspace.performMessageAction()
        #expect(opened.map(\.absoluteString) == ["zotero://select/library/items/NSPZRSQM"])
        expectPlainStorage(editor)

        // It compiles with the new entry and no duplicate key.
        let first = try await app.exportedText(containing: ["Quokka"])
        #expect(first.contains("Quokka"))
        #expect(!app.workspace.diagnostics.contains { $0.message.localizedCaseInsensitiveContains("duplicate") })

        // The next auto-export brings the key into `refs.bib`: Prose removes
        // its copy, leaves the file empty and keeps the array.
        let removed = app.workspace.proseDuplicatesRemoved
        let exportedFile = String(decoding: bibliography, as: UTF8.self) + "\n" + newEntry(title: "Wombat")
        try Data(exportedFile.utf8).write(to: paper.bibliography)
        // The file is rewritten off the main actor and counted after it, so
        // wait for both.
        try await app.wait {
            (try? String(contentsOf: paper.prose, encoding: .utf8))?.isEmpty == true
                && app.workspace.proseDuplicatesRemoved > removed
        }
        #expect(app.workspace.proseDuplicatesRemoved == removed + 1)
        #expect(try String(contentsOf: paper.bibliography, encoding: .utf8) == exportedFile)
        #expect(app.workspace.text == expected)
        let second = try await app.exportedText(containing: ["Wombat"])
        #expect(second.contains("Wombat") && !second.contains("Quokka"))
        #expect(!app.workspace.diagnostics.contains { $0.message.localizedCaseInsensitiveContains("duplicate") })

        // Two undos remove the call edit, then the citation; the file stays.
        editor.undoManager?.undo()
        try await app.wait { !app.workspace.text.contains("references-prose.bib") }
        #expect(app.workspace.text.contains(" @\(newItem.key)"))
        editor.undoManager?.undo()
        try await app.wait { app.workspace.text == original }
        #expect(FileManager.default.fileExists(atPath: paper.prose.path))
        expectPlainStorage(editor)
    }

    /// Acceptance test 9, last part: with nothing listening on Zotero's port,
    /// the tab says that Zotero is not running within 2.5 s, and the project
    /// tab still works.
    @Test func zoteroTabSaysZoteroIsNotRunning() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeZoteroPaper(in: app.root)
        app.workspace.zoteroSource = try HTTPZoteroSource(base: #require(URL(
            string: "http://127.0.0.1:\(closedLoopbackPort())",
        )))
        #expect(app.workspace.openFolder(paper.root))
        try await openCitationPanel(app)
        let start = ContinuousClock.now
        // `⌘2` reaches the picker before the menu's mode shortcut.
        #expect(app.window.performKeyEquivalent(with: app.key("2", code: 19, modifiers: .command)))
        #expect(app.workspace.citationPicker?.tab == .zotero)
        #expect(app.workspace.editorMode == .code)
        try await app.wait { app.workspace.zotero.availability == .notRunning }
        #expect(ContinuousClock.now - start < .milliseconds(2500))
        await app.layout()
        app.workspace.query = "smith"
        try await app.wait { app.workspace.zotero.searchedQuery == "smith" }
        #expect(app.workspace.zotero.results.isEmpty && app.workspace.zotero.availability == .notRunning)
        #expect(ContinuousClock.now - start < .milliseconds(2500))
        // Tab goes back to the project, whose entries still answer.
        #expect(app.workspace.handlePaletteKey(app.key("\t", code: 48)))
        #expect(app.workspace.citationPicker?.tab == .project)
        #expect(app.workspace.citationResults.map(\.key) == ["smith2019"])
        #expect(app.workspace.handlePaletteKey(app.key("2", code: 19, modifiers: .command)))
        #expect(app.workspace.handlePaletteKey(app.key("1", code: 18, modifiers: .command)))
        #expect(app.workspace.citationPicker?.tab == .project)
        await app.layout()
    }

    /// The link is chosen in the Zotero tab, stored with the project in
    /// `recent.json`, restored when the project reopens, and puts the linked
    /// collection's items first.
    @Test func zoteroLinkIsStoredWithTheProjectAndOrdersResults() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeZoteroPaper(in: app.root)
        try Data("".utf8).write(to: paper.prose)
        let source = ScriptedZoteroSource(
            items: [
                zoteroItem("Lee_2018_Walking", item: "LEEKEY", family: "Lee", title: "Walking together", year: 2018),
                zoteroItem("Kim_2020_Walking", item: "KIMKEY", family: "Kim", title: "Walking apart", year: 2020),
            ],
            collections: [
                ZoteroCollection(key: "P1", name: "Work"),
                ZoteroCollection(key: "C1", name: "Thesis", parent: "P1"),
            ],
            members: ["C1": ["KIMKEY"]],
        )
        app.workspace.zoteroSource = source
        #expect(app.workspace.openFolder(paper.root))
        try await openZoteroTab(app)
        app.workspace.query = "walking"
        try await app.wait { app.workspace.zotero.searchedQuery == "walking" }
        #expect(app.workspace.zotero.results.map(\.item.key) == ["Lee_2018_Walking", "Kim_2020_Walking"])

        app.workspace.beginZoteroLink()
        #expect(app.workspace.citationPicker?.stage == .zoteroLink)
        try await app.wait { !app.workspace.zotero.linkLoading }
        await app.layout()
        // `references-prose.bib` is never offered as the export.
        #expect(app.workspace.zotero.linkFiles == ["refs.bib"])
        #expect(app.workspace.zotero.linkCollections.map(\.path) == ["Work", "Work / Thesis"])
        app.workspace.zotero.linkCollection = "C1"
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        let link = ZoteroLink(bibliography: "refs.bib", collection: "C1", collectionName: "Work / Thesis")
        #expect(app.workspace.zoteroLink == link)
        #expect(app.workspace.projectStore.recent().first?.zotero == link)
        let recent = app.root.appendingPathComponent("State/Projects/recent.json")
        #expect(try String(contentsOf: recent, encoding: .utf8).contains("\"collection\" : \"C1\""))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paper.root.path).sorted()
            == ["main.typ", "references-prose.bib", "refs.bib"])

        // With the link, the collection's item comes first and is marked.
        try await app.wait { app.workspace.zotero.results.first?.item.key == "Kim_2020_Walking" }
        #expect(app.workspace.zotero.results.map(\.inCollection) == [true, false])
        #expect(await source.memberQueries == ["C1:walking"])
        await app.layout()
        app.workspace.closePalette()

        // Reopening the project restores the link.
        let other = app.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("= Other\n".utf8).write(to: other.appendingPathComponent("main.typ"))
        #expect(app.workspace.openFolder(other))
        #expect(app.workspace.zoteroLink == nil)
        let record = try #require(app.workspace.projectStore.recent().first { $0.path.hasSuffix("/Paper") })
        #expect(app.workspace.openRecentFolder(record))
        #expect(app.workspace.zoteroLink == link)

        app.workspace.unlinkZotero()
        #expect(app.workspace.zoteroLink == nil)
        #expect(app.workspace.projectStore.recent().first?.zotero == nil)
    }

    /// A new item in a document with no `#bibliography` call: the offer adds a
    /// call for `references-prose.bib`, and `⌥Return` takes a page first.
    @Test func zoteroItemInADocumentWithoutABibliographyOffersTheCall() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let paper = try makeZoteroPaper(in: app.root, call: false)
        let source = ScriptedZoteroSource(items: [newItem], exports: [newItem.key: newEntry(title: "Quokka")])
        app.workspace.zoteroSource = source
        #expect(app.workspace.openFolder(paper.root))
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let original = editor.string
        try await openZoteroTab(app)
        app.workspace.query = "furmanek"
        try await app.wait { app.workspace.zotero.searchedQuery == "furmanek" }
        let claim = (original as NSString).range(of: "The second claim").location + 16
        editor.setSelectedRange(NSRange(location: claim, length: 0))
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36, modifiers: .option)))
        guard case .supplement = app.workspace.citationPicker?.stage else {
            Issue.record("No supplement stage")
            return
        }
        app.workspace.citationPicker?.supplement = "p. 4"
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        try await app.wait {
            if case .linkBibliography = app.workspace.citationPicker?.stage {
                return true
            }
            return false
        }
        await app.layout()
        #expect(!FileManager.default.fileExists(atPath: paper.prose.path))
        #expect(app.workspace.handlePaletteKey(app.key("\r", code: 36)))
        try await app.wait { app.workspace.text.contains("#bibliography(\"references-prose.bib\"") }
        #expect(app.workspace.text.contains(" @\(newItem.key)[p. 4]"))
        #expect(try String(contentsOf: paper.prose, encoding: .utf8).contains("Quokka"))
        #expect(app.workspace.message?.contains("references-prose.bib") == true)
        expectPlainStorage(editor)
    }
}

// MARK: - Helpers

/// Answers like Better BibTeX and Zotero's local API, and records what it
/// was asked.
private actor ScriptedZoteroSource: ZoteroSource {
    private let items: [ZoteroItem]
    private let entries: [String: String]
    private let collectionList: [ZoteroCollection]
    private let members: [String: Set<String>]
    private(set) var searches: [String] = []
    private(set) var exports: [[String]] = []
    private(set) var memberQueries: [String] = []

    init(
        items: [ZoteroItem],
        exports: [String: String] = [:],
        collections: [ZoteroCollection] = [],
        members: [String: Set<String>] = [:],
    ) {
        self.items = items
        entries = exports
        collectionList = collections
        self.members = members
    }

    func ready() -> ZoteroStatus {
        ZoteroStatus(zotero: "10.0.8", betterBibTeX: "9.0.77")
    }

    /// One phrase, as Better BibTeX matches it.
    func search(_ text: String) -> [ZoteroItem] {
        searches.append(text)
        let phrase = text.lowercased()
        return items.filter { item in
            ([item.key, item.title ?? "", item.year.map(String.init) ?? ""] + item.authors.map(\.family))
                .contains { $0.lowercased().contains(phrase) }
        }
    }

    func export(_ keys: [String]) -> String {
        exports.append(keys)
        return keys.compactMap { entries[$0] }.joined(separator: "\n")
    }

    func collections() -> [ZoteroCollection] {
        collectionList
    }

    func collectionItems(_ collection: String, query: String) -> Set<String> {
        memberQueries.append("\(collection):\(query)")
        return members[collection] ?? []
    }

    func itemCollections(_ keys: [String]) -> [String: [ZoteroCollection]] {
        Dictionary(uniqueKeysWithValues: keys.map { key in
            let item = items.first { $0.key == key }
            return (key, collectionList.filter { members[$0.key]?.contains(item?.itemKey ?? "") == true })
        })
    }
}

private func zoteroItem(_ key: String, item: String, family: String, title: String, year: Int) -> ZoteroItem {
    ZoteroItem(
        key: key,
        itemKey: item,
        uri: "http://zotero.org/users/2104204/items/\(item)",
        title: title,
        authors: [.init(family: family, given: "A.")],
        year: year,
    )
}

private let newItem = ZoteroItem(
    key: "Furmanek_2019_Coordination",
    itemKey: "NSPZRSQM",
    uri: "http://zotero.org/users/2104204/items/NSPZRSQM",
    title: "Coordination dynamics of joint action",
    authors: [.init(family: "Furmanek", given: "Mariusz P."), .init(family: "Davis", given: "Tehran J.")],
    year: 2019,
    container: "Human Movement Science",
)

/// The entry as Better BibTeX exports it, with a distinctive title word.
private func newEntry(title word: String) -> String {
    """
    @article{Furmanek_2019_Coordination,
      title = {\(word) Coordination Dynamics},
      author = {Furmanek, Mariusz P. and Davis, Tehran J.},
      date = {2019},
      journaltitle = {Human Movement Science},
      volume = {64},
      pages = {1--12},
    }

    """
}

private struct ZoteroPaper {
    let root: URL
    let main: URL
    let bibliography: URL
    let prose: URL
}

/// `Paper/main.typ` cites `a` and names `refs.bib` with a style, unless
/// `call` is false; `refs.bib` has `a` and `smith2019`.
@MainActor
private func makeZoteroPaper(in folder: URL, call: Bool = true) throws -> ZoteroPaper {
    let root = folder.appendingPathComponent("Paper")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let main = root.appendingPathComponent("main.typ")
    var source = "= Paper\n\nSee @a for the method.\n\nThe second claim.\n"
    if call {
        source += "\n#bibliography(\"refs.bib\", style: \"apa\")\n"
    }
    try Data(source.utf8).write(to: main)
    let bibliography = root.appendingPathComponent("refs.bib")
    try Data("""
    @book{a, title={Old Title}, author={Writer, Ann}, year={2020}}
    @article{smith2019, title={Quantum Gravity Notes}, author={Smith, Jane and Jones, Tom},
      journal={Journal of Notes}, year={2019}}

    """.utf8).write(to: bibliography)
    return ZoteroPaper(
        root: root.standardizedFileURL,
        main: main.standardizedFileURL,
        bibliography: bibliography,
        prose: root.appendingPathComponent(ProseBibliography.fileName),
    )
}

/// Opens the panel and the picker by keys (`⌘J`, `R`, `S`) and waits for the
/// index.
@MainActor
private func openCitationPanel(_ app: WritingFixture) async throws {
    if !app.workspace.paletteOpen {
        app.workspace.togglePalette()
    }
    #expect(app.workspace.handlePaletteKey(app.key("r", code: 15)))
    #expect(app.workspace.handlePaletteKey(app.key("s", code: 1)))
    try await app.wait { app.workspace.citationPicker?.loading == false }
    await app.layout()
}

/// The picker on its Zotero tab (`⌘2`), with Zotero ready.
@MainActor
private func openZoteroTab(_ app: WritingFixture) async throws {
    try await openCitationPanel(app)
    #expect(app.workspace.handlePaletteKey(app.key("2", code: 19, modifiers: .command)))
    #expect(app.workspace.citationPicker?.tab == .zotero)
    try await app.wait { app.workspace.zotero.availability == .ready }
    await app.layout()
}

/// A loopback port nothing listens on. Port 1 needs root to listen on and
/// nothing does on macOS, so a connection is refused at once. (A port bound,
/// read and closed could be taken by a parallel test before the request.)
private func closedLoopbackPort() -> UInt16 {
    1
}
