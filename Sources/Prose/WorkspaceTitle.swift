import ProseCore

extension Workspace {
    /// The compile state behind the title row's status dot.
    var compileStatus: CompileStatus {
        CompileStatus.resolve(
            serviceReady: serviceReady,
            serviceStatus: serviceStatus,
            errors: checkErrors,
            previewStale: previewStale,
            hasSuccessfulPreview: hasSuccessfulPreview,
        )
    }

    /// Headings that enclose the caret, outermost first.
    var breadcrumb: [OutlineItem] {
        guard let index = activeOutlineIndex else {
            return []
        }
        return outlineNavigation.ancestry(of: index).map { outlineNavigation.items[$0] }
    }

    var previewShown: Bool {
        layout != .writing
    }

    /// Shows the preview beside the text, or hides it.
    func togglePreview() {
        layout = layout == .writing ? .split : .writing
    }

    /// Code, Writing or Focus. Focus is Writing mode plus view state: entering
    /// it from Code enters Writing mode with the same model, engine and
    /// fragments (decision 2 of the Phase 4 note).
    func setMode(_ mode: EditorMode) {
        recordOperation("mode.changed", ["mode": mode.rawValue])
        guard mode != editorMode else {
            return
        }
        editorMode = mode
        updateWritingMode()
    }
}
