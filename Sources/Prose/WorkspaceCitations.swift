import AppKit
import ProseCore

/// The citation picker's state in the command panel (citations note,
/// decision 4). It shares the panel's query and selected row.
struct CitationPicker: Equatable {
    enum Stage: Equatable {
        /// Searching the entries.
        case list
        /// One field for a page or section (`⌥Return`).
        case supplement(BibliographyEntry)
        /// The document has no `#bibliography` call: offer to add one for
        /// the file the entry came from.
        case linkBibliography(BibliographyEntry, supplement: String?, path: String)
    }

    var stage = Stage.list
    var supplement = ""
    /// The index is being read.
    var loading = true
    /// The index revision on show, so the panel redraws when it changes.
    var revision = 0
    /// The command search to return to.
    var returnQuery = ""
}

extension Workspace {
    private var citeCommand: WritingCommand? {
        WritingCommand.all.first { $0.id == "cite" }
    }

    /// Opens the picker in the panel and reads the project's bibliography
    /// files again.
    func openCitationPicker() {
        guard paletteOpen else {
            return
        }
        recordOperation("citation.open")
        commandError = nil
        activeCommand = nil
        citationPicker = CitationPicker(revision: bibliographyIndex.revision, returnQuery: query)
        query = ""
        selectedCommandIndex = 0
        reloadBibliographyIndex()
    }

    /// The entries matching the panel's query, best first.
    var citationResults: [BibliographyEntry] {
        let revision = bibliographyIndex.revision
        if let cached = citationResultsCache, cached.query == query, cached.revision == revision {
            return cached.entries
        }
        let entries = bibliographyIndex.search(query, limit: 200)
        citationResultsCache = (query, revision, entries)
        return entries
    }

    var highlightedCitation: BibliographyEntry? {
        let results = citationResults
        return results.indices.contains(selectedCommandIndex) ? results[selectedCommandIndex] : nil
    }

    /// The entry the panel is about: the highlighted row, or the one being
    /// cited.
    var citationPickerEntry: BibliographyEntry? {
        switch citationPicker?.stage {
        case .list: highlightedCitation
        case let .supplement(entry): entry
        case let .linkBibliography(entry, _, _): entry
        case nil: nil
        }
    }

    /// The empty state's action: the `bibliography` command, which asks for
    /// a file to import.
    func createBibliographyFromPicker() {
        guard let command = WritingCommand.all.first(where: { $0.id == "bibliography" }) else {
            return
        }
        citationPicker = nil
        query = ""
        selectedCommandIndex = 0
        selectCommand(command)
    }

    /// Problems in the bibliography files, one line per file.
    var citationProblems: [String] {
        bibliographyIndex.contents.problemSummaries
    }

    /// Reads the bibliography files through Writing mode's engine, creating
    /// the engine first in Code mode. The editor's text goes to the engine so
    /// an unsaved `#bibliography` call counts.
    func reloadBibliographyIndex() {
        bibliographyReloadTask?.cancel()
        bibliographyReloadTask = nil
        bibliographyIndexUsed = true
        bibliographyIndexGeneration += 1
        let generation = bibliographyIndexGeneration
        Task {
            defer {
                if generation == bibliographyIndexGeneration {
                    citationPicker?.loading = false
                    citationPicker?.revision = bibliographyIndex.revision
                }
            }
            guard let engine = await citationEngine(), generation == bibliographyIndexGeneration else {
                return
            }
            try? await engine.renderer.setText(text, of: documentURL)
            await bibliographyIndex.reload(using: engine.renderer, root: engine.root)
            guard generation == bibliographyIndexGeneration else {
                return
            }
            bibliographyReloads += 1
            recordOperation("citation.indexed", [
                "entries": String(bibliographyIndex.entries.count),
                "linked": String(bibliographyIndex.isLinked),
            ])
        }
    }

