import AppKit
import ProseCore

/// Keyboard navigation in Writing mode (step F of the Phase 3 note).
///
/// - An empty selection lies in the active block, which lays out as source
///   (decision 5). TextKit's selection navigation steps through line
///   fragments, and a rendered block keeps its source line fragments, so
///   every key already lands where it lands in Code mode; the block it lands
///   in opens at once. Writing mode leaves those moves to TextKit.
/// - A selection the pointer made opens no block (step E). While the keyboard
///   extends it, Writing mode moves its moving end itself and the selection
///   still opens nothing: up and down step through the drawn lines of
///   rendered blocks (the glyph lines of `WritingGlyphMap`) at the nearest x,
///   line start and end use the drawn line, and paragraph start and end the
///   block. Other moves are TextKit's from the moving end.
/// - Page up and down move the caret about one viewport of drawn content
///   and scroll with it. With TextKit 2, NSTextView's own `pageDown:` and
///   `pageUp:` moved neither the caret nor the view in the test harness, in
///   Code mode too; Code mode keeps them.
///
/// The selection is always a plain source range.
struct WritingKeyboardMove {
    let direction: NSTextSelectionNavigation.Direction
    let destination: NSTextSelectionNavigation.Destination
    let confined: Bool

    var isVertical: Bool {
        destination == .character && (direction == .up || direction == .down)
    }

    /// Toward the end of the text, for left-to-right text.
    var forward: Bool {
        direction == .forward || direction == .right || direction == .down
    }
}

/// A block drawn rendered or as a pill, where its first paragraph's fragment
/// draws it.
struct WritingDrawnBlock {
    let frame: CGRect
    let block: NSRange
    /// Nil for a pill.
    let map: WritingGlyphMap?
    /// The pill, for a pill.
    var pill: WritingPill?

    var lines: [WritingGlyphMap.Line] {
        map?.sourceLines() ?? []
    }
}

extension WritingController {
    // MARK: - Extending a pointer selection

    /// The selection a keyboard move that extends the selection makes, when
    /// the selection is one the pointer made; nil leaves the move to TextKit.
    /// `native` is where TextKit moves a caret at a location.
    func keyboardDestination(
        _ move: WritingKeyboardMove,
        native: (NSTextLocation) -> NSTextLocation?,
    ) -> NSTextSelection? {
        guard isRunning, let editor, let manager = editor.textLayoutManager, !editor.hasMarkedText() else {
            return nil
        }
        let selection = editor.selectedRange()
        guard selection.length > 0, selection == pointerSelection else {
            return nil
        }
        let (fixed, moving) = ends(of: selection)
        let goal = verticalGoal.flatMap { $0.range == selection ? $0.x : nil }
        verticalGoal = nil
        var x: CGFloat?
        let end: Int? = if move.isVertical {
            verticalEnd(from: moving, down: move.direction == .down, fixed: fixed, goal: goal, x: &x) {
                nativeOffset(from: $0, native)
            }
        } else {
            drawnEnd(from: moving, move) ?? nativeOffset(from: moving, native)
        }
        guard let end else {
            return nil
        }
        let range = NSRange(location: min(fixed, end), length: abs(end - fixed))
        pointerExtension = (range, fixed)
        if let x {
            verticalGoal = (range, x)
        }
        guard range.length > 0 else {
            return TextKit2Geometry.location(end, in: manager).map { NSTextSelection($0, affinity: .downstream) }
        }
        return TextKit2Geometry.textRange(range, in: manager).map {
            NSTextSelection(range: $0, affinity: .downstream, granularity: .character)
        }
    }

    /// The fixed and the moving end of a non-empty selection, from the last
    /// fixed end known; a selection with none grows at its end.
    func ends(of selection: NSRange) -> (fixed: Int, moving: Int) {
        selectionAnchor == NSMaxRange(selection)
            ? (NSMaxRange(selection), selection.location)
            : (selection.location, NSMaxRange(selection))
    }

    private func nativeOffset(from offset: Int, _ native: (NSTextLocation) -> NSTextLocation?) -> Int? {
        guard let manager = editor?.textLayoutManager, let location = TextKit2Geometry.location(offset, in: manager),
              let moved = native(location)
        else {
            return nil
        }
        return TextKit2Geometry.offset(of: moved, in: manager)
    }

    /// Line start and end on a drawn line, and paragraph start and end at the
    /// block's ends, while the moving end lies in a rendered block.
    private func drawnEnd(from moving: Int, _ move: WritingKeyboardMove) -> Int? {
        guard let drawn = drawnBlock(holding: moving), drawn.map != nil else {
            return nil
        }
        switch move.destination {
        case .line:
            let lines = drawn.lines
            guard let caret = drawn.map?.caret(at: moving, in: lines) else {
                return nil
            }
            let line = lines[caret.line]
            return move.forward ? characterEnd(line.last) : line.first
        case .paragraph:
            if move.forward, moving < NSMaxRange(drawn.block) {
                return NSMaxRange(drawn.block)
            }
            if !move.forward, moving > drawn.block.location {
                return drawn.block.location
            }
            return nil
        default:
            return nil
        }
    }

