import AppKit
import ProseCore
import SwiftUI

/// What the sidebar shows under its segmented control.
enum SidebarView: Equatable {
    case files
    case comments
    case bibliography
}

/// The look shared by the `@` list and the sidebar's Bibliography view
/// (after RStudio's citation rows): a type icon in a small bordered square,
/// a "Z" badge for an entry from Zotero, `@key` in the monospaced font, the
/// authors and year, and the title.
enum CitationRowStyle {
    /// The Phosphor icon for a Hayagriva entry type.
    static func icon(forKind kind: String) -> String {
        switch kind.lowercased() {
        case "article", "periodical", "newspaper": "article"
        case "book", "anthology", "proceedings", "reference": "book"
        case "chapter", "anthos", "entry": "book-open-text"
        case "thesis": "graduation-cap"
        case "web", "blog", "post", "thread", "repository": "globe"
        case "report", "manuscript": "file-text"
        default: "file"
        }
    }

    /// The type in words, for VoiceOver.
    static func typeName(forKind kind: String) -> String {
        switch icon(forKind: kind) {
        case "article": L10n.text("Article")
        case "book": L10n.text("Book")
        case "book-open-text": L10n.text("Chapter")
        case "graduation-cap": L10n.text("Thesis")
        case "globe": L10n.text("Web page")
        case "file-text": L10n.text("Report")
        default: L10n.text("Source")
        }
    }

    static let iconBox: CGFloat = 28
    static let zoteroRed = NSColor(hex: 0xCC2936)
}

/// The type icon in its bordered square, with the Zotero badge.
struct CitationTypeIcon: View {
    let kind: String
    let zotero: Bool

