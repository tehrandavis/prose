import AppKit
import ProseCore

/// Folds in Writing and Focus mode (Phase 6 decisions 2 to 4): what the
/// fragments draw for them, the pointer on their rows and margin icons, the
/// caret at a resting position, and the arrow keys' step over a closed fold.
/// The model (`WritingLayout`) decides what folds and whether each is open;
/// nothing here touches the storage, its attributes or the undo stack.
extension WritingController {
    // MARK: - Drawing

    /// The muted text colour that rows and margin icons draw in.
    func foldColor() -> CGColor {
        resolved(Theme.nativeMuted)
    }

    /// What the paragraph that starts at `offset`, with role `role`, draws in
    /// the margin: a closed mark, or `caret-down` on an open fold's first
    /// paragraph.
    func marginIcon(ofParagraphAt offset: Int, role: WritingRole) -> WritingMarginIcon? {
        guard let model, model.isRunning else {
            return nil
        }
        switch role {
        case let .pill(pill):
            if case let .mark(mark) = pill.style {
                return .mark(mark)
            }
            return nil
        case .source:
            guard let fold = model.fold(holding: offset), fold.isOpen, fold.span.location == offset else {
                return nil
            }
            return .close
        case .rendered, .collapsed:
            return nil
        }
    }

    /// The fold's source: from its first character to the end of its last
    /// line's content (a mark's trailing blank lines are not part of it).
    func foldRange(_ fold: WritingFold) -> NSRange {
        let text = (editor?.string ?? "") as NSString
        let span = NSIntersectionRange(fold.span, NSRange(location: 0, length: text.length))
        var end = NSMaxRange(span)
        if end > span.location {
            let last = text.character(at: end - 1)
            if last == 0x0A {
                end -= end - 1 > span.location && text.character(at: end - 2) == 0x0D ? 2 : 1
            } else if last == 0x0D || last == 0x2029 || last == 0x2028 {
                end -= 1
            }
        }
        return NSRange(location: span.location, length: end - span.location)
    }

    /// The closed fold that holds `offset` and draws (not hidden by Focus).
    func closedFold(holding offset: Int) -> WritingFold? {
        guard isRunning, let model, let fold = model.fold(holding: offset), !fold.isOpen, !fold.isHidden else {
            return nil
        }
        return fold
    }

    /// The laid-out fragment of the paragraph that starts at `offset`.
    func fragment(at offset: Int) -> WritingFragment? {
        guard let manager = editor?.textLayoutManager, let location = TextKit2Geometry.location(offset, in: manager)
        else {
            return nil
        }
        return manager.textLayoutFragment(for: location) as? WritingFragment
    }

    // MARK: - The caret at a resting position

    /// Where TextKit's caret for `offset` goes when a closed fold that draws
    /// holds it, in container coordinates: on a setup row at its left edge,
    /// as tall as its label's line; on a mark at the column's left edge,
    /// level with the mark, as tall as one source line's text. Nil elsewhere, and for a
    /// fold whose row is hidden. `width` is TextKit's caret width.
    func foldCaretRect(at offset: Int, width: CGFloat) -> CGRect? {
        guard let fold = closedFold(holding: offset), let fragment = fragment(at: fold.span.location) else {
            return nil
        }
        let frame = fragment.layoutFragmentFrame
        if fold.pill.isMark {
            let line = fragment.textLineFragments.first?.typographicBounds.height ?? 0
            let middle = frame.minY - fragment.sourceLineHeight / 2
            return CGRect(x: frame.minX, y: middle - line / 2, width: width, height: line)
        }
        var rect = WritingMetrics.setupCaretRect.offsetBy(dx: frame.minX, dy: frame.minY)
        rect.size.width = width
        return rect
    }

    // MARK: - Pointer

