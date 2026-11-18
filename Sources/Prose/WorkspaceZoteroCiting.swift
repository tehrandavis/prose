import AppKit
import ProseCore

/// What the sidebar's Bibliography view lists: the project's entries, or
/// the Zotero library through the picker's search.
enum BibliographySidebarSource: Equatable {
    case project
    case zotero
}

/// "Search Zotero when I type @": on by default. It is kept in this Mac's
/// user defaults, like Check Spelling While Typing, since it depends on
/// whether this Mac runs Zotero.
enum ZoteroCompletionPreference {
    static let key = "searchZoteroWhenTyping"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Zotero outside the picker: the sidebar's Zotero view and the `@` list.
/// Both use the picker's search (`ZoteroSearch.search`), its export
/// (`exportZoteroAddition`) and its file write (`appendToProseBibliography`).
extension Workspace {
    /// After Zotero fails to answer the `@` list, it is not asked again for
    /// this long, so typing `@` never waits on a closed port.
    static let zoteroCompletionPause = Duration.seconds(60)

    // MARK: - The sidebar

    func switchBibliographySidebar(to source: BibliographySidebarSource) {
        guard bibliographySidebarSource != source else {
            return
        }
        bibliographySidebarSource = source
        recordOperation("bibliography.sidebarSource", ["source": source == .zotero ? "zotero" : "project"])
        if source == .project {
            sidebarZoteroTask?.cancel()
            sidebarZotero.searching = false
        }
    }