    var body: some View {
        PhosphorIcon(name: CitationRowStyle.icon(forKind: kind), size: 15).foregroundStyle(Theme.secondary)
            .frame(width: CitationRowStyle.iconBox, height: CitationRowStyle.iconBox)
            .background(Theme.editor, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
            .overlay(alignment: .bottomTrailing) {
                if zotero {
                    Text("Z").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 11, height: 11)
                        .background(Color(nsColor: CitationRowStyle.zoteroRed), in: RoundedRectangle(cornerRadius: 2))
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// The sidebar's Bibliography view: the project's entries sorted by first
/// author and year, filtered by the sidebar's search. A click cites the
/// entry at the caret.
struct BibliographySidebarList: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var hover: RowHover
    let query: String
    /// The entries sorted, for the index revision they were sorted at.
    @State private var sorted: (revision: Int, entries: [BibliographyEntry]) = (-1, [])
    /// The keys matching the search, for the query and revision.
    @State private var matches: (query: String, revision: Int, keys: Set<String>)?
    /// The keys the open document cites.
    @State private var cited: Set<String> = []

    var body: some View {
        let revision = workspace.bibliographyRevisionShown
        let contents = workspace.bibliographyIndex.contents
        let loading = revision < 0
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let entries = searching
            ? (matches.map { found in sorted.entries.filter { found.keys.contains($0.key) } } ?? sorted.entries)
            : sorted.entries
        let rejected = Self.rejectedFiles(contents)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !contents.files.isEmpty {
                    ForEach(contents.files, id: \.path) { file in
                        fileHeader(file, problem: rejected[file.path])
                    }
                    .padding(.bottom, 4)
                }
                if loading, contents.files.isEmpty {
                    note(L10n.text("Reading bibliography files…"), detail: nil)
                } else if contents.files.isEmpty {
                    note(
                        L10n.text("No bibliography"),
                        detail: L10n.text("Add a .bib or .yml file to the project, or press ⌘J R B to add one."),
                    )
                } else if entries.isEmpty {
                    note(
                        searching ? L10n.text("No matching sources") : L10n.text("No entries"),
                        detail: searching ? L10n.text("Try an author's family name, a year, a title word or a key.")
                            : nil,
                    )
                }
                ForEach(entries, id: \.key) { entry in
                    BibliographySidebarRow(
                        entry: entry,
                        zotero: workspace.isZoteroEntry(entry),
                        mark: cited.contains(entry.key) ? .cited : nil,
                        problem: rejected[entry.file],
                        hover: hover,
                        cite: { workspace.citeFromSidebar(entry) },
                    )
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
        }
        .accessibilityIdentifier("sidebar.bibliography")
        .onAppear { workspace.loadSidebarBibliography() }
        .onChange(of: workspace.fileURL) { _, _ in workspace.loadSidebarBibliography() }
        .task(id: revision) {
            let snapshot = workspace.bibliographyIndex.snapshot
            let entries = await Task.detached(priority: .userInitiated) { Self.sort(snapshot.entries) }.value
            sorted = (revision, entries)
        }
        .task(id: SearchKey(query: query, revision: revision)) {
            guard searching else {
                matches = nil
                return
            }
            let snapshot = workspace.bibliographyIndex.snapshot
            let found = await Task.detached(priority: .userInitiated) {
                Set(snapshot.search(query).map(\.key))
            }.value
            matches = (query, revision, found)
        }
        .task(id: workspace.revision) {
            // After a pause in typing, the keys the document cites.
            try? await Task.sleep(for: .milliseconds(cited.isEmpty ? 0 : 600))
            guard !Task.isCancelled else {
                return
            }
            let source = workspace.text
            let keys = await Task.detached(priority: .utility) { CitationInsertion.citedKeys(in: source) }.value
            if !Task.isCancelled, keys != cited {
                cited = keys
            }
        }
    }

    private struct SearchKey: Equatable {
        let query: String
        let revision: Int
    }

    /// By the first author's family name, then the year, then the key. An
    /// entry with no author sorts by its title.
    nonisolated static func sort(_ entries: [BibliographyEntry]) -> [BibliographyEntry] {
        let fold = { (text: String) in
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let keyed = entries.map { entry in
            (entry, fold(entry.authors.first?.family ?? entry.title ?? entry.key))
        }
        return keyed.sorted { left, right in
            if left.1 != right.1 {
                return left.1 < right.1
            }
            if left.0.year != right.0.year {
                return (left.0.year ?? .max) < (right.0.year ?? .max)
            }
            return left.0.key < right.0.key
        }.map(\.0)
    }

    /// Files Typst would reject, with the reason: the picker's problem line
    /// for the file.
    static func rejectedFiles(_ contents: BibliographyContents) -> [String: String] {
        let summaries = contents.problemSummaries
        var rejected: [String: String] = [:]
        for file in contents.files where !file.accepted {
            rejected[file.path] = summaries.first { $0.hasPrefix(file.path + ":") }
                ?? L10n.format("%@: Typst cannot read this file.", file.path)
        }
        return rejected
    }

    private func fileHeader(_ file: BibliographyFile, problem: String?) -> some View {
        let count = file.entries == 1 ? L10n.text("1 entry") : L10n.format("%@ entries", String(file.entries))
        return HStack(spacing: 5) {
            if let problem {
                PhosphorIcon(name: "warning-circle", size: 12).foregroundStyle(Theme.amber)
                    .help(problem)
            }
            Text((file.path as NSString).lastPathComponent + " · " + count)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(file.path)
            Spacer(minLength: 0)
            Button { workspace.openProjectFile(workspace.bibliographyFileURL(file.path)) } label: {
                PhosphorIcon(name: "arrow-square-out", size: 12).foregroundStyle(Theme.secondary)
                    .frame(width: 20, height: 20)
            }.buttonStyle(QuietControlStyle())
                .accessibilityLabel(L10n.format("Open %@", file.path))
                .learningHelp(L10n.format("Open %@", file.path))
        }
        .padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.bibliography.file." + file.path)
    }

    private func note(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 8).padding(.vertical, 10)
    }
}

/// "This Project" and "Zotero" under the Bibliography view's search field.
struct BibliographySourceSwitch: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            item(.project, title: L10n.text("This Project"), identifier: "sidebar.bibliography.project")
            item(.zotero, title: L10n.text("Zotero"), identifier: "sidebar.bibliography.zotero")
        }
        .padding(2)
        .background(Theme.border.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }

    private func item(_ value: BibliographySidebarSource, title: String, identifier: String) -> some View {
        let selected = workspace.bibliographySidebarSource == value
        return Button { workspace.switchBibliographySidebar(to: value) } label: {
            Text(title).font(.system(size: 11, weight: selected ? .medium : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 20)
                .background(selected ? Theme.background : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(selected ? Theme.text : Theme.secondary)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// The Bibliography view's Zotero side: the picker's Zotero search over the
/// whole library, at most 50 rows, the linked collection's first. Every row
/// has the Zotero badge; a check marks an item the project has. A click
/// cites it at the caret as the picker's Return does.
struct ZoteroSidebarList: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var hover: RowHover
    let query: String

    var body: some View {
        let pane = workspace.sidebarZotero
        // Redrawn when the index changes, for the marks.
        let _ = workspace.bibliographyRevisionShown
        let keys = workspace.bibliographyIndex.keys
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if pane.exporting {
                    note(L10n.text("Getting the entry from Zotero…"), detail: nil)
                }
                if pane.results.isEmpty {
                    status(pane)
                }
                ForEach(pane.results) { result in
                    let inProject = keys.contains(result.item.key)
                    BibliographySidebarRow(
                        entry: result.item.bibliographyEntry,
                        zotero: true,
                        mark: inProject ? .inProject : (result.inCollection ? .inCollection : nil),
                        problem: nil,
                        hover: hover,
                        rowPrefix: "zotero",
                        cite: { workspace.citeZoteroItem(result) },
                    )
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
        }
        .accessibilityIdentifier("sidebar.zotero")
        .onAppear {
            workspace.loadSidebarBibliography()
            workspace.scheduleSidebarZoteroSearch(query)
        }
        .onChange(of: query) { _, query in workspace.scheduleSidebarZoteroSearch(query) }
    }

    /// Why there are no rows, in the picker's words.
    @ViewBuilder
    private func status(_ pane: ZoteroPane) -> some View {
        switch pane.availability {
        case .notRunning:
            note(
                L10n.text("Zotero is not running."),
                detail: L10n.text("Open Zotero to search your library. This Project still works."),
            )
        case .betterBibTeXMissing:
            note(
                L10n.text("Better BibTeX is required."),
                detail: L10n.text("Install the Better BibTeX plugin in Zotero, then try again."),
            )
        case let .failed(message):
            note(L10n.text("Zotero could not be searched."), detail: message)
        case .checking, .ready:
            if pane.searching {
                note(L10n.text("Searching Zotero…"), detail: nil)
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                note(
                    L10n.text("Type to search your Zotero library"),
                    detail: L10n.text("An author's family name, a title word, a year or a key."),
                )
            } else if pane.searchedQuery == nil {
                note(L10n.text("Type at least three characters to search Zotero."), detail: nil)
            } else {
                note(
                    L10n.text("No matching items in Zotero"),
                    detail: L10n
                        .text("Every word must appear in an author's family name, the title, the year or the key."),
                )
            }
        }
    }

    private func note(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 8).padding(.vertical, 10)
    }
}

/// The quiet mark at the end of a sidebar row.
enum BibliographyRowMark {
    /// The open document cites the entry.
    case cited
    /// A Zotero item whose key a project bibliography file has.
    case inProject
    /// A Zotero item in the project's linked collection.
    case inCollection

    var icon: String {
        switch self {
        case .cited, .inProject: "check"
        case .inCollection: "folder-simple"
        }
    }

    var help: String {
        switch self {
        case .cited: L10n.text("Cited in this document")
        case .inProject: L10n.text("Already in a project bibliography file")
        case .inCollection: L10n.text("In the linked collection")
        }
    }

    /// The words VoiceOver reads after the row.
    var spoken: String {
        switch self {
        case .cited: L10n.text("cited")
        case .inProject: L10n.text("in the project")
        case .inCollection: L10n.text("in the linked collection")
        }
    }
}

/// One entry in the sidebar: the type icon, `@key`, the authors and year,
/// then the title. A quiet mark ends a cited entry, or a Zotero item the
/// project has; on hover a button copies the key.
private struct BibliographySidebarRow: View {
    let entry: BibliographyEntry
    let zotero: Bool
    let mark: BibliographyRowMark?
    let problem: String?
    @ObservedObject var hover: RowHover
    /// "bibliography" for the project's entries, "zotero" for Zotero's.
    var rowPrefix = "bibliography"
    let cite: () -> Void

    private var rowID: String {
        rowPrefix + ":" + entry.key
    }

    var body: some View {
        let hovered = hover.id == rowID
        HStack(alignment: .top, spacing: 8) {
            CitationTypeIcon(kind: entry.kind, zotero: zotero).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("@" + entry.key).font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if let problem {
                        PhosphorIcon(name: "warning-circle", size: 11).foregroundStyle(Theme.amber)
                            .help(problem)
                    }
                    Spacer(minLength: 0)
                    if hovered {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.key, forType: .string)
                        } label: {
                            PhosphorIcon(name: "copy", size: 12).foregroundStyle(Theme.secondary)
                                .frame(width: 18, height: 18)
                        }.buttonStyle(QuietControlStyle())
                            .accessibilityLabel(L10n.text("Copy Key"))
                            .learningHelp(L10n.text("Copy Key"))
                    } else if let mark {
                        PhosphorIcon(name: mark.icon, size: 11).foregroundStyle(Theme.muted)
                            .frame(width: 18, height: 18)
                            .help(mark.help)
                    }
                }
                if !entry.authorYearLine.isEmpty {
                    Text(entry.authorYearLine).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text(entry.title ?? L10n.text("Untitled")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openRow(rowID, hover: hover)
        .onTapGesture(perform: cite)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([
            CitationRowStyle.typeName(forKind: entry.kind),
            entry.key,
            entry.authorYearLine,
            entry.title ?? "",
            mark?.spoken ?? "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { cite() }
        .accessibilityIdentifier("sidebar." + rowPrefix + "." + entry.key)
    }
}
