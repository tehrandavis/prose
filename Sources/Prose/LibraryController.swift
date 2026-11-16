import AppKit
import Combine
import ProseCore
import UniformTypeIdentifiers

/// Keeps library navigation separate from the live editor buffer. Disk operations
/// run on the library actor; switching documents always passes through Workspace.
@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var cloudEnabled = false
    @Published private(set) var syncMessage = ""
    let store: DocumentLibrary
    private weak var workspace: Workspace?
    private var monitor: LibraryFileMonitor?
    private var cloudQuery: LibraryCloudQuery?
    private var refreshTask: Task<Void, Never>?
    private var started = false
    private var accountMonitor: LibraryAccountMonitor?
    private let locationURL: URL
    private let recentURL: URL
    private let blankPageURL: URL
    /// Library documents opened, most recent first. Published so the blank
    /// page's sidebar recents follow it.
    @Published private(set) var recentDocumentIDs: [UUID]
    /// The untouched blank page (Phase 7, decision 2), stored in
    /// `blank-page.json`, local to this Mac. There is at most one. The first
    /// edit or rename clears it, and the page is an ordinary document.
    @Published private(set) var blankPageID: UUID?
    static let recentLimit = 50
    var onSyncChange: ((Bool) -> Void)?

    init(
        workspace: Workspace,
        cloudResolver: @escaping DocumentLibrary.CloudResolver = { try LibraryCloudEnvironment.containerURL() },
    ) {
        self.workspace = workspace
        locationURL = workspace.stateDirectory.appendingPathComponent("library-location.json")
        recentURL = workspace.stateDirectory.appendingPathComponent("recent-documents.json")
        blankPageURL = workspace.stateDirectory.appendingPathComponent("blank-page.json")
        recentDocumentIDs = (try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: recentURL))) ?? []
        blankPageID = try? JSONDecoder().decode(UUID.self, from: Data(contentsOf: blankPageURL))
        store = DocumentLibrary(
            rootURL: workspace.stateDirectory.appendingPathComponent("Library"),
            cloudResolver: cloudResolver,
        )
    }

    /// False before `start()` and after iCloud failed to resume in it.
    var isStarted: Bool {
        started
    }

    func start() async {
        guard !started else {
            return
        }
        started = true
        let savedLocation = try? Data(contentsOf: locationURL)
        if savedLocation == Data("icloud".utf8) {
            do { _ = try await store.resumeICloud()
                cloudEnabled = true
                onSyncChange?(true)
            } catch {
                self.error = error.localizedDescription
                // The cached recovery buffer remains open; a stale local backup
                // must never masquerade as the current cloud library.
                started = false
                return
            }
        }
        await refresh()
        if let workspace, let url = workspace.fileURL {
            associate(url)
            // A blank page restored at launch and typed in before this point
            // had no document id yet, so `edited()` could not keep it.
            if let id = blankPageID, id == workspace.managedDocumentID,
               workspace.text != DocumentTemplate.blank.source
            {
                keepBlankPage()
            }
            if documents.contains(where: { $0.id == workspace.managedDocumentID && $0.trashedAt != nil }) {
                // A blank page takes the trashed document's place (Phase 7, decision 3).
                await workspace.showBlankPage()
            }
        } else if let workspace, !workspace.isLibraryHome, !workspace.launchPending {
            // One-time adoption of the previous single-draft model.
            do {
                let mark = workspace.stateDirectory.appendingPathComponent(WelcomeDocument.markFilename)
                let assets = (try? Data(contentsOf: mark)).map { [WelcomeDocument.markFilename: $0] } ?? [:]
                try await create(title: L10n.text("Welcome"), text: workspace.text, assets: assets)
            } catch { self.error = error.localizedDescription }
        }
        if savedLocation == nil {
            do { try await setCloudEnabled(true) }
            catch { syncMessage = error.localizedDescription }
        }
        await observeRoot()
        accountMonitor = LibraryAccountMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncMessage = L10n.text("iCloud account changed. Check sync in Settings.")
                self?.onSyncChange?(false)
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        do {
            documents = try await store.list(includeTrashed: true)
            error = await store.issues.first?.message
            if let workspace, let url = workspace.fileURL {
                associate(url)
            }
        } catch { self.error = error.localizedDescription }
    }

    func associate(_ url: URL) {
        let entry = (workspace?.mainFileURL ?? url).resolvingSymlinksInPath().standardizedFileURL
        let document = documents.first { $0.sourceURL.resolvingSymlinksInPath().standardizedFileURL == entry }
        workspace?.managedDocumentID = document?.id
        workspace?.managedTitle = document?.title
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy, workspace?.agentMetadataChangeInProgress != true else {
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do { try await action()
                error = nil
            } catch { self.error = error.localizedDescription
                workspace?.showMessage(error.localizedDescription, persistent: true)
            }
        }
    }

    func create(
        title: String? = nil,
        text: String? = nil,
        template: DocumentTemplate? = nil,
        assets: [String: Data] = [:],
    ) async throws {
        let selected = template ?? .blank
        let content = text ?? selected.source
        let document = try await store.create(
            title: title ?? L10n.text(selected == .codeNotes ? "Code notes" : "Untitled"),
            text: content,
            assets: assets,
        )
        await refresh()
        try await open(document.id)
    }

    func create(builtIn template: BuiltInTemplate) async throws {
        // The gallery's "Blank page" follows the reuse rule of `openBlankPage`.
        if template == .blank {
            try await openBlankPage()
            return
        }
        let assets = template == .welcome ? try WelcomeDocument.assets() : [:]
        try await create(
            title: template == .welcome ? L10n.text("Welcome") : nil,
            text: template.source,
            assets: assets,
        )
        if template == .welcome {
            workspace?.layout = .split
        }
    }

    /// A dedicated resolver keeps template downloads independent of the live
    /// document service, including when the library is empty or compilation is busy.
    func create(from package: UniversePackage) async throws {
        guard let workspace, !busy else {
            throw LibraryInteractionError.operationInProgress
        }
        busy = true
        defer { busy = false }
        let staging = workspace.stateDirectory.appendingPathComponent("TemplateDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let client = TinymistClient()
        defer { client.stop() }
        let project = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await client.start(
                root: staging,
                outputDirectory: workspace.stateDirectory.appendingPathComponent("Exports"),
            )
            return try await UniverseTemplateInstaller.materialize(package, using: client, in: staging)
        } onCancel: {
            Task { @MainActor in client.stop() }
        }
        defer { try? FileManager.default.removeItem(at: project.directoryURL) }
        try Task.checkCancellation()
        let document = try await store.importProject(
            at: project.directoryURL,
            mainFile: project.mainFileURL,
            title: package.name,
        )
        await refresh()
        try await open(document.id)
        workspace.recordOperation("library.createTemplate", ["package": package.name, "version": package.version])
    }

    func create(sample: SampleBook, using suppliedStore: SampleBookStore? = nil) async throws {
        guard let workspace, !busy else {
            throw LibraryInteractionError.operationInProgress
        }
        busy = true
        defer { busy = false }
        let books = suppliedStore ??
            SampleBookStore(cacheURL: workspace.stateDirectory.appendingPathComponent("SampleBooks"))
        let project = try await books.materialize(
            sample,
            in: workspace.stateDirectory.appendingPathComponent("SampleDownloads"),
        )
        defer { try? FileManager.default.removeItem(at: project.directoryURL) }
        try Task.checkCancellation()
        let document = try await store.importProject(
            at: project.directoryURL,
            mainFile: project.mainFileURL,
            title: sample.title,
        )
        await refresh()
        try await open(document.id)
        workspace.recordOperation("library.createExample", ["book": sample.rawValue])
    }

    func open(_ id: UUID) async throws {
        guard let workspace else {
            return
        }
        let result = try await store.read(id)
        guard result.document.trashedAt == nil else {
            throw LibraryInteractionError.restoreFirst
        }
        guard workspace.open(result.document.sourceURL) else {
            throw LibraryInteractionError.couldNotOpen
        }
        workspace.managedDocumentID = result.document.id
        workspace.managedTitle = result.document.title
        noteOpened(result.document.id)
        workspace.onTitleChange?(workspace.title)
        workspace.libraryOpen = false
    }

    func noteOpened(_ id: UUID) {
        // An untouched blank page is never a recent to return to.
        guard recentDocumentIDs.first != id, !isUntouchedBlankPage(id) else {
            return
        }
        updateRecent { $0 = [id] + $0.filter { $0 != id } }
    }

    func forgetRecent(_ id: UUID) {
        updateRecent { $0.removeAll { $0 == id } }
    }

    /// Recently opened documents that can still be reopened, most recent first.
    var reopenableRecentIDs: [UUID] {
        let available = Set(listedDocuments.filter { !$0.isTrashed }.map(\.id))
        return recentDocumentIDs.filter { available.contains($0) }
    }

    // MARK: The blank page (Phase 7, decision 2)

    /// Whether `id` is the untouched blank page, which no list shows.
    func isUntouchedBlankPage(_ id: UUID) -> Bool {
        id == blankPageID
    }

    /// The library's documents (Trash included) without the untouched blank
    /// page: what the writer's lists show.
    var listedDocuments: [LibraryDocument] {
        guard let blankPageID else {
            return documents
        }
        return documents.filter { $0.id != blankPageID }
    }

    /// Opens the untouched blank page, or makes one. Nothing happens when it is
    /// already open, so repeated requests never make a second one. The page
    /// opens in Writing mode with the caret on its empty last line.
    func openBlankPage() async throws {
        guard let workspace else {
            return
        }
        let source = DocumentTemplate.blank.source
        if let id = blankPageID {
            if workspace.managedDocumentID == id, !workspace.isLibraryHome {
                workspace.libraryOpen = false
                return
            }
            if await (try? store.isUntouched(id, expecting: source)) == true {
                try await showBlankPage(id)
                return
            }
            // Gone, trashed or changed elsewhere: from now on an ordinary document.
            setBlankPage(nil)
        }
        let document = try await store.create(title: L10n.text("Untitled"), text: source)
        setBlankPage(document.id)
        workspace.recordOperation("library.blankPage", ["documentID": document.id.uuidString])
        await refresh()
        try await showBlankPage(document.id)
    }

    private func showBlankPage(_ id: UUID) async throws {
        guard let workspace else {
            return
        }
        try await open(id)
        workspace.setMode(.writing)
        workspace.jump(to: workspace.text.utf16.count, synchronizePreview: false)
    }

    /// The first edit or rename keeps the page: it becomes an ordinary
    /// document and a recent like any other.
    func keepBlankPage() {
        guard let id = blankPageID else {
            return
        }
        setBlankPage(nil)
        workspace?.recordOperation("library.blankPageKept", ["documentID": id.uuidString])
        if workspace?.managedDocumentID == id {
            noteOpened(id)
        }
    }

    /// The writer left the untouched blank page for another document or a
    /// folder: delete it for good if it is still untouched, else keep it.
    func leaveBlankPage(_ id: UUID) {
        guard isUntouchedBlankPage(id) else {
            return
        }
        setBlankPage(nil)
        forgetRecent(id)
        Task { [weak self] in
            guard let self else {
                return
            }
            let discarded: Bool
            do { discarded = try await store.discardUntouched(id, expecting: DocumentTemplate.blank.source) }
            catch { discarded = false }
            workspace?.recordOperation(
                discarded ? "library.blankPageDiscarded" : "library.blankPageKept",
                ["documentID": id.uuidString],
            )
            await refresh()
        }
    }

    /// Shows an error from a library action that ran outside `perform`.
    func report(_ error: Error) {
        self.error = error.localizedDescription
    }

    private func setBlankPage(_ id: UUID?) {
        guard blankPageID != id else {
            return
        }
        blankPageID = id
        do {
            if let id {
                try JSONEncoder().encode(id).write(to: blankPageURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: blankPageURL.path) {
                try FileManager.default.removeItem(at: blankPageURL)
            }
        } catch { workspace?.recordOperation("library.blankPageFailed", ["error": error.localizedDescription]) }
    }

    private func updateRecent(_ change: (inout [UUID]) -> Void) {
        let previous = recentDocumentIDs
        change(&recentDocumentIDs)
        recentDocumentIDs = Array(recentDocumentIDs.prefix(Self.recentLimit))
        guard recentDocumentIDs != previous else {
            return
        }
        do { try JSONEncoder().encode(recentDocumentIDs).write(to: recentURL, options: .atomic) }
        catch { workspace?.recordOperation("library.recentFailed", ["error": error.localizedDescription]) }
    }

    func rename(_ id: UUID, title: String) async throws {
        _ = try await store.rename(id, title: title)
        if isUntouchedBlankPage(id) {
            keepBlankPage()
        }
        await refresh()
        if workspace?.managedDocumentID == id, let workspace {
            workspace.onTitleChange?(workspace.title)
        }
        workspace?.recordOperation("library.rename", ["documentID": id.uuidString])
    }

    func moveToTrash(_ id: UUID) async throws {
        guard let workspace else {
            return
        }
        let wasActive = workspace.managedDocumentID == id
        if wasActive {
            workspace.documentTransitionInProgress = true
            workspace.editor?.isEditable = false
        }
        defer {
            if wasActive {
                workspace.documentTransitionInProgress = false
                workspace.editor?.isEditable = workspace.editorIsEditable
            }
        }
        if wasActive {
            workspace.save()
            guard workspace.text == workspace.savedText else {
                throw LibraryInteractionError.saveFirst
            }
        }
        _ = try await store.trash(id)
        forgetRecent(id)
        if isUntouchedBlankPage(id) {
            setBlankPage(nil)
        }
        workspace.recordOperation("library.trash", ["documentID": id.uuidString, "active": String(wasActive)])
        await refresh()
        if wasActive {
            // A blank page takes the trashed document's place (Phase 7, decision 3).
            await workspace.showBlankPage()
        }
    }

    func restore(_ id: UUID) async throws {
        _ = try await store.restore(id)
        await refresh()
        workspace?.recordOperation("library.restore", ["documentID": id.uuidString])
    }

    func confirmEmptyTrash() {
        guard let owner = workspace?.window ?? workspace?.editor?.window else {
            return
        }
        let window = owner.attachedSheet ?? owner
        guard window.attachedSheet == nil else {
            return
        }
        perform { [self] in
            let snapshot = try await store.trashSnapshot()
            guard !snapshot.isEmpty else {
                await refresh()
                return
            }
            let alert = NSAlert()
            alert.messageText = L10n.text("Empty Trash?")
            alert.informativeText = L10n.format(
                "Permanently delete %d documents and their attachments? This cannot be undone.",
                snapshot.count,
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.text("Cancel"))
            alert.addButton(withTitle: L10n.text("Empty Trash"))
            alert.buttons[1].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self else {
                    return
                }
                perform { try await self.emptyTrash(snapshot) }
            }
        }
    }

    func emptyTrash(_ snapshot: LibraryTrashSnapshot) async throws {
        let result = try await store.emptyTrash(snapshot)
        await refresh()
        workspace?.recordOperation(
            "library.emptyTrash",
            ["deleted": String(result.deletedCount), "failed": String(result.issues.count)],
        )
        if let issue = result.issues.first {
            throw CommandError.invalid(L10n.format(
                "%d documents deleted. Some items could not be removed: %@",
                result.deletedCount,
                issue.message,
            ))
        }
    }

    func importDocument(_ url: URL) async throws {
        let document = try await store.importDocument(at: url)
        await refresh()
        try await open(document.id)
    }

    func importProject(_ folder: URL, mainFile: URL) async throws {
        let document = try await store.importProject(at: folder, mainFile: mainFile)
        await refresh()
        try await open(document.id)
    }

    func importPanel(project: Bool = false) {
        guard let owner = workspace?.window ?? workspace?.editor?.window else {
            return
        }
        let window = owner.attachedSheet ?? owner
        guard window.attachedSheet == nil else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.text(project ? "Import project folder" : "Import a document")
        panel.canChooseDirectories = project
        panel.canChooseFiles = !project
        panel.allowsMultipleSelection = false
        if !project {
            panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            if project {
                chooseProjectEntry(in: url, window: window)
            } else {
                perform { try await self.importDocument(url) }
            }
        }
    }

    private func chooseProjectEntry(in folder: URL, window: NSWindow) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose the project's main document")
        panel.directoryURL = folder
        panel.allowedContentTypes = [UTType(filenameExtension: "typ") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let mainFile = panel.url, let self else {
                return
            }
            perform { try await self.importProject(folder, mainFile: mainFile) }
        }
    }

    func exportProject(_ id: UUID, to destination: URL) async throws {
        if workspace?.managedDocumentID == id {
            workspace?.save()
            guard workspace?.text == workspace?.savedText else {
                throw LibraryInteractionError.saveFirst
            }
        }
        try await store.exportProject(id, to: destination)
    }

    func exportPanel(_ document: LibraryDocument) {
        guard let owner = workspace?.window ?? workspace?.editor?.window else {
            return
        }
        let window = owner.attachedSheet ?? owner
        guard window.attachedSheet == nil else {
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("Export source project")
        panel.nameFieldStringValue = document.title
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            perform { try await self.exportProject(document.id, to: url) }
        }
    }

    func setCloudEnabled(_ enabled: Bool) async throws {
        guard let workspace else {
            return
        }
        guard !workspace.agentMetadataChangeInProgress else {
            throw AgentToolError("busy", "An agent is updating the document library. Try again after it finishes.")
        }
        if enabled == cloudEnabled {
            try Data(enabled ? "icloud".utf8 : "local".utf8).write(to: locationURL, options: .atomic)
            return
        }
        if workspace.fileURL != nil {
            workspace.save()
        }
        guard workspace.fileURL == nil || workspace.text == workspace.savedText
        else {
            throw LibraryInteractionError.saveFirst
        }
        let currentID = workspace.managedDocumentID
        workspace.documentTransitionInProgress = true
        workspace.editor?.isEditable = false
        defer {
            workspace.documentTransitionInProgress = false
            workspace.editor?.isEditable = workspace.editorIsEditable
        }
        let report = try await store.setICloudEnabled(enabled)
        updateRecent { $0 = $0.map { report.idMappings[$0] ?? $0 } }
        if let id = blankPageID, let mapped = report.idMappings[id] {
            setBlankPage(mapped)
        }
        cloudEnabled = report.isICloud
        try Data(enabled ? "icloud".utf8 : "local".utf8).write(to: locationURL, options: .atomic)
        onSyncChange?(enabled)
        syncMessage = enabled ? L10n.text("iCloud Drive manages uploads and downloads.") : L10n
            .text("Saved on this Mac")
        await refresh()
        await observeRoot()
        if let currentID {
            try await open(report.idMappings[currentID] ?? currentID)
        }
    }

    private func observeRoot() async {
        monitor?.stop()
        cloudQuery = nil
        let root = await store.rootURL
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                refreshTask?.cancel()
                refreshTask = Task {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    await self.refresh()
                    await self.workspace?.refreshFromLibrary()
                }
            }
        }
        monitor = LibraryFileMonitor(rootURL: root, onChange: changed)
        if cloudEnabled {
            cloudQuery = LibraryCloudQuery(rootURL: root, onChange: changed)
        }
    }

    func stop() {
        refreshTask?.cancel()
        monitor?.stop()
        monitor = nil
        accountMonitor = nil
        cloudQuery = nil
    }
}

enum LibraryInteractionError: LocalizedError {
    case saveFirst
    case restoreFirst
    case couldNotOpen
    case operationInProgress
    var errorDescription: String? {
        switch self {
        case .operationInProgress: L10n.text("Another library operation is in progress. Try again in a moment.")
        case .saveFirst: L10n.text("Resolve the current save conflict before continuing.")
        case .restoreFirst: L10n.text("Restore this document from Trash before opening it.")
        case .couldNotOpen: L10n.text("The document could not be opened. Your current writing is preserved.")
        }
    }
}
