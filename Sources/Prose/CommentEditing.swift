import AppKit
import ProseCore

/// The writer's edits near a comment's markers (Phase 8 decision 4), in
/// the editor's gate for text changes, and the edit path of comment
/// actions. Nothing here writes an attribute into the storage.
extension ManuscriptTextView {
    /// Runs the rules of `CommentEditRules` for an edit the gate is asked
    /// about. Returns nil when the edit stands as it is; otherwise the edit
    /// was made another way here (or refused), and the gate refuses the
    /// original: a rewrite of the edit, in one undo group with its record
    /// removals.
    func commentRuleOutcome(_ range: NSRange, _ replacement: String?) -> Bool? {
        guard commentRulesApply, let replacement, comments.mayTouchMarker(range) else {
            return nil
        }
        let text = string as NSString
        guard let index = comments.index(of: text),
              let plan = CommentEditRules.plan(
                  replacing: range,
                  with: replacement,
                  selection: selectedRange(),
                  index: index,
                  source: text,
              )
        else {
            return nil
        }
        applyCommentRule(plan)
        return false
    }

    /// Whether the rules run for an edit now: not while text is marked,
    /// during undo or redo, while text is loaded, for a comment action's
    /// edits or for the edits a rule makes.
    private var commentRulesApply: Bool {
        !hasMarkedText() && !composing && !loading && commentEditDepth == 0 &&
            undoManager?.isUndoing != true && undoManager?.isRedoing != true
    }

    /// Makes `plan`'s replacements through the native edit path, last first,
    /// in one undo group, and puts the selection where the plan says.
    private func applyCommentRule(_ plan: CommentEditRules.Plan) {
        guard !plan.replacements.isEmpty else {
            return
        }
        makeCommentEdits(plan.replacements, actionName: nil) { _ in plan.selection }
    }

    /// Makes a comment action's replacements (`CommentEdits`: sorted, never
    /// overlapping) through the native edit path, last first, as one undo
    /// step named `actionName`. The rules of decision 4 do not run for them,
    /// and they open no closed fold, so a record written into the store
    /// leaves it closed (decision 6). The selection keeps its place in the
    /// text. Returns false when the editor cannot edit.
    @discardableResult
    func applyCommentEdits(_ replacements: [TextReplacement], actionName: String) -> Bool {
        let length = (string as NSString).length
        guard workspace?.canEditSource != false, !hasMarkedText(), !replacements.isEmpty,
              replacements.allSatisfy({ $0.range.location >= 0 && NSMaxRange($0.range) <= length })
        else {
            return false
        }
        makeCommentEdits(replacements, actionName: actionName) { $0 }
        return true
    }

    /// Makes `replacements` (sorted, never overlapping), last first, as one
    /// undo step, with the rules off and no fold opened. While they are
    /// made the selection that each one leaves is not shown to Writing
    /// mode, so it never sees the caret inside the store. Then the
    /// selection is `selection` of the old selection moved through the
    /// edits.
    private func makeCommentEdits(
        _ replacements: [TextReplacement],
        actionName: String?,
        selection: (NSRange) -> NSRange,
    ) {
        let before = selectedRange()
        var kept = before
        // A comment action changes the store at the end of the file and two
        // short markers. The writer is looking at a card, so the view must
        // stay where it is: the native edit path scrolls to each edit, and
        // then to the selection, which is at the start of the document when
        // the writer has only clicked cards.
        // The writer's own edits that a rule rewrote (no action name) scroll
        // as typing does.
        let clip = actionName == nil ? nil : enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        commentEditDepth += 1
        let model = writing.model
        let opened = model?.editsOpenFolds ?? true
        model?.editsOpenFolds = false
        observeUndoManagerForComments()
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        let restores = actionName != nil
        if restores {
            registerSelectionOnUndo(before)
        }
        for replacement in replacements.reversed() {
            insertText(replacement.text, replacementRange: replacement.range)
            kept = SourceStyling.rebase(
                kept,
                editing: replacement.range,
                delta: (replacement.text as NSString).length - replacement.range.length,
            )
        }
        let after = selection(kept)
        if restores {
            registerSelectionOnRedo(after)
        }
        undoManager?.endUndoGrouping()
        if let actionName {
            undoManager?.setActionName(actionName)
        }
        breakUndoCoalescing()
        model?.editsOpenFolds = opened
        commentEditDepth -= 1
        keepsActiveComment = true
        setSelectedRange(after)
        selectionChanged()
        keepsActiveComment = false
        if let clip, let origin {
            let restore = { [weak self] in
                guard clip.bounds.origin != origin else {
                    return
                }
                clip.scroll(to: origin)
                self?.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            restore()
            // Writing mode lays out its swaps at the end of this turn of the
            // run loop, and that can scroll once more.
            DispatchQueue.main.async(execute: restore)
        }
    }

    /// Registered first in a comment action's undo group, so an undo runs it
    /// last: the selection goes back to `range`, where it was before the
    /// action, and not into the store where the last undone edit left it.
    /// It registers itself again through the redo, so the next undo of the
    /// same action does the same.
    private func registerSelectionOnUndo(_ range: NSRange) {
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.restoreCommentSelection(range)
            editor.undoManager?.registerUndo(withTarget: editor) { again in
                again.registerSelectionOnUndo(range)
            }
        }
    }

    /// Registered last, so an undo runs it first and a redo runs what it
    /// registers last: after a redo the selection is `range`, where the
    /// action left it.
    private func registerSelectionOnRedo(_ range: NSRange) {
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.undoManager?.registerUndo(withTarget: editor) { again in
                again.restoreCommentSelection(range)
                again.registerSelectionOnRedo(range)
            }
        }
    }

    private func restoreCommentSelection(_ range: NSRange) {
        let length = (string as NSString).length
        let location = min(max(0, range.location), length)
        setSelectedRange(NSRange(location: location, length: min(range.length, length - location)))
    }
}
