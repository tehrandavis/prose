import AppKit
import CoreServices
import ProseCore
import Quartz
import UniformTypeIdentifiers

/// The folder shown in the sidebar: a folder opened in place, or the folder of
/// a library document.
struct OpenProject: Equatable {
    enum Kind: Equatable {
        /// A folder edited in place, remembered in `ProjectStore`.
        case folder(ProjectRecord)
        /// A library document; its main entry is fixed by the library.
        case library(UUID)
    }

    let root: URL
    var main: URL?
    var kind: Kind
    /// Folders the reader has expanded, relative to the root.
    var expanded: Set<String> = []

    var name: String {
        switch kind {
        case let .folder(record): record.name
        case .library: root.lastPathComponent
        }
    }

    var canChangeMain: Bool {
        if case .folder = kind {
            return true
        }
        return false
    }

    func contains(_ url: URL) -> Bool {
        (try? ProjectTree.relativePath(of: url, in: root)) != nil
    }

    /// Files Prose keeps beside a library document that are not the writer's.
    static let hiddenLibraryFiles: Set = ["document.json"]
}

extension Workspace {
    func openFolderPanel() {
        recordOperation("folder.dialog")
        let panel = NSOpenPanel()
        panel.title = L10n.text("Open Folder")
        panel.prompt = L10n.text("Open")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        present(panel) { [weak self] url in self?.openFolder(url) }
    }

    /// Opens a folder in place and its main entry, if it has one.
    @discardableResult
    func openFolder(_ url: URL) -> Bool {
        recordOperation("folder.open")
        do {
            let record = try projectStore.remember(url)
            return openRemembered(record, at: url.standardizedFileURL)
        } catch {
            showMessage(error.localizedDescription, persistent: true)
            return false
        }
    }

    /// Reopens a folder from the recent list. A folder that is gone is dropped.
    @discardableResult
    func openRecentFolder(_ record: ProjectRecord) -> Bool {
        do {
            let root = try projectStore.resolve(record)
            let current = projectStore.recent().first { $0.id == record.id } ?? record
            return openRemembered(try projectStore.remember(root), at: root, previous: current)
        } catch {
            try? projectStore.forget(record.id)
            showMessage(error.localizedDescription, persistent: true)
            return false
        }
    }

    private func openRemembered(_ record: ProjectRecord, at root: URL, previous: ProjectRecord? = nil) -> Bool {
        if ProjectStore.isSandboxed {
            _ = root.startAccessingSecurityScopedResource()
        }
        let main = (previous?.mainEntry ?? record.mainEntry).map { root.appendingPathComponent($0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.standardizedFileURL : nil }
            ?? ProjectTree.defaultMainEntry(in: root)
        project = OpenProject(root: root, main: main, kind: .folder(record), expanded: Set(record.expanded))
        sidebarVisible = true
        watchProject()
        guard let main else {
            showMessage(L10n.text("This folder has no Typst file yet. Create one with the + button in the sidebar."))
            return true
        }
        if main.standardizedFileURL == fileURL?.standardizedFileURL {
            mainFileURL = nil
            startService(reusingEngine: false)
            return true
        }
        return open(main)
    }

    /// The main entry that compiles `url`, if `url` belongs to the open project.
    func projectMain(for url: URL) -> URL? {
        guard let project, project.contains(url) else {
            return nil
        }
        return project.main
    }

    /// Keeps the sidebar's project in step with the open file.
    func updateProject(for url: URL) {
        if let project, project.contains(url) {
            return
        }
        if let id = managedDocumentID {
            let folder = url.deletingLastPathComponent()
            let projectFolder = folder.appendingPathComponent("Project")
            let root = url.path.hasPrefix(projectFolder.path + "/") ? projectFolder : folder
            project = OpenProject(root: root.standardizedFileURL, main: url.standardizedFileURL, kind: .library(id))
        } else if let record = projectStore.recent().first(where: {
            // Both sides resolve symbolic links, such as /tmp and /private/tmp.
            (try? ProjectTree.relativePath(of: url, in: URL(fileURLWithPath: $0.path, isDirectory: true))) != nil
        }) {
            // A file reopened after relaunch belongs to its remembered folder.
            let root = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
            project = OpenProject(
                root: root,
                main: record.mainEntry.map { root.appendingPathComponent($0).standardizedFileURL },
                kind: .folder(record),
                expanded: Set(record.expanded),
            )
            if let main = project?.main, main != url.standardizedFileURL {
                mainFileURL = main
            }
            sidebarVisible = true
        } else {
            project = nil
        }
        watchProject()
    }

    /// Opens a file chosen in the sidebar. Typst files open in the editor;
    /// other files open in Quick Look.
    func openProjectFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "typ" else {
            recordOperation("project.preview")
            previewFile(url)
            return
        }
        guard url.standardizedFileURL != fileURL?.standardizedFileURL else {
            return
        }
        recordOperation("project.openFile")
        open(url)
    }

