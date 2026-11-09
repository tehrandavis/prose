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

    /// Code, or Writing behind the hidden default `WritingModeEnabled` until
    /// its acceptance tests pass (decision 11). Focus arrives in Phase 4.
    func setMode(_ mode: EditorMode) {
        guard mode.isAvailable else {
            showMessage(L10n.text("Writing and Focus modes arrive in a later version of Prose."))
            return
        }
        recordOperation("mode.changed", ["mode": mode.rawValue])
        guard mode != editorMode else {
            return
        }
        editorMode = mode
        updateWritingMode()
    }
}
