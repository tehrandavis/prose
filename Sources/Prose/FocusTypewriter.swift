import AppKit
import ProseCore

/// How a caret change in Focus mode scrolls: at once for keys, typing and
/// commands, over 0.2 s for a click (decision 5 of the Phase 4 note).
enum TypewriterScroll {
    case immediate
    case animated
}

/// Focus mode's dimming and typewriter scrolling (decisions 4 and 5 of the
/// Phase 4 note), on Writing mode's mechanisms: the fragment draws a paragraph
/// outside the focus blocks at 45 percent opacity, a change of the focus
/// blocks lays out the paragraphs whose contrast changed with
/// `invalidateLayout(for:)` in `flush()`, and the same `flush()` keeps the
/// caret's line in place across swaps and moves it to the typewriter line
/// after a caret change. Nothing here touches the storage, its attributes,
/// the selection or the undo stack.
extension WritingController {
    /// The typewriter line, as a fraction of the visible height from its top.
    static let typewriterFraction: CGFloat = 0.4
    /// How long a click's typewriter scroll takes.
    static let typewriterAnimationDuration: TimeInterval = 0.2

    // MARK: - Dimming

    /// Whether the paragraph that starts at `offset` draws dimmed: in Focus
    /// mode, outside the focus blocks.
    func dims(paragraphAt offset: Int) -> Bool {
        guard let focusSpans else {
            return false
        }
        return !WritingFocus.contains(focusSpans, offset)
    }

    /// The focus blocks now: every block a selection made with the pointer
    /// touches; else the active block (the paragraph of the caret when it
    /// lies in no block), and every block another non-empty selection
    /// touches, so selected text is never dimmed. Nil outside Focus mode.
    private func currentFocusSpans() -> [NSRange]? {
        guard focused, let model, model.isRunning, let editor else {
            return nil
        }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        guard NSMaxRange(selection) <= text.length else {
            return focusSpans
        }
        var spans: [NSRange] = []
        if selection.length > 0 {
            spans = model.spans(intersecting: selection) + [text.paragraphRange(for: selection)]
        }
        if selection.length == 0 || selection != pointerSelection {
            if let index = model.activeBlock {
                spans.append(model.span(ofBlockAt: index))
            } else {
                let moving = min(caret ?? selection.location, text.length)
                spans.append(text.paragraphRange(for: NSRange(location: moving, length: 0)))
            }
        }
        return WritingFocus.merged(spans)
    }

    /// Takes the new focus blocks for drawing and returns the paragraphs whose
    /// contrast changed: those whose first character moved in or out of the
    /// focus blocks, or every paragraph in view when Focus began or ended.
    /// Nothing changes while text is marked (Phase 3: no swap then).
    func refocus() -> [NSRange] {
        guard let editor, !editor.hasMarkedText() else {
            return []
        }
        let new = currentFocusSpans()
        let old = focusSpans
        guard new != old else {
            return []
        }
        focusSpans = new
        let text = editor.string as NSString
        guard let new, let old else {
            guard let visible = visibleRange else {
                return []
            }
            let start = min(visible.location, text.length)
            let end = min(NSMaxRange(visible), text.length)
            refocused = [text.paragraphRange(for: NSRange(location: start, length: end - start))]
            return refocused
        }
        refocused = WritingFocus.paragraphs(startingIn: WritingFocus.symmetricDifference(old, new), of: text)
        return refocused
    }

    // MARK: - Typewriter scrolling

    /// The typewriter scroll asked for, with the caret it is for, while Focus
    /// mode has an empty selection; it is then no longer asked for.
    func takeTypewriter() -> (offset: Int, scroll: TypewriterScroll)? {
        defer { typewriter = nil }
        guard focused, let scroll = typewriter, let editor, editor.selectedRange().length == 0 else {
            return nil
        }
        return (editor.selectedRange().location, scroll)
    }