    /// The moving end one drawn line up or down at the goal x: inside a
    /// rendered block, to its neighbour's nearest line from a block's first
    /// or last line or a pill, and into a block that TextKit's step from
    /// source reaches. `x` is the goal x used.
    private func verticalEnd(
        from moving: Int,
        down: Bool,
        fixed: Int,
        goal: CGFloat?,
        x: inout CGFloat?,
        native: (Int) -> Int?,
    ) -> Int? {
        guard let editor, let manager = editor.textLayoutManager else {
            return nil
        }
        let current = drawnBlock(holding: moving)
        let goalX = goal ?? drawnPoint(of: moving, in: current)?.x ?? 0
        x = goalX
        guard let current else {
            guard let next = native(moving) else {
                return nil
            }
            if let entered = drawnBlock(holding: next), !NSLocationInRange(moving, entered.block) {
                return entering(entered, down: down, x: goalX, fixed: fixed)
            }
            return next
        }
        if let map = current.map {
            let lines = current.lines
            if let caret = map.caret(at: moving, in: lines) {
                let target = caret.line + (down ? 1 : -1)
                if lines.indices.contains(target) {
                    return offset(on: lines[target], of: current, x: goalX)
                }
            }
        }
        // Past the block's first or last drawn line: the paragraph beside it.
        let text = editor.string as NSString
        let span = text.paragraphRange(for: current.block)
        if down {
            let after = NSMaxRange(span)
            guard after < text.length else {
                return text.length
            }
            if let next = drawnBlock(holding: after) {
                return entering(next, down: true, x: goalX, fixed: fixed)
            }
            return sourceOffset(inParagraphAt: after, firstLine: true, x: goalX, manager: manager)
        }
        guard span.location > 0 else {
            return 0
        }
        let before = text.paragraphRange(for: NSRange(location: span.location - 1, length: 0))
        if let previous = drawnBlock(holding: before.location) {
            return entering(previous, down: false, x: goalX, fixed: fixed)
        }
        return sourceOffset(inParagraphAt: before.location, firstLine: false, x: goalX, manager: manager)
    }

    /// Where the moving end lands entering `drawn`: on its first drawn line
    /// going down, its last going up, at `x`. A pill (or a block with no
    /// source glyph) is covered when the selection grows toward it.
    private func entering(_ drawn: WritingDrawnBlock, down: Bool, x: CGFloat, fixed: Int) -> Int {
        let lines = drawn.lines
        guard let line = down ? lines.first : lines.last else {
            return fixed <= drawn.block.location ? NSMaxRange(drawn.block) : drawn.block.location
        }
        return offset(on: line, of: drawn, x: x)
    }

    /// The insertion offset nearest container-x `x` on a drawn line.
    private func offset(on line: WritingGlyphMap.Line, of drawn: WritingDrawnBlock, x: CGFloat) -> Int {
        guard let map = drawn.map,
              case let .glyph(glyph, trailing) = map.position(on: line, nearest: x - drawn.frame.minX)
        else {
            return drawn.block.location
        }
        let offset = trailing ? characterEnd(glyph) : glyph
        return min(max(offset, drawn.block.location), NSMaxRange(drawn.block))
    }

