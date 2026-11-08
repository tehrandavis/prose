import ProseCore
import SwiftUI

struct LibraryBrowser: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var library: LibraryController
    @State private var query = ""
    @State private var showingTrash = false
    @State private var results: [LibraryDocument] = []
    @State private var renaming: LibraryDocument?
    @State private var newTitle = ""
    @State private var searchError: String?

    private var browserSize: CGSize {
        DiscoveryLayout.size(for: workspace.window, gallery: false)
    }

    var body: some View {
        if let mode = workspace.discoveryMode {
            UniverseBrowser(
                cacheURL: workspace.stateDirectory.appendingPathComponent("universe-index.json"),
                mode: mode,
                size: DiscoveryLayout.size(for: workspace.window),
                canImport: !workspace.isLibraryHome,
                onBack: { workspace.discoveryMode = nil },
                onClose: { workspace.discoveryMode = nil
                    workspace.libraryOpen = false
                },
                onModeChange: { workspace.discoveryMode = $0 },
                onCreate: library.create(from:),
                onCreateBuiltIn: library.create(builtIn:),
                onAddSample: { try await library.create(sample: $0) },
                onImport: workspace.importPackage,
            )
            .id(mode)
        } else {
            documents
        }
    }

    /// Folders opened in place, most recent first. They are not library
    /// documents: Prose edits their files where they are.
    @ViewBuilder private var folders: some View {
        let recent = workspace.projectStore.recent()
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Folders")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(recent) { record in
                    Button {
                        workspace.libraryOpen = false
                        workspace.openRecentFolder(record)
                    } label: {
                        HStack(spacing: 10) {
                            PhosphorIcon(name: "folder-simple", size: 16).foregroundStyle(Theme.accent)
                            Text(record.name).font(.system(size: 13)).foregroundStyle(Theme.text)
                            Text((record.path as NSString).deletingLastPathComponent
                                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("library.folder." + record.name)
                }
                Text(L10n.text("Documents")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
        }
    }

    private var documents: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Your writing")).font(.system(size: 23, weight: .medium, design: .serif))
                    Text(L10n.text(library.cloudEnabled ? "iCloud Library" : "On this Mac"))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Menu {
                    Button(L10n.text("Open Folder…")) { workspace.openFolderPanel() }
                    Divider()
                    Button(L10n.text("Import a document…")) { library.importPanel() }
                    Button(L10n.text("Import project folder…")) { library.importPanel(project: true) }
                    Divider()
                    Button(L10n.text(showingTrash ? "Show documents" : "Show Trash")) { showingTrash.toggle() }
                } label: { PhosphorIcon(name: "dots-three-vertical", size: 18).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.text("Library actions"))
                Button { workspace.openDiscovery(.templates) } label: {
                    HStack(spacing: 6) {
                        PhosphorIcon(name: "grid-four", size: 15)
                        Text(L10n.text("Browse templates")).font(.system(size: 12))
                    }.foregroundStyle(Theme.secondary).padding(.horizontal, 5).frame(height: 32)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("library-browse-templates")
                    .learningHelp(L10n.text("Start a document from a template"), shortcut: "⌘N")
                if !workspace.isLibraryHome {
                    QuietButton(icon: "x", help: L10n.text("Close library"), shortcut: "Esc") {
                        workspace.libraryOpen = false
                    }
                }
            }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 24)

            HStack(spacing: 11) {
                PhosphorIcon(name: "magnifying-glass", size: 17).foregroundStyle(Theme.muted)
                PaletteTextField(
                    text: $query,
                    label: L10n.text("Search your writing"),
                    placeholder: L10n.text("Search titles and content"),
                )
                if showingTrash {
                    Button(L10n.text("Trash ×")) { showingTrash = false }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
            }.padding(13).background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 30).padding(.bottom, 16)

            if let error = searchError ?? library.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.redText).padding(.horizontal, 30).padding(
                    .bottom,
                    10,
                )
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !showingTrash, query.isEmpty {
                        folders
                    }
                    if results.isEmpty {
                        VStack(spacing: 10) {
                            PhosphorIcon(name: showingTrash ? "clock-counter-clockwise" : "book-open-text", size: 28)
                                .foregroundStyle(Theme.muted)
                            Text(L10n
                                .text(query
                                    .isEmpty ? (showingTrash ? "Trash is empty" : "A place for your next idea") :
                                    "No matching documents"))
                                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 260)
                    }
                    ForEach(results) { document in row(document) }
                }.padding(.horizontal, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(results.count == 1 ? L10n.text("1 document") : L10n.format("%d documents", results.count))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                if library.busy {
                    ProgressView().controlSize(.small)
                }
                if showingTrash {
                    Button(action: library.confirmEmptyTrash) {
                        HStack(spacing: 6) {
                            PhosphorIcon(name: "trash", size: 13)
                            Text(L10n.text("Empty Trash…"))
                        }.font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                        .disabled(!library.documents.contains(where: \.isTrashed))
                        .accessibilityIdentifier("library-empty-trash")
                        .learningHelp(L10n.text("Permanently delete all documents in Trash"))
                } else {
                    Text(L10n.text("Your writing saves automatically.")).font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 30).padding(.vertical, 15)
        }
        .frame(width: browserSize.width, height: browserSize.height)
        .background(Theme.editor).foregroundStyle(Theme.text)
        .disabled(library.busy)
        .task { await library.start()
            await search()
        }
        .task(id: query + String(showingTrash)) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await search()
        }
        .onReceive(library.$documents) { _ in Task { await search() } }
        .onExitCommand { workspace.libraryOpen = false }
        .alert(
            L10n.text("Rename document"),
            isPresented: Binding(get: { renaming != nil }, set: {
                if !$0 {
                    renaming = nil
                }
            }),
        ) {
            TextField(L10n.text("Title"), text: $newTitle)
            Button(L10n.text("Cancel"), role: .cancel) { renaming = nil }
            Button(L10n.text("Rename")) {
                if let document = renaming {
                    library.perform { try await library.rename(document.id, title: newTitle) }
                }
                renaming = nil
            }
        }
    }

    private func row(_ document: LibraryDocument) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule().fill(workspace.managedDocumentID == document.id ? Theme.accent.opacity(0.8) : .clear)
                .frame(width: 2, height: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                if showingTrash {
                    Text(document.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                } else {
                    EditableDocumentName(
                        title: document.title,
                        documentID: document.id,
                        fontSize: 14,
                        identifier: "library-title-\(document.id)",
                        help: "Click to rename. Double-click to open.",
                        onOpen: { library.perform { try await library.open(document.id) } },
                        onRename: { title in library.perform { try await library.rename(
                            document.id,
                            title: title,
                        ) } },
                    )
                    .frame(height: 20)
                    .learningHelp(L10n.text("Click to rename. Double-click to open."))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(document.snippet.isEmpty ? L10n.text("Empty document") : document.snippet)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                    Text(document.modifiedAt, style: .relative).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if !showingTrash {
                            library.perform { try await library.open(document.id) }
                        }
                    }
            }.frame(maxWidth: .infinity, alignment: .leading)
            QuietButton(
                icon: showingTrash ? "arrow-counter-clockwise" : "trash",
                help: L10n.text(showingTrash ? "Restore" : "Move to Trash"),
            ) {
                library.perform {
                    if showingTrash {
                        try await library.restore(document.id)
                    } else {
                        try await library.moveToTrash(document.id)
                    }
                }
            }.accessibilityIdentifier("library-\(showingTrash ? "restore" : "trash")-\(document.id)")
        }.padding(.vertical, 16).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                if showingTrash {
                    Button(L10n.text("Restore")) { library.perform { try await library.restore(document.id) } }
                } else {
                    Button(L10n.text("Rename…")) { renaming = document
                        newTitle = document.title
                    }
                    Button(L10n.text("Export source project…")) { library.exportPanel(document) }
                    Button(L10n.text("Show source in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([document.sourceURL])
                    }
                    Divider()
                    Button(L10n.text("Move to Trash")) { library.perform { try await library.moveToTrash(document.id) }
                    }
                }
            }
    }

    private func search() async {
        let request = query, trash = showingTrash
        do {
            let matches = try await library.store.list(query: request, includeTrashed: true)
            guard request == query, trash == showingTrash else {
                return
            }
            results = matches.filter { ($0.trashedAt != nil) == trash }
            searchError = nil
        } catch { searchError = error.localizedDescription }
    }
}