    /// In Focus mode with an empty selection, the caret's line middle in the
    /// viewport that a swap keeps in place: where it was before the model
    /// changed roles, or where it is now when the swap leaves its paragraph
    /// alone. Nil when the caret is out of view.
    func focusLine(changing ranges: [NSRange]) -> (offset: Int, y: CGFloat)? {
        guard focused, let editor, editor.selectedRange().length == 0 else {
            return nil
        }
        let caret = editor.selectedRange().location
        if let focusCaretLine, focusCaretLine.offset == caret {
            return focusCaretLine
        }
        let text = editor.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: min(caret, text.length), length: 0))
        guard !ranges.contains(where: { NSIntersectionRange($0, paragraph).length > 0 || $0.location == caret })
        else {
            return nil
        }
        return caretMiddleInView(caret).map { (caret, $0) }
    }

    /// Where the middle of the caret's line is drawn, in container
    /// coordinates: on its glyph line inside a rendered block (never
    /// TextKit's hidden lines there), at a pill's middle, else TextKit's.
    func caretMiddle(_ offset: Int) -> CGFloat? {
        drawnPoint(of: offset, in: drawnBlock(holding: offset))?.y
    }

    /// The caret line's middle from the top of the visible area, while it is
    /// in view.
    func caretMiddleInView(_ offset: Int) -> CGFloat? {
        guard let editor, let middle = caretMiddle(offset) else {
            return nil
        }
        let visible = editor.containerVisibleRect()
        guard middle >= visible.minY, middle <= visible.maxY else {
            return nil
        }
        return middle - visible.minY
    }

    /// After a swap's layout: keeps the caret line at `kept` (from the top of
    /// the visible area), then makes the typewriter scroll, if one is due:
    /// at once, or animated from where the line was kept.
    func placeFocusLine(_ caret: Int, keeping kept: CGFloat?, scroll: TypewriterScroll?) {
        guard let editor else {
            return
        }
        let line = Self.typewriterFraction * editor.containerVisibleRect().height
        switch scroll {
        case .immediate?:
            stopTypewriterAnimation()
            placeCaretLine(caret, at: line)
        case .animated?:
            stopTypewriterAnimation()
            if let kept {
                placeCaretLine(caret, at: kept)
                animateCaretLine(caret, to: line)
            } else {
                placeCaretLine(caret, at: line)
            }
        case nil:
            if let kept, typewriterAnimation == nil {
                placeCaretLine(caret, at: kept)
            } else {
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
                editor.needsDisplay = true
            }
        }
    }

    /// Scrolls so that the middle of the caret's line lies `y` below the top
    /// of the visible area, or as near as the text and its insets allow. A
    /// caret out of view first lays out the text around it, as a jump does.
    func placeCaretLine(_ caret: Int, at y: CGFloat) {
        guard let editor, let manager = editor.textLayoutManager else {
            return
        }
        defer {
            manager.textViewportLayoutController.layoutViewport()
            editor.needsDisplay = true
        }
        var laidOut = false
        for _ in 0 ..< 4 {
            guard let middle = caretMiddle(caret) else {
                return
            }
            let visible = editor.containerVisibleRect()
            if !laidOut, middle < visible.minY || middle > visible.maxY {
                laidOut = true
                TextKit2Geometry.layOutContext(around: caret, in: manager)
                guard let laid = caretMiddle(caret) else {
                    return
                }
                editor.scrollContainer(to: laid - y)
                manager.textViewportLayoutController.layoutViewport()
                continue
            }
            guard abs(middle - visible.minY - y) >= 0.25 else {
                return
            }
            editor.scrollContainer(to: middle - y)
            manager.textViewportLayoutController.layoutViewport()
        }
    }

    /// Scrolls the caret's line to `y` over `typewriterAnimationDuration`,
    /// easing out, and corrects for layout that changed on the way. Reduced
    /// motion scrolls at once.
    private func animateCaretLine(_ caret: Int, to y: CGFloat) {
        guard let editor, let middle = caretMiddle(caret) else {
            return
        }
        let from = editor.containerVisibleRect().minY
        let target = middle - y
        guard abs(target - from) >= 0.25, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            placeCaretLine(caret, at: y)
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let duration = Self.typewriterAnimationDuration
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let editor = self.editor else {
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                let eased = 1 - pow(1 - progress, 3)
                editor.scrollContainer(to: from + (target - from) * eased)
                guard progress >= 1 else {
                    return
                }
                self.stopTypewriterAnimation()
                if self.focused, editor.selectedRange() == NSRange(location: caret, length: 0) {
                    self.placeCaretLine(caret, at: y)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        typewriterAnimation = timer
    }

    /// The caret whose line Focus mode keeps on the typewriter line while the
    /// visible height changes: an empty selection, no marked text, its line
    /// in view. Nil otherwise, and the top line stays in place instead.
    func typewriterCaretInView() -> Int? {
        guard focused, let editor, !editor.hasMarkedText(), editor.selectedRange().length == 0 else {
            return nil
        }
        let caret = editor.selectedRange().location
        return caretMiddleInView(caret) == nil ? nil : caret
    }

    /// The visible height changed (a window resize, the command panel or the
    /// message bar opening or closing): the caret line goes back to the
    /// typewriter line, as after a caret change.
    func visibleHeightChanged(caret: Int) {
        guard focused, let editor, editor.selectedRange() == NSRange(location: caret, length: 0) else {
            return
        }
        stopTypewriterAnimation()
        placeCaretLine(caret, at: Self.typewriterFraction * editor.containerVisibleRect().height)
    }

    func stopTypewriterAnimation() {
        typewriterAnimation?.invalidate()
        typewriterAnimation = nil
    }
}
