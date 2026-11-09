import ProseCore
import SwiftUI

/// "This Project" and "Zotero" above the picker's list (`⌘1`, `⌘2`, Tab).
struct CitationTabs: View {
    @ObservedObject var workspace: Workspace
    let tab: CitationPicker.Tab

    var body: some View {
        HStack(spacing: 2) {
            item(.project, title: L10n.text("This Project"), key: "⌘1")
            item(.zotero, title: L10n.text("Zotero"), key: "⌘2")
        }.padding(2).background(Theme.border.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
    }

    private func item(_ value: CitationPicker.Tab, title: String, key: String) -> some View {
        Button { workspace.switchCitationTab(value) } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: tab == value ? .medium : .regular))
                Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tab == value ? Theme.background : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).foregroundStyle(tab == value ? Theme.text : Theme.secondary)
            .accessibilityAddTraits(tab == value ? [.isSelected, .isButton] : .isButton)
    }
}

/// The Zotero tab: the results, or why there are none, and the link.
struct ZoteroResultsPane: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let pane = workspace.zotero
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if pane.results.isEmpty {
                            status(pane)
                        }
                        ForEach(Array(pane.results.enumerated()), id: \.element.id) { offset, result in
                            ZoteroRow(result: result, selected: offset == workspace.selectedCommandIndex) {
                                workspace.selectedCommandIndex = offset
                                workspace.chooseZoteroItem(result)
                            }.id(result.id)
                        }
                    }.padding(.trailing, 16)
                }
                .onChange(of: workspace.selectedCommandIndex) { _, _ in
                    if let result = workspace.highlightedZoteroResult {
                        proxy.scrollTo(result.id)
                    }
                }
            }
            linkLine
        }
    }

    private func status(_ pane: ZoteroPane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch pane.availability {
            case .notRunning:
                Text(L10n.text("Zotero is not running.")).font(.system(size: 12))
                Text(L10n.text("Open Zotero to search your library. This Project (⌘1) still works."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            case .betterBibTeXMissing:
                Text(L10n.text("Better BibTeX is required.")).font(.system(size: 12))
                Text(L10n.text("Install the Better BibTeX plugin in Zotero, then try again."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            case let .failed(message):
                Text(L10n.text("Zotero could not be searched.")).font(.system(size: 12))
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
            case .checking, .ready:
                if pane.exporting {
                    Text(L10n.text("Getting the entry from Zotero…")).font(.system(size: 12))
                } else if pane.searching {
                    Text(L10n.text("Searching Zotero…")).font(.system(size: 12))
                } else if pane.searchedQuery == nil {
                    Text(L10n.text("Type at least three characters to search Zotero.")).font(.system(size: 12))
                    Text(L10n.text("An author's family name, a title word, a year or a key."))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                } else {
                    Text(L10n.text("No matching items in Zotero")).font(.system(size: 12))
                    Text(L10n
                        .text("Every word must appear in an author's family name, the title, the year or the key."))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var linkLine: some View {
        HStack(spacing: 8) {
            PhosphorIcon(name: "link", size: 12).foregroundStyle(Theme.muted)
            if let link = workspace.zoteroLink {
                Text(L10n.format("Linked: %@ ← “%@”", link.bibliography, link.collectionName))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                Button(L10n.text("Change…")) { workspace.beginZoteroLink() }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                Button(L10n.text("Unlink")) { workspace.unlinkZotero() }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
            } else if workspace.canLinkZotero {
                Button(L10n.text("Link to Zotero…")) { workspace.beginZoteroLink() }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                Text(L10n.text("Choose the project's auto-exported .bib and its collection."))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            } else {
                Text(L10n.text("Open the project folder with File → Open Folder to link it to Zotero."))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.bottom, 4)
    }
}

/// One Zotero item: first author, year, title, key, and whether it is in the
/// linked collection or already in the project.
private struct ZoteroRow: View {
    let result: ZoteroSearch.Result
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let item = result.item
        Button(action: action) {
            HStack(spacing: 11) {
                Text(item.leadAuthor.isEmpty ? "—" : item.leadAuthor)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 130, alignment: .leading)
                Text(item.year.map(String.init) ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .frame(width: 38, alignment: .leading)
                Text(item.title ?? "")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if result.inProject {
                    PhosphorIcon(name: "check", size: 12).foregroundStyle(Theme.accent)
                        .help(L10n.text("Already in a project bibliography file"))
                } else if result.inCollection {
                    PhosphorIcon(name: "folder-simple", size: 12).foregroundStyle(Theme.secondary)
                        .help(L10n.text("In the linked collection"))
                }
                Text(item.key)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }.padding(.horizontal, 12).frame(height: 34).contentShape(Rectangle())
                .background(
                    selected ? Theme.border.opacity(0.75) : (hovered ? Theme.border.opacity(0.35) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 5),
                )
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(Theme.accent).frame(width: 2, height: 16)
                    }
                }
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(Text(accessibilityText))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var accessibilityText: String {
        let item = result.item
        var parts = [item.leadAuthor, item.year.map(String.init) ?? "", item.title ?? "", item.key]
        if result.inProject {
            parts.append(L10n.text("Already in a project bibliography file"))
        } else if result.inCollection {
            parts.append(L10n.text("In the linked collection"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// "Link to Zotero…": the auto-exported file and the collection behind it.
struct ZoteroLinkForm: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let pane = workspace.zotero
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Link this project to Zotero")).font(.system(size: 12, weight: .medium))
            Text(L10n.text(
                "Choose the .bib file Better BibTeX exports automatically and the collection it exports. Prose never writes into that file; results from the collection come first.",
            )).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if pane.linkFiles.isEmpty {
                Text(L10n
                    .text(
                        "This project has no .bib file yet. Point Better BibTeX's automatic export at the project folder first.",
                    ))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            } else {
                Picker(L10n.text("Auto-exported file"), selection: Binding(
                    get: { workspace.zotero.linkFile ?? "" },
                    set: { workspace.zotero.linkFile = $0 },
                )) {
                    ForEach(pane.linkFiles, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 420)
            }
            if pane.linkLoading {
                Text(L10n.text("Reading Zotero's collections…")).font(.system(size: 11))
            } else if !pane.linkCollections.isEmpty {
                Picker(L10n.text("Zotero collection"), selection: Binding(
                    get: { workspace.zotero.linkCollection ?? "" },
                    set: { workspace.zotero.linkCollection = $0 },
                )) {
                    ForEach(pane.linkCollections) { Text($0.path).tag($0.key) }
                }.frame(maxWidth: 420)
            }
            Button { workspace.confirmZoteroLink() } label: {
                HStack(spacing: 14) {
                    Text(L10n.text("Link"))
                    Text("↵").opacity(0.65)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.background)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
                .disabled(pane.linkFile == nil || pane.linkCollection == nil || pane.linkLoading)
        }.padding(.top, 10).padding(.trailing, 24).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The right column on the Zotero tab: the highlighted item in full.
struct ZoteroGuide: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                PhosphorIcon(name: "books", size: 19).foregroundStyle(Theme.accent)
                Text(L10n.text("Cite from Zotero")).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            if let result = workspace.highlightedZoteroResult {
                let item = result.item
                Text(item.title ?? L10n.text("Untitled")).font(.system(size: 11, weight: .medium)).lineLimit(3)
                if !item.authors.isEmpty {
                    Text(item.authors.map(\.display).joined(separator: "; "))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                Text([item.container, item.year.map(String.init)].compactMap(\.self).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                Text(CitationInsertion.citation(item.key))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
                Text(result.inProject ? L10n.text("Already in the project: Prose inserts only the citation.")
                    : L10n.format("Not in the project yet: its entry goes into %@.", ProseBibliography.fileName))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(3)
            } else {
                Text(L10n.text(
                    "Items come from Zotero through Better BibTeX. An item the project does not have yet is added to references-prose.bib.",
                ))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }
            Spacer(minLength: 0)
        }.padding(.top, 9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }
}
