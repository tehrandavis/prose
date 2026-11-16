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
        var kept = selectedRange()
        commentEditDepth += 1
        let model = writing.model
        let opened = model?.editsOpenFolds ?? true
        model?.editsOpenFolds = false
        observeUndoManagerForComments()
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        for replacement in replacements.reversed() {
            insertText(replacement.text, replacementRange: replacement.range)
            kept = SourceStyling.rebase(
                kept,
                editing: replacement.range,
                delta: (replacement.text as NSString).length - replacement.range.length,
            )
        }
        undoManager?.endUndoGrouping()
        if let actionName {
            undoManager?.setActionName(actionName)
        }
        breakUndoCoalescing()
        model?.editsOpenFolds = opened
        commentEditDepth -= 1
        setSelectedRange(selection(kept))
        selectionChanged()
    }
}
