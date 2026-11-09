import Foundation
import ProseCore

/// What a Writing mode engine is opened for: the project root and the main
/// entry. Files of one project share one engine.
struct WritingEngineKey: Equatable {
    let root: URL
    let main: URL
}

/// The life of Writing mode's engine (decision 10 of the Phase 3 note): one
/// `BlockRenderer` per open project, created off the main thread the first time
/// Writing mode is entered, kept across files of the project, freed when the
/// project changes or the window closes.
extension Workspace {
    /// The project root and main entry for the open file; for a file outside
    /// any project, its folder and the file it compiles.
    var writingEngineKey: WritingEngineKey {
        let main = compilationURL.standardizedFileURL
        if let project, project.contains(main) {
            return WritingEngineKey(root: project.root.standardizedFileURL, main: main)
        }
        return WritingEngineKey(root: main.deletingLastPathComponent(), main: main)
    }

    /// Brings Writing mode in step with the mode, the open file and its
    /// project. `reload` means the editor's text was replaced.
    func updateWritingMode(reload: Bool = false) {
        guard let editor else {
            return
        }
        if isLibraryHome {
            editor.writing.stop()
            freeWritingEngine()
            return
        }
        let key = writingEngineKey
        if let engine = writingEngine, engine.key != key {
            freeWritingEngine()
        }
        guard editorMode != .code else {
            editor.writing.stop()
            editor.writing.setFocus(false)
            return
        }
        // Focus changes the scale and the column of a running model through
        // Writing mode's entry path; a model that starts later starts with it.
        editor.writing.setFocus(editorMode == .focus)
        if let engine = writingEngine {
            editor.writing.start(renderer: engine.renderer, file: documentURL, reload: reload)
        } else if writingEngineRequest != key {
            editor.writing.stop()
            createWritingEngine(for: key)
        }
    }

    /// Stops Writing mode in the editor and releases the engine.
    func freeWritingEngine() {
        writingEngineGeneration += 1
        writingEngineTask?.cancel()
        writingEngineTask = nil
        writingEngineRequest = nil
        projectChangeTask?.cancel()
        projectChangeTask = nil
        pendingProjectChanges = []
        if writingEngine != nil {
            recordOperation("writing.engineFreed")
        }
        writingEngine = nil
        editor?.writing.detach()
    }

    func createWritingEngine(for key: WritingEngineKey) {
        writingEngineTask?.cancel()
        writingEngineGeneration += 1
        let generation = writingEngineGeneration
        writingEngineRequest = key
        recordOperation("writing.engineStart")
        if fileURL == nil {
            // The draft compiles from disk; the engine needs it to exist.
            _ = try? DocumentStorage.write(text, to: draftURL, baseline: nil)
        }
        let packages = BlockRenderer.defaultPackageDirectories(packageCache: packageCache)
        writingEngineTask = Task {
            // The font scan takes about 180 ms; keep it off the main thread.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<
                BlockRenderer,
                BlockRendererError,
            > in
                do {
                    return try await .success(BlockRenderer(
                        root: key.root,
                        main: key.main,
                        packageDirectories: packages,
                    ))
                } catch {
                    return .failure(BlockRendererError(error.localizedDescription))
                }
            }.value
            guard generation == writingEngineGeneration else {
                return
            }
            writingEngineTask = nil
            writingEngineRequest = nil
            switch result {
            case let .success(renderer):
                writingEngine = (key, renderer)
                writingEnginesCreated += 1
                recordOperation("writing.engineReady")
                updateWritingMode()
            case let .failure(error):
                recordOperation("writing.engineFailed", ["error": error.message])
                editorMode = .code
                updateWritingMode()
                showMessage(error.message, persistent: true)
            }
        }
    }

    /// Files of the project changed on disk. A burst of changes is passed on
    /// once it pauses for `projectChangeDelay` (citations note, decision 1):
    /// Typst files other than the open one go to the engine as text, as the
    /// editor's buffers do, and every changed file is reported to it, so it
    /// reads bibliographies, data and images again. When the document read any
    /// of them, Writing mode compiles it again and re-renders the blocks in view;
    /// the engine's cache compiles only those whose result can have changed.
    /// The open file's text is the editor's.
    func projectFilesChanged(_ files: [URL]) {
        guard let engine = writingEngine else {
            return
        }
        for file in files {
            guard let relative = try? ProjectTree.relativePath(of: file, in: engine.key.root) else {
                continue
            }
            let url = engine.key.root.appendingPathComponent(relative).standardizedFileURL
            if !pendingProjectChanges.contains(url) {
                pendingProjectChanges.append(url)
            }
        }
        guard !pendingProjectChanges.isEmpty else {
            return
        }
        projectChangeTask?.cancel()
        let delay = projectChangeDelay
        projectChangeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.applyProjectChanges()
        }
    }

    private func applyProjectChanges() {
        projectChangeTask = nil
        let open = documentURL.standardizedFileURL
        let changed = pendingProjectChanges.filter { $0 != open }
        pendingProjectChanges = []
        guard let renderer = writingEngine?.renderer, !changed.isEmpty else {
            return
        }
        Task {
            for url in changed where url.pathExtension.lowercased() == "typ" {
                let text = await Task.detached { try? DocumentStorage.read(url).0 }.value
                guard let text, writingEngine?.renderer === renderer else {
                    continue
                }
                try? await renderer.setText(text, of: url)
                writingDiskUpdates += 1
            }
            guard writingEngine?.renderer === renderer else {
                return
            }
            let read = await renderer.filesChanged(changed)
            writingChangeReports += 1
            if bibliographyIndexUsed, changed.contains(where: {
                ["bib", "yml", "yaml"].contains($0.pathExtension.lowercased())
            }) {
                reloadBibliographyIndex()
            }
            recordOperation("writing.filesChanged", ["files": String(changed.count), "read": String(read)])
            guard read > 0, writingEngine?.renderer === renderer else {
                return
            }
            writingExternalRefreshes += 1
            editor?.writing.filesChangedOnDisk()
        }
    }
}