    /// The sidebar's query in its Zotero view. A query too short to search
    /// only asks whether Zotero answers; a longer one searches after the
    /// picker's pause.
    func scheduleSidebarZoteroSearch(_ query: String) {
        sidebarZoteroTask?.cancel()
        let source = zoteroSource, collection = zoteroLink?.collection
        guard ZoteroSearch.remoteWord(for: query) != nil else {
            sidebarZotero.searching = false
            sidebarZotero.results = []
            sidebarZotero.searchedQuery = nil
            sidebarZoteroTask = Task { [weak self] in
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
                sidebarZotero.availability = availability
            }
            return
        }
        sidebarZotero.searching = true
        sidebarZoteroTask = Task { [weak self] in
            try? await Task.sleep(for: ZoteroSearch.pause)
            guard !Task.isCancelled else {
                return
            }
            let outcome: Result<ZoteroSearch.Found?, any Error>
            do {
                outcome = try await .success(ZoteroSearch.search(
                    query,
                    in: source,
                    collection: collection,
                    projectKeys: [],
                ))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled, let self else {
                return
            }
            sidebarZotero.searching = false
            sidebarZotero.searchedQuery = query
            switch outcome {
            case let .success(found):
                sidebarZotero.availability = .ready
                sidebarZotero.results = markingProjectKeys(found?.results ?? [])
                zoteroCompletionPausedUntil = nil
                recordOperation("zotero.sidebarSearch", [
                    "word": found?.word ?? "",
                    "items": String(found?.items ?? 0),
                    "results": String(sidebarZotero.results.count),
                ])
            case let .failure(error):
                sidebarZotero.results = []
                sidebarZotero.availability = Self.availability(for: error)
                recordOperation("zotero.sidebarSearchFailed", ["error": error.localizedDescription])
            }
        }
    }

    // MARK: - The `@` list

    /// Zotero's rows for the `@` list: the picker's search for what was
    /// typed after the `@`, without the items whose key the project has
    /// (the list shows those already). Empty when the setting is off, the
    /// typed text is shorter than three characters, or Zotero failed to
    /// answer in the last minute. A failure pauses the search; it never
    /// shows in the list.
    func zoteroCompletions(
        for reference: (range: NSRange, query: String),
        in source: String,
    ) async -> [SourceCompletion] {
        guard searchesZoteroWhenTyping, ZoteroSearch.remoteWord(for: reference.query) != nil else {
            return []
        }
        if let until = zoteroCompletionPausedUntil, ContinuousClock.now < until {
            return []
        }
        let zotero = zoteroSource, collection = zoteroLink?.collection
        do {
            guard let found = try await ZoteroSearch.search(
                reference.query,
                in: zotero,
                collection: collection,
                projectKeys: [],
            ) else {
                return []
            }
            zoteroCompletionPausedUntil = nil
            let keys = bibliographyIndex.keys
            let text = source as NSString
            return found.results.filter { !keys.contains($0.item.key) }.map { result in
                SourceCompletion(
                    citing: result,
                    replacing: reference.range,
                    with: CitationInsertion.text(citing: result.item.key, in: text, replacing: reference.range),
                )
            }
        } catch {
            // A request cancelled because the writer typed on is no failure.
            guard !Task.isCancelled else {
                return []
            }
            zoteroCompletionPausedUntil = .now + Self.zoteroCompletionPause
            recordOperation("zotero.completionPaused", ["error": error.localizedDescription])
            return []
        }
    }

    // MARK: - Citing

    /// Cites a Zotero item from the sidebar, at the caret, or from the `@`
    /// list, in place of the typed `@prefix` (`typed`), as the picker's
    /// Return does: an item whose key the project has is cited as that
    /// entry; otherwise its entry is exported, written into
    /// `references-prose.bib`, cited, and the file is named in the
    /// `#bibliography` call. With no call in the main file, the call is
    /// added, since there is no panel to ask in. The keyboard stays in the
    /// editor and the message line confirms.
    func citeZoteroItem(_ result: ZoteroSearch.Result, replacing typed: NSRange? = nil) {
        let item = result.item
        let from = typed == nil ? "sidebar" : "completion"
        if let entry = bibliographyIndex.entries.first(where: { $0.key == item.key }) {
            recordOperation("zotero.cite", ["key": item.key, "new": "false", "from": from])
            if let typed {
                citeTyped(entry.key, replacing: typed)
            } else {
                citeFromSidebar(entry)
            }
            return
        }
        guard canEditSource, !applyingCommand, !sidebarZotero.exporting, let editor, !editor.hasMarkedText(),
              let command = citeCommand
        else {
            return
        }
        if layout == .preview {
            layout = .split
        }
        if typed == nil {
            returnKeyboardToEditor()
        }
        let selection = editor.selectedRange()
        let target = typed ?? NSRange(location: NSMaxRange(selection), length: 0)
        let typedText = (text as NSString).substring(with: target)
        let version = revision, document = documentURL
        sidebarZotero.exporting = true
        recordOperation("insertion.begin", ["command": command.id, "from": from])
        Task {
            defer { sidebarZotero.exporting = false }
            do {
                let addition = try await exportZoteroAddition(result)
                if typed == nil {
                    _ = try await insertionContext(for: command, range: target)
                }
                // Where the citation goes now. From the sidebar the caret
                // must not have moved; from the `@` list the typed text must
                // still be where it was.
                let place = { [self] () -> NSRange? in
                    guard documentURL == document, !editor.hasMarkedText(), canEditSource else {
                        return nil
                    }
                    if version == revision {
                        return typed == nil && editor.selectedRange() != selection ? nil : target
                    }
                    let source = text as NSString
                    guard typed != nil, NSMaxRange(target) <= source.length,
                          source.substring(with: target) == typedText
                    else {
                        return nil
                    }
                    return target
                }
                guard place() != nil, !applyingCommand else {
                    cancelZoteroCitation(command, item: item)
                    return
                }
                applyingCommand = true
                defer { applyingCommand = false }
                let wrote = try await Task.detached { try Self.appendToProseBibliography(addition) }.value
                if wrote {
                    _ = await writingEngine?.renderer.filesChanged([addition.file])
                }
                guard let range = place() else {
                    cancelZoteroCitation(command, item: item)
                    return
                }
                recordOperation("zotero.cite", ["key": item.key, "new": "true", "from": from])
                let offer = proseBibliographyCallOffer(for: addition.file)
                let call = try offer.map { try TypstInsertion.make("bibliography", values: ["path": $0]) }
                let typedOn = version != revision
                let caret = editor.selectedRange()
                let citation = CitationInsertion.text(citing: item.key, in: text as NSString, replacing: range)
                editor.insertSnippet(Snippet(text: citation), replacing: range)
                if typedOn, caret.location >= NSMaxRange(range) {
                    // The writer typed on after the `@` list closed: the
                    // caret stays where they were typing.
                    let shift = citation.utf16.count - range.length
                    editor.setSelectedRange(NSRange(location: caret.location + shift, length: caret.length))
                }
                editor.writing.refreshNow()
                if typed == nil {
                    returnKeyboardToEditor()
                }
                recordOperation(
                    "insertion.finished",
                    ["command": command.id, "insertedUTF16": String(citation.utf16.count)],
                )
                recordOperation("zotero.added", ["key": item.key, "written": String(wrote)])
                var named = false
                if let call, let offer {
                    await appendBibliographyCall(call, path: offer, document: document)
                    named = BibliographyCall.adding(offer, to: text) == .alreadyNamed
                } else {
                    named = await addProseBibliographyToCall(document: document)
                }
                confirmZoteroAddition(addition, named: named)
            } catch {
                recordOperation("zotero.exportFailed", ["error": error.localizedDescription, "from": from])
                if error as? ZoteroError == .notRunning || error as? ZoteroError == .betterBibTeXMissing {
                    sidebarZotero.availability = Self.availability(for: error)
                }
                showMessage(error.localizedDescription)
            }
        }
    }

    /// The `@` list chose an entry the project has: the citation replaces
    /// the typed `@prefix`, as a project row does.
    private func citeTyped(_ key: String, replacing typed: NSRange) {
        guard canEditSource, let editor, !editor.hasMarkedText(), NSMaxRange(typed) <= text.utf16.count else {
            return
        }
        let citation = CitationInsertion.text(citing: key, in: text as NSString, replacing: typed)
        editor.insertSnippet(Snippet(text: citation), replacing: typed)
        editor.writing.refreshNow()
    }

    private func cancelZoteroCitation(_ command: WritingCommand, item: ZoteroItem) {
        recordOperation("insertion.cancelled", ["command": command.id, "reason": "document or selection changed"])
        showMessage(L10n.format("The text changed while Zotero answered, so %@ was not cited. Try again.", item.key))
    }
}