    /// The source paragraph at `offset`: the insertion offset at `x` on its
    /// first or last line.
    private func sourceOffset(
        inParagraphAt offset: Int,
        firstLine: Bool,
        x: CGFloat,
        manager: NSTextLayoutManager,
    ) -> Int? {
        guard let location = TextKit2Geometry.location(offset, in: manager) else {
            return nil
        }
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location),
              let line = firstLine ? fragment.textLineFragments.first : fragment.textLineFragments.last
        else {
            return offset
        }
        let frame = fragment.layoutFragmentFrame
        let point = CGPoint(x: x, y: frame.minY + line.typographicBounds.midY)
        return TextKit2Geometry.viewportInsertionOffset(at: point, in: manager)
            ?? TextKit2Geometry.insertionOffset(at: point, in: manager)
    }

    /// The end of the character at `offset`.
    private func characterEnd(_ offset: Int) -> Int {
        let text = (editor?.string ?? "") as NSString
        guard offset < text.length else {
            return offset
        }
        return NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
    }

    // MARK: - Drawn geometry

    /// The rendered block or pill whose paragraphs hold `offset`, where it is
    /// drawn; nil while that paragraph draws source.
    func drawnBlock(holding offset: Int) -> WritingDrawnBlock? {
        guard isRunning, let model, let editor, let manager = editor.textLayoutManager else {
            return nil
        }
        let text = editor.string as NSString
        guard offset <= text.length else {
            return nil
        }
        var paragraph = text.paragraphRange(for: NSRange(location: offset, length: 0))
        if let fold = model.fold(holding: offset), !fold.isOpen {
            // A closed fold draws on its first paragraph, unless Focus hides it.
            guard !fold.isHidden else {
                return nil
            }
            paragraph = text.paragraphRange(for: NSRange(location: fold.span.location, length: 0))
        }
        var role = model.role(forParagraph: paragraph)
        var steps = 0
        while case .collapsed = role, paragraph.location > 0, steps <= WritingLayout.longBlockLines {
            paragraph = text.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            role = model.role(forParagraph: paragraph)
            steps += 1
        }
        guard let location = TextKit2Geometry.location(paragraph.location, in: manager) else {
            return nil
        }
        manager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = manager.textLayoutFragment(for: location) as? WritingFragment else {
            return nil
        }
        let frame = fragment.layoutFragmentFrame
        switch role {
        case .source, .collapsed:
            return nil
        case let .pill(pill):
            if pill.style != .plain, let fold = model.fold(holding: paragraph.location) {
                return WritingDrawnBlock(frame: frame, block: foldRange(fold), map: nil, pill: pill)
            }
            return model.blockRange(holding: paragraph.location).map {
                WritingDrawnBlock(frame: frame, block: $0, map: nil, pill: pill)
            }
        case let .rendered(rendering, block):
            return WritingDrawnBlock(frame: frame, block: block, map: fragment.glyphMap(rendering, block: block))
        }
    }

    /// Where the caret at `offset` is drawn, in container coordinates: on its
    /// glyph line in a rendered block, at a pill's middle, else TextKit's
    /// caret. `drawn` is the block that holds it, if already known.
    func drawnPoint(of offset: Int, in drawn: WritingDrawnBlock?) -> CGPoint? {
        if let drawn {
            let lines = drawn.lines
            guard let caret = drawn.map?.caret(at: offset, in: lines) else {
                // A setup row's or mark's caret (`foldCaretRect`), else a pill's middle.
                if drawn.pill.map({ $0.style != .plain }) == true,
                   let rect = foldCaretRect(at: drawn.block.location, width: 0)
                {
                    return CGPoint(x: rect.minX, y: rect.midY)
                }
                return CGPoint(x: drawn.frame.minX, y: drawn.frame.midY)
            }
            return CGPoint(x: drawn.frame.minX + caret.x, y: drawn.frame.minY + lines[caret.line].midY)
        }
        guard let manager = editor?.textLayoutManager, let rect = TextKit2Geometry.caretRect(at: offset, in: manager)
        else {
            return nil
        }
        return CGPoint(x: rect.minX, y: rect.midY)
    }

    /// The source position drawn at `point` (container coordinates): through
    /// the glyph boxes in rendered fragments and pills, through TextKit in
    /// source.
    func offset(atDrawn point: CGPoint, anchor: Int?) -> Int? {
        if let hit = pointerHit(at: point, anchor: anchor) {
            return hit.offset
        }
        guard let manager = editor?.textLayoutManager else {
            return nil
        }
        return TextKit2Geometry.viewportInsertionOffset(at: point, in: manager)
            ?? TextKit2Geometry.insertionOffset(at: point, in: manager)
    }

    // MARK: - Page up and down

    /// Moves the caret, or the selection's moving end, about one viewport of
    /// drawn content up or down, and scrolls the view by the same distance.
    /// A move past the text's start or end goes to it. Returns false while
    /// Writing mode is off.
    func page(down: Bool, extending: Bool) -> Bool {
        guard isRunning, let editor, let manager = editor.textLayoutManager, !editor.hasMarkedText() else {
            return false
        }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        let pointer = extending && selection.length > 0 && selection == pointerSelection
        let (fixed, moving) = if extending, selection.length > 0 {
            ends(of: selection)
        } else if extending {
            (selection.location, selection.location)
        } else {
            (selection.location, down ? NSMaxRange(selection) : selection.location)
        }
        let visible = editor.containerVisibleRect()
        let distance = max(visible.height - (editor.enclosingScrollView?.verticalPageScroll ?? 0), 1)
        let step = down ? distance : -distance
        let start = drawnPoint(of: moving, in: drawnBlock(holding: moving))
            ?? CGPoint(x: 0, y: down ? visible.minY : visible.maxY)
        // A caret out of view pages from the edge of the view.
        let target = CGPoint(x: start.x, y: min(max(start.y, visible.minY), visible.maxY) + step)
        editor.scrollContainer(to: visible.minY + step)
        manager.textViewportLayoutController.layoutViewport()
        let usage = manager.usageBoundsForTextContainer
        let end = if target.y < usage.minY {
            0
        } else if target.y >= usage.maxY {
            text.length
        } else {
            offset(atDrawn: target, anchor: extending ? fixed : nil) ?? (down ? text.length : 0)
        }
        verticalGoal = nil
        if extending {
            let range = NSRange(location: min(fixed, end), length: abs(end - fixed))
            if pointer {
                pointerExtension = (range, fixed)
            }
            selectionAnchor = fixed
            editor.setSelectedRange(range)
        } else {
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
        // The moving end in view once its block has opened.
        editor.reveal(NSRange(location: end, length: 0))
        if down, end == text.length, !focused {
            // The text's end: its last page in view, after the swaps the move
            // caused have changed the text's height. (Focus puts the caret's
            // line on the typewriter line instead.)
            manager.textViewportLayoutController.layoutViewport()
            editor.scrollContainer(to: manager.usageBoundsForTextContainer.maxY)
            manager.textViewportLayoutController.layoutViewport()
        }
        return true
    }
}