    /// An edit may have changed a `#bibliography` call: read the index again
    /// once edits pause.
    func scheduleBibliographyReload() {
        bibliographyReloadTask?.cancel()
        bibliographyReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else {
                return
            }
            bibliographyReloadTask = nil
            reloadBibliographyIndex()
        }
    }

    /// Writing mode's engine for the open project and its root, created if
    /// Writing mode has not been used yet.
    private func citationEngine() async -> (renderer: BlockRenderer, root: URL)? {
        let key = writingEngineKey
        if let engine = writingEngine, engine.key == key {
            return (engine.renderer, key.root)
        }
        if writingEngineRequest != key {
            if writingEngine != nil {
                freeWritingEngine()
            }
            createWritingEngine(for: key)
        }
        await writingEngineTask?.value
        guard let engine = writingEngine, engine.key == key else {
            return nil
        }
        return (engine.renderer, key.root)
    }

    /// Keys in the picker. Returns whether the panel used the event; typing
    /// goes on to the search or supplement field.
    func handleCitationKey(_ event: NSEvent) -> Bool {
        guard let picker = citationPicker else {
            return false
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch picker.stage {
        case .list:
            if modifiers.isEmpty || modifiers == .shift, event.keyCode == 125 {
                selectedCommandIndex = min(selectedCommandIndex + 1, max(0, citationResults.count - 1))
                return true
            }
            if modifiers.isEmpty || modifiers == .shift, event.keyCode == 126 {
                selectedCommandIndex = max(0, selectedCommandIndex - 1)
                return true
            }
            if isReturn, modifiers.isEmpty || modifiers == .option {
                if let entry = highlightedCitation {
                    if modifiers == .option {
                        askSupplement(for: entry)
                    } else {
                        cite(entry)
                    }
                }
                return true
            }
            return false
        case let .supplement(entry):
            if isReturn, modifiers.isEmpty {
                cite(entry, supplement: picker.supplement)
                return true
            }
            return false
        case let .linkBibliography(entry, supplement, _):
            if isReturn, modifiers.isEmpty {
                performCitation(entry, supplement: supplement, addingBibliography: true)
                return true
            }
            if modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "n" {
                answerBibliographyOffer(add: false)
                return true
            }
            return modifiers.isEmpty
        }
    }

    /// `⌥Return` (the note's **Choice**): one field for a page or section.
    func askSupplement(for entry: BibliographyEntry) {
        guard citationPicker != nil else {
            return
        }
        commandError = nil
        citationPicker?.supplement = ""
        citationPicker?.stage = .supplement(entry)
    }

    /// Accepts or declines the offer to add a `#bibliography` call.
    func answerBibliographyOffer(add: Bool) {
        guard case let .linkBibliography(entry, supplement, _) = citationPicker?.stage else {
            return
        }
        if !add {
            declinedBibliographyOffers.insert(compilationURL.standardizedFileURL)
        }
        recordOperation("citation.bibliographyOffer", ["accepted": String(add)])
        performCitation(entry, supplement: supplement, addingBibliography: add)
    }

    /// Cites `entry` at the caret. When the document names no bibliography
    /// file and this file is the main file, asks first whether to add a
    /// `#bibliography` call for the entry's file.
    func cite(_ entry: BibliographyEntry, supplement: String? = nil) {
        guard let picker = citationPicker, !picker.loading else {
            return
        }
        if let path = bibliographyOfferPath(for: entry) {
            commandError = nil
            citationPicker?.stage = .linkBibliography(entry, supplement: supplement, path: path)
            return
        }
        performCitation(entry, supplement: supplement, addingBibliography: false)
    }

    /// The path, relative to the main file, of the `#bibliography` call to
    /// offer, or nil when no offer applies: the document has a call, the
    /// writer declined for this main file, or the open file is not the main
    /// file (the insertion edits only the open buffer).
    private func bibliographyOfferPath(for entry: BibliographyEntry) -> String? {
        let main = compilationURL.standardizedFileURL
        guard !bibliographyIndex.isLinked,
              bibliographyIndex.contents.files.contains(where: { $0.path == entry.file && !$0.linked }),
              documentURL.standardizedFileURL == main, !declinedBibliographyOffers.contains(main),
              !text.contains("bibliography(")
        else {
            return nil
        }
        let file = writingEngineKey.root.appendingPathComponent(entry.file)
        return DocumentResource(url: file, relativeTo: main).relativePath
    }

    /// Inserts the citation at the caret as one undoable edit, after the
    /// insertion-context check refuses math, code and raw text. With
    /// `addingBibliography`, first adds the `#bibliography` call at the end
    /// of the main file through the `bibliography` command's snippet, as its
    /// own undoable edit. Writing mode compiles at once afterwards.
    func performCitation(_ entry: BibliographyEntry, supplement: String?, addingBibliography: Bool) {
        guard canEditSource, !applyingCommand, let editor, !editor.hasMarkedText(), let command = citeCommand,
              let picker = citationPicker
        else {
            return
        }
        guard serviceReady else {
            commandError = L10n.text(
                "The typesetting service is not ready to check the insertion position. You can still edit directly.",
            )
            return
        }
        let selection = editor.selectedRange()
        let range = NSRange(location: NSMaxRange(selection), length: 0)
        let version = revision, document = documentURL
        let offerPath: String? = if case let .linkBibliography(_, _, path) = picker.stage {
            path
        } else {
            nil
        }
        applyingCommand = true
        recordOperation("insertion.begin", ["command": command.id])
        Task {
            defer { applyingCommand = false }
            do {
                _ = try await insertionContext(for: command, range: range)
                guard version == revision, documentURL == document, paletteOpen, citationPicker != nil,
                      editor.selectedRange() == selection
                else {
                    recordOperation(
                        "insertion.cancelled",
                        ["command": command.id, "reason": "document, selection or panel changed"],
                    )
                    return
                }
                let bibliographyCommand = addingBibliography && offerPath != nil
                    ? WritingCommand.all.first(where: { $0.id == "bibliography" }) : nil
                let call = try bibliographyCommand.map { try TypstInsertion.make(
                    $0.id,
                    values: ["path": offerPath ?? ""],
                ) }
                let citation = CitationInsertion.text(
                    citing: entry.key,
                    in: text as NSString,
                    at: range.location,
                    supplement: supplement,
                )
                closePalette()
                if layout == .preview {
                    layout = .split
                }
                editor.insertSnippet(Snippet(text: citation), replacing: range)
                editor.writing.refreshNow()
                recordOperation(
                    "insertion.finished",
                    ["command": command.id, "insertedUTF16": String(citation.utf16.count)],
                )
                if let call {
                    await appendBibliographyCall(call, path: offerPath ?? "", document: document)
                }
            } catch {
                recordOperation("insertion.failed", ["command": command.id, "error": error.localizedDescription])
                commandError = error.localizedDescription
            }
        }
    }

    /// Adds the `bibliography` command's call at the end of the open main
    /// file, after a blank line, as its own undoable edit. The citation's
    /// edit joined the undo group AppKit keeps open for this pass of the run
    /// loop; waiting for that group to close keeps the two edits apart, so
    /// one undo removes only the call. The caret stays where it was.
    private func appendBibliographyCall(_ call: Snippet, path: String, document: URL) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while editor?.undoManager.map({ $0.groupingLevel > 0 }) == true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let editor, documentURL == document, canEditSource, !paletteOpen, !editor.hasMarkedText() else {
            return
        }
        let before = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        let caret = editor.selectedRange()
        editor.insertSnippet(
            call.padded(before: before, after: "\n"),
            replacing: NSRange(location: text.utf16.count, length: 0),
            focus: false,
        )
        editor.setSelectedRange(caret)
        editor.writing.refreshNow()
        recordOperation("citation.bibliographyAdded", ["path": path])
    }
}
