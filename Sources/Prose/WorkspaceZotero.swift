import AppKit
import ProseCore

/// The citation picker's Zotero tab (citations note, step E): its state
/// while the panel is open.
struct ZoteroPane: Equatable {
    enum Availability: Equatable {
        case checking
        case ready
        case notRunning
        case betterBibTeXMissing
        case failed(String)
    }

    var availability = Availability.checking
    /// A search is waiting for its pause or for Zotero.
    var searching = false
    var results: [ZoteroSearch.Result] = []
    /// The query `results` answer, nil before the first search.
    var searchedQuery: String?
    /// An entry is being exported from Zotero.
    var exporting = false
    /// "Link to Zotero…": the choices and what is chosen.
    var linkFiles: [String] = []
    var linkCollections: [ZoteroCollectionChoice] = []
    var linkLoading = false
    var linkFile: String?
    var linkCollection: String?
}

struct ZoteroCollectionChoice: Equatable, Identifiable {
    let key: String
    /// The name after its parents' names.
    let path: String

    var id: String {
        key
    }
}

/// An item chosen from Zotero whose key no project file has: its BibLaTeX
/// entry goes into `references-prose.bib` when the citation is inserted.
struct ZoteroAddition: Equatable {
    let item: ZoteroItem
    let biblatex: String
    let file: URL
    /// Whether the item is in the linked collection; nil without a link.
    let inCollection: Bool?
}

/// A button beside the window's message, such as "Show in Zotero".
struct MessageAction: Equatable {
    let title: String
    let icon: String
    let url: URL
}

extension Workspace {
    /// `references-prose.bib` beside the main file.
    var proseBibliographyURL: URL {
        compilationURL.deletingLastPathComponent().appendingPathComponent(ProseBibliography.fileName)
            .standardizedFileURL
    }

    /// The open folder's link to Zotero.
    var zoteroLink: ZoteroLink? {
        if case let .folder(record) = project?.kind {
            return record.zotero
        }
        return nil
    }

    /// Only a folder opened in place has a record to keep a link in.
    var canLinkZotero: Bool {
        if case .folder = project?.kind {
            return true
        }
        return false
    }

    func performMessageAction() {
        guard let action = messageAction else {
            return
        }
        recordOperation("message.action", ["url": action.url.absoluteString])
        openExternalURL(action.url)
    }

    // MARK: - Tabs

    /// Shows the project's entries or Zotero's, keeping the query.
    func switchCitationTab(_ tab: CitationPicker.Tab) {
        guard let picker = citationPicker, picker.stage == .list, picker.tab != tab else {
            return
        }
        recordOperation("citation.tab", ["tab": tab == .zotero ? "zotero" : "project"])
        citationPicker?.tab = tab
        selectedCommandIndex = 0
        commandError = nil
        if tab == .zotero {
            checkZotero()
            scheduleZoteroSearch()
        } else {
            zoteroSearchTask?.cancel()
            zotero.searching = false
        }
    }

    /// The panel's query changed: the Zotero tab searches again after a pause.
    func citationQueryChanged() {
        guard citationPicker?.tab == .zotero, citationPicker?.stage == .list else {
            return
        }
        scheduleZoteroSearch()
    }

    /// Asks whether Zotero and Better BibTeX answer.
    func checkZotero() {
        zoteroCheckTask?.cancel()
        if zotero.availability != .ready {
            zotero.availability = .checking
        }
        let source = zoteroSource
        zoteroCheckTask = Task { [weak self] in
            let availability: ZoteroPane.Availability
            do {
                _ = try await source.ready()
                availability = .ready
            } catch {
                availability = Self.availability(for: error)
            }
            guard !Task.isCancelled, let self else {
                return
            }
            if availability != .ready || zotero.availability == .checking {
                zotero.availability = availability
            }
            recordOperation("zotero.ready", ["state": "\(availability)"])
        }
    }

    nonisolated static func availability(for error: any Error) -> ZoteroPane.Availability {
        switch error as? ZoteroError {
        case .notRunning: .notRunning
        case .betterBibTeXMissing: .betterBibTeXMissing
        case let .server(message): .failed(message)
        case nil: .failed(error.localizedDescription)
        }
    }

    // MARK: - Search