    func setMainEntry(_ url: URL) {
        guard var project, project.canChangeMain, case var .folder(record) = project.kind,
              url.pathExtension.lowercased() == "typ",
              let relative = try? ProjectTree.relativePath(of: url, in: project.root)
        else {
            return
        }
        recordOperation("project.main")
        record.mainEntry = relative
        try? projectStore.update(record)
        project.main = url.standardizedFileURL
        project.kind = .folder(record)
        self.project = project
        try? flushChanges()
        mainFileURL = url.standardizedFileURL == fileURL?.standardizedFileURL ? nil : url.standardizedFileURL
        startService(reusingEngine: false)
    }

    func toggleProjectFolder(_ url: URL) {
        guard var project, let relative = try? ProjectTree.relativePath(of: url, in: project.root) else {
            return
        }
        if project.expanded.contains(relative) {
            project.expanded.remove(relative)
        } else {
            project.expanded.insert(relative)
        }
        self.project = project
        if case var .folder(record) = project.kind {
            record.expanded = project.expanded.sorted()
            try? projectStore.update(record)
            self.project?.kind = .folder(record)
        }
    }

    func createProjectFile(in directory: URL, named name: String) {
        projectOperation("project.createFile") { root in
            let url = try ProjectTree.createFile(named: name, in: directory, root: root)
            if url.pathExtension.lowercased() == "typ" {
                if project?.main == nil {
                    setMainEntry(url)
                }
                open(url)
            }
        }
    }

    func createProjectFolder(in directory: URL, named name: String) {
        projectOperation("project.createFolder") { root in
            let folder = try ProjectTree.createFolder(named: name, in: directory, root: root)
            if let relative = try? ProjectTree.relativePath(of: directory, in: root), !relative.isEmpty {
                project?.expanded.insert(relative)
            }
            _ = folder
        }
    }

    func renameProjectItem(_ url: URL, to name: String) {
        projectOperation("project.rename") { root in
            let wasOpen = fileURL.map { $0.standardizedFileURL == url.standardizedFileURL } ?? false
            if wasOpen {
                try? flushChanges()
                _ = preserveForMove()
            }
            let renamed = try ProjectTree.rename(url, to: name, root: root)
            if project?.main?.standardizedFileURL == url.standardizedFileURL {
                setMainEntry(renamed)
            }
            if wasOpen {
                open(renamed)
            }
        }
    }

    func trashProjectItem(_ url: URL) {
        projectOperation("project.trash") { root in
            if url.standardizedFileURL == project?.main?.standardizedFileURL {
                throw ProjectActionError.mainEntry
            }
            if let fileURL, fileURL.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path) {
                throw ProjectActionError.openFile
            }
            try ProjectTree.trash(url, root: root)
        }
    }

    func revealProjectItem(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func projectOperation(_ name: String, _ body: (URL) throws -> Void) {
        guard let root = project?.root else {
            return
        }
        recordOperation(name)
        do {
            try body(root)
        } catch {
            showMessage(error.localizedDescription, persistent: true)
        }
        projectRevision += 1
    }

    /// Saves the open file before it is renamed, so the rename moves saved text.
    private func preserveForMove() -> Bool {
        if fileURL != nil, text != savedText {
            save()
        }
        return text == savedText
    }

    private func watchProject() {
        let root = project?.root
        if projectWatcher?.root == root {
            return
        }
        projectWatcher?.stop()
        projectWatcher = root.map { root in
            ProjectWatcher(root: root) { [weak self] in self?.projectRevision += 1 }
        }
    }
}

enum ProjectActionError: LocalizedError {
    case mainEntry
    case openFile
    var errorDescription: String? {
        switch self {
        case .mainEntry: L10n.text("Choose another main document before moving this one to the Trash.")
        case .openFile: L10n.text("Open another file before moving this one to the Trash.")
        }
    }
}

/// Reports changes anywhere under a folder through FSEvents. The stream runs on
/// the main queue, so callbacks are on the main actor; `stop()` is main-only.
final class ProjectWatcher: @unchecked Sendable {
    let root: URL
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor @Sendable () -> Void

    init(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.root = root
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else {
                return
            }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer),
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        stop()
    }
}

/// Shows one file in the system Quick Look panel.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPreview()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