    /// What a click at `point` (container coordinates) on a fold's control
    /// does: the fold, and whether the control is a closed row's or mark's
    /// (`opens`) or an open fold's `caret-down`. `margin` is true for the
    /// icons in the margin.
    func foldControl(at point: CGPoint) -> (fold: WritingFold, opens: Bool, margin: Bool)? {
        guard isRunning, let model, let editor, let manager = editor.textLayoutManager else {
            return nil
        }
        // A closed setup row: its icon and label.
        if let fragment = manager.textLayoutFragment(for: point) as? WritingFragment,
           case let .pill(pill) = fragment.role, pill.isSetup, let start = fragment.offset
        {
            let frame = fragment.layoutFragmentFrame
            let row = WritingMetrics.setupRowRect(label: pill.text, column: fragment.columnWidth)
                .offsetBy(dx: frame.minX, dy: frame.minY)
            if row.contains(point), let fold = closedFold(holding: start) {
                return (fold, true, false)
            }
        }
        // Icons in the margin, of the folds in the viewport.
        guard point.x < 0, let viewport = manager.textViewportLayoutController.viewportRange else {
            return nil
        }
        let start = TextKit2Geometry.offset(of: viewport.location, in: manager)
        let range = NSRange(
            location: start,
            length: TextKit2Geometry.offset(of: viewport.endLocation, in: manager) - start,
        )
        let slop = WritingMetrics.marginHitSlop
        for fold in model.folds(intersecting: range) where !fold.isHidden {
            guard let fragment = fragment(at: fold.span.location), let icon = fragment.marginIconRect else {
                continue
            }
            let frame = fragment.layoutFragmentFrame
            if icon.offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -slop, dy: -slop).contains(point) {
                return (fold, !fold.isOpen, true)
            }
        }
        return nil
    }

    /// A press on a fold's control: a single click on a closed row or mark
    /// opens the fold, and on an open fold's `caret-down` closes it, with the
    /// caret and the selection left where they are. The second and third
    /// press of a multi-click that opened a fold map to it as for a pill (the
    /// word at its first character, then its source). While text is marked a
    /// press on a control does nothing. Returns false for a press that is not
    /// on a control, or that the pill path handles (shift, a multi-click on a
    /// row).
    func handleFoldPress(_ down: NSEvent, at point: CGPoint) -> Bool {
        guard let editor, let control = foldControl(at: point) else {
            return false
        }
        let modifiers = down.modifierFlags.intersection([.command, .control, .option, .shift])
        if !control.margin, down.clickCount > 1 || !modifiers.isEmpty {
            return false
        }
        if editor.hasMarkedText() || !modifiers.isEmpty {
            return true
        }
        if down.clickCount > 1 {
            // A multi-click that began by opening this fold goes on as for a
            // pill; any other is not for the icon.
            return editor.lastWritingClick == nil
        }
        guard model?.setFold(open: control.opens, at: control.fold.restingPosition) == true else {
            return true
        }
        editor.window?.makeFirstResponder(editor)
        editor.lastWritingClick = control.opens ? WritingClick(
            location: down.locationInWindow,
            time: down.timestamp,
            hit: WritingPointerHit(offset: control.fold.restingPosition, block: foldRange(control.fold)),
        ) : nil
        return true
    }

    // MARK: - Arrow keys

    /// Up and down from an empty selection over a closed fold (decisions 3
    /// and 4): coming toward a setup row, the caret stops at its resting
    /// position; from there, down goes to the first position after the fold
    /// (line start) and up is TextKit's own. A mark, and in Focus a hidden
    /// setup row, are passed in one step: down to the first position after
    /// the fold, up to the end of the line before it. Returns false, moving
    /// nothing, when TextKit's own step stands.
    func stepOverFold(down: Bool) -> Bool {
        guard isRunning, let model, let editor, let manager = editor.textLayoutManager, !editor.hasMarkedText()
        else {
            return false
        }
        let selection = editor.selectedRange()
        guard selection.length == 0 else {
            return false
        }
        let caret = selection.location
        let length = (editor.string as NSString).length
        var target: Int?
        if let fold = model.fold(holding: caret), !fold.isOpen, caret == fold.restingPosition {
            if down {
                target = min(fold.end, length)
            }
        } else if let native = nativeVerticalStep(down: down, manager: manager),
                  let fold = model.fold(holding: native), !fold.isOpen,
                  fold.restingPosition != caret
        {
            if fold.pill.isMark || fold.isHidden {
                target = down ? min(fold.end, length) : max(fold.restingPosition - 1, 0)
                if !down, fold.restingPosition == 0 {
                    target = 0
                }
            } else if native != fold.restingPosition {
                target = fold.restingPosition
            }
        }
        guard let target, target != caret else {
            return false
        }
        editor.setSelectedRange(NSRange(location: target, length: 0))
        if !focused {
            editor.reveal(NSRange(location: target, length: 0))
        }
        return true
    }

    /// Where TextKit's own vertical step from the selection lands.
    private func nativeVerticalStep(down: Bool, manager: NSTextLayoutManager) -> Int? {
        guard let selection = manager.textSelections.first,
              let moved = manager.textSelectionNavigation.destinationSelection(
                  for: selection,
                  direction: down ? .down : .up,
                  destination: .character,
                  extending: false,
                  confined: false,
              ),
              let location = moved.textRanges.first?.location
        else {
            return nil
        }
        return TextKit2Geometry.offset(of: location, in: manager)
    }
}