    /// Searches Zotero for the query after `ZoteroSearch.pause` (step D
    /// outcome, change 1): the longest word goes to Better BibTeX, the linked
    /// collection is searched for it in parallel, and the items are filtered
    /// by every word here. A query shorter than three characters searches
    /// nothing.
    func scheduleZoteroSearch() {
        zoteroSearchTask?.cancel()
        let query = query
        guard let word = ZoteroSearch.remoteWord(for: query) else {
            zotero.searching = false
            zotero.results = []
            zotero.searchedQuery = nil
            return
        }
        zotero.searching = true
        let source = zoteroSource, collection = zoteroLink?.collection
        zoteroSearchTask = Task { [weak self] in
            try? await Task.sleep(for: ZoteroSearch.pause)
            guard !Task.isCancelled else {
                return
            }
            async let items = source.search(word)
            async let members = Self.members(of: collection, matching: word, in: source)
            let outcome: Result<[ZoteroItem], any Error>
            do {
                outcome = try await .success(items)
            } catch {
                outcome = .failure(error)
            }
            let inCollection = await members
            guard !Task.isCancelled, let self, self.query == query else {
                return
            }
            zotero.searching = false
            zotero.searchedQuery = query
            switch outcome {
            case let .success(items):
                zotero.availability = .ready
                zotero.results = ZoteroSearch.results(
                    items,
                    query: query,
                    collectionItems: inCollection,
                    projectKeys: Set(bibliographyIndex.entries.map(\.key)),
                )
                selectedCommandIndex = min(selectedCommandIndex, max(0, zotero.results.count - 1))
                recordOperation("zotero.search", [
                    "word": word,
                    "items": String(items.count),
                    "results": String(zotero.results.count),
                ])
            case let .failure(error):
                zotero.results = []
                zotero.availability = Self.availability(for: error)
                recordOperation("zotero.searchFailed", ["error": error.localizedDescription])
            }
        }
    }

    /// The item keys in the linked collection that match `word`; empty
    /// without a link or when Zotero's local API does not answer.
    private nonisolated static func members(
        of collection: String?,
        matching word: String,
        in source: any ZoteroSource,
    ) async -> Set<String> {
        guard let collection else {
            return []
        }
        return await (try? source.collectionItems(collection, query: word)) ?? []
    }

    var highlightedZoteroResult: ZoteroSearch.Result? {
        let results = zotero.results
        return results.indices.contains(selectedCommandIndex) ? results[selectedCommandIndex] : nil
    }

    // MARK: - Citing

    /// Cites a Zotero item (step D outcome, change 3). An item whose key a
    /// project file already has is cited as that entry. Otherwise its
    /// BibLaTeX entry is exported first; the citation then writes it into
    /// `references-prose.bib` and names that file in the `#bibliography` call.
    func chooseZoteroItem(_ result: ZoteroSearch.Result, supplement: String? = nil) {
        guard let picker = citationPicker, !picker.loading, !zotero.exporting, !applyingCommand else {
            return
        }
        let item = result.item
        if let entry = bibliographyIndex.entries.first(where: { $0.key == item.key }) {
            recordOperation("zotero.cite", ["key": item.key, "new": "false"])
            citationPicker?.zoteroAddition = nil
            cite(entry, supplement: supplement)
            return
        }
        commandError = nil
        zotero.exporting = true
        let source = zoteroSource, link = zoteroLink, file = proseBibliographyURL
        Task {
            defer { zotero.exporting = false }
            async let exported = source.export([item.key])
            async let collections = Self.collections(of: item.key, linked: link != nil, in: source)
            do {
                let biblatex = try await exported
                guard ProseBibliography.keys(in: biblatex).contains(item.key) else {
                    throw ZoteroError.server(L10n.format("The export did not contain %@.", item.key))
                }
                let memberships = await collections
                let inCollection = link.map { link in
                    memberships.contains { $0.key == link.collection } || result.inCollection
                }
                guard citationPicker != nil else {
                    return
                }
                recordOperation("zotero.cite", ["key": item.key, "new": "true"])
                let addition = ZoteroAddition(item: item, biblatex: biblatex, file: file, inCollection: inCollection)
                citationPicker?.zoteroAddition = addition
                let entry = Self.entry(for: item)
                let path = DocumentResource(url: file, relativeTo: documentURL).relativePath
                let main = compilationURL.standardizedFileURL
                if BibliographyCall.adding(path, to: text) == .noCall, !bibliographyIndex.isLinked,
                   documentURL.standardizedFileURL == main, !declinedBibliographyOffers.contains(main)
                {
                    citationPicker?.stage = .linkBibliography(entry, supplement: supplement, path: path)
                    return
                }
                performCitation(entry, supplement: supplement, addingBibliography: false)
            } catch {
                recordOperation("zotero.exportFailed", ["error": error.localizedDescription])
                if error as? ZoteroError == .notRunning || error as? ZoteroError == .betterBibTeXMissing {
                    zotero.availability = Self.availability(for: error)
                }
                commandError = error.localizedDescription
            }
        }
    }

    private nonisolated static func collections(
        of key: String,
        linked: Bool,
        in source: any ZoteroSource,
    ) async -> [ZoteroCollection] {
        guard linked else {
            return []
        }
        return await (try? source.itemCollections([key]))?[key] ?? []
    }

    /// Appends the entry to `references-prose.bib`, creating it, unless the
    /// file has the key already. A file write: undo does not reach it.
    /// Returns whether the file changed.
    nonisolated static func appendToProseBibliography(_ addition: ZoteroAddition) throws -> Bool {
        let url = addition.file
        let existing = FileManager.default.fileExists(atPath: url.path) ? try DocumentStorage.read(url) : nil
        if let existing, ProseBibliography.keys(in: existing.0).contains(addition.item.key) {
            return false
        }
        let text = ProseBibliography.appending(addition.biblatex, to: existing?.0 ?? "")
        _ = try DocumentStorage.write(text, to: url, baseline: existing?.1 ?? DiskBaseline(data: nil))
        return true
    }

    /// Makes the open file's `#bibliography` call name `references-prose.bib`
    /// as its own undoable edit, after the citation's undo group closes.
    /// Returns whether the call names the file afterwards.
    func addProseBibliographyToCall(document: URL) async -> Bool {
        let path = DocumentResource(url: proseBibliographyURL, relativeTo: document).relativePath
        let deadline = ContinuousClock.now + .seconds(1)
        while editor?.undoManager.map({ $0.groupingLevel > 0 }) == true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let editor, documentURL == document, canEditSource, !editor.hasMarkedText() else {
            return false
        }
        switch BibliographyCall.adding(path, to: text) {
        case .alreadyNamed:
            return true
        case .noCall, .unsupported:
            return false
        case let .replace(range, replacement):
            let caret = editor.selectedRange()
            editor.insertSnippet(Snippet(text: replacement), replacing: range, focus: false)
            let shift = replacement.utf16.count - range.length
            editor.setSelectedRange(range.location < caret.location
                ? NSRange(location: caret.location + shift, length: caret.length) : caret)
            editor.writing.refreshNow()
            recordOperation("zotero.bibliographyCall", ["path": path])
            return true
        }
    }

    /// The line under the editor after a Zotero entry was added, with "Show
    /// in Zotero".
    func confirmZoteroAddition(_ addition: ZoteroAddition, named: Bool) {
        var parts = [L10n.format(
            "Cited %@ and added its entry to %@. That file change is not undone with ⌘Z.",
            addition.item.key,
            ProseBibliography.fileName,
        )]
        if !named {
            parts.append(L10n.format(
                "Add %@ to the #bibliography call so the citation compiles.",
                ProseBibliography
                    .fileName,
            ))
        }
        if let link = zoteroLink, addition.inCollection == false {
            parts.append(L10n.format(
                "Add the item to “%@” in Zotero; Prose removes its copy once %@ has it.",
                link.collectionName,
                link.bibliography,
            ))
        }
        showMessage(
            parts.joined(separator: " "),
            persistent: true,
            action: addition.item.selectURL.map {
                MessageAction(title: L10n.text("Show in Zotero"), icon: "arrow-square-out", url: $0)
            },
        )
    }

    // MARK: - Deduplication

    /// Removes from `references-prose.bib` every entry whose key another
    /// linked bibliography file now has, so Typst sees each key once. The
    /// file is rewritten atomically, every other entry byte for byte; it is
    /// left empty rather than deleted, and the `#bibliography` call keeps it.
    func removeProseDuplicates(using renderer: BlockRenderer, root: URL) async {
        let files = bibliographyIndex.contents.files.filter(\.linked)
        for file in files where (file.path as NSString).lastPathComponent == ProseBibliography.fileName {
            let others = files.map(\.path).filter { $0 != file.path }
            guard !others.isEmpty else {
                continue
            }
            let keys = await Set(renderer.bibliography(others).entries.map(\.key))
            let url = root.appendingPathComponent(file.path).standardizedFileURL
            let removed = await Task.detached { try? Self.removeKeys(keys, from: url) }.value ?? []
            guard !removed.isEmpty else {
                continue
            }
            proseDuplicatesRemoved += removed.count
            recordOperation("zotero.duplicatesRemoved", ["file": file.path, "keys": removed.joined(separator: ",")])
            projectFilesChanged([url])
        }
    }

    /// Rewrites `url` without the entries whose keys are in `keys`; returns
    /// the keys removed.
    nonisolated static func removeKeys(_ keys: Set<String>, from url: URL) throws -> [String] {
        let (text, baseline) = try DocumentStorage.read(url)
        let present = Set(ProseBibliography.keys(in: text)).intersection(keys)
        guard let updated = ProseBibliography.removing(present, from: text) else {
            return []
        }
        _ = try DocumentStorage.write(updated, to: url, baseline: baseline)
        return present.sorted()
    }

    /// A bibliography file changed on disk while the index is not kept
    /// current: when the project has a `references-prose.bib`, read the index
    /// again so its duplicates leave.
    func checkProseDuplicates(after files: [URL]) {
        guard !(writingEngine != nil && bibliographyIndexUsed),
              files.contains(where: {
                  $0.pathExtension.lowercased() == "bib" && $0.lastPathComponent != ProseBibliography.fileName
              }),
              FileManager.default.fileExists(atPath: proseBibliographyURL.path)
        else {
            return
        }
        scheduleBibliographyReload()
    }

    // MARK: - Link

    /// "Link to Zotero…": choose the project's auto-exported `.bib` and the
    /// collection behind it.
    func beginZoteroLink() {
        guard let picker = citationPicker, picker.stage == .list, let project, canLinkZotero else {
            return
        }
        recordOperation("zotero.linkBegin")
        commandError = nil
        let indexed = bibliographyIndex.contents.files.map(\.path)
        let found = ProjectTree.bibliographyFiles(in: project.root)
        var files: [String] = []
        for path in indexed + found where path.lowercased().hasSuffix(".bib")
            && (path as NSString).lastPathComponent != ProseBibliography.fileName && !files.contains(path)
        {
            files.append(path)
        }
        zotero.linkFiles = files
        zotero.linkFile = zoteroLink?.bibliography ?? files.first
        zotero.linkCollection = zoteroLink?.collection
        zotero.linkCollections = []
        zotero.linkLoading = true
        citationPicker?.stage = .zoteroLink
        let source = zoteroSource
        Task {
            do {
                let collections = try await source.collections()
                zotero.linkCollections = ZoteroCollection.paths(collections).map {
                    ZoteroCollectionChoice(key: $0.collection.key, path: $0.path)
                }
                if zotero.linkCollection == nil {
                    zotero.linkCollection = zotero.linkCollections.first?.key
                }
            } catch {
                zotero.availability = Self.availability(for: error)
                commandError = error.localizedDescription
            }
            zotero.linkLoading = false
        }
    }

    /// Stores the chosen file and collection with the project.
    func confirmZoteroLink() {
        guard case .zoteroLink = citationPicker?.stage, let file = zotero.linkFile,
              let key = zotero.linkCollection,
              let choice = zotero.linkCollections.first(where: { $0.key == key })
        else {
            return
        }
        setZoteroLink(ZoteroLink(bibliography: file, collection: key, collectionName: choice.path))
        citationPicker?.stage = .list
        scheduleZoteroSearch()
    }

    func unlinkZotero() {
        setZoteroLink(nil)
        if citationPicker?.tab == .zotero {
            scheduleZoteroSearch()
        }
    }

    /// The link goes into the project's record in `recent.json`.
    func setZoteroLink(_ link: ZoteroLink?) {
        guard var project, case var .folder(record) = project.kind else {
            return
        }
        recordOperation(link == nil ? "zotero.unlink" : "zotero.link", [
            "file": link?.bibliography ?? "",
            "collection": link?.collection ?? "",
        ])
        record.zotero = link
        try? projectStore.update(record)
        project.kind = .folder(record)
        self.project = project
    }
}
