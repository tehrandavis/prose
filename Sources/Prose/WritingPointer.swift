import AppKit
import ProseCore

/// Pointer and selection in Writing mode (step E of the Phase 3 note,
/// decisions 6 and 7). Inside a rendered block TextKit still lays out the
/// source lines, so every position there comes from the engine's glyph boxes:
///
/// - A press in a rendered block or a pill runs Prose's tracking loop
///   (`trackWritingPointer`), which maps each point through the glyph boxes in
///   rendered fragments and through TextKit in source fragments.
/// - A drag that starts in source stays with AppKit. Its tracking asks the
///   layout manager's `textSelectionNavigation` for
///   `textSelections(interactingAt:…)` at every point; `WritingSelectionNavigation`
///   replaces the answer inside a rendered block or a pill.
/// - NSTextView draws no selection inside rendered blocks and pills
///   (`ManuscriptLayoutManager`); the editor draws it there from the glyph
///   boxes, under the transparent images, in `drawBackground(in:)`.
///
/// The selection is always a plain source range.
struct WritingPointerHit: Equatable {
    let offset: Int
    /// The block under the point.
    let block: NSRange
}

/// A click that Prose mapped through a rendered block.
struct WritingClick {
    /// In the window.
    let location: NSPoint
    let time: TimeInterval
    let hit: WritingPointerHit
}

/// The selection navigation of the editor's layout manager once Writing mode
/// has been used. NSTextView's mouse tracking, and `TextKit2Geometry`'s hit
/// tests, ask it for the selection at a point; in a rendered fragment or a
/// pill it answers from the glyph boxes, and elsewhere, or while Writing mode
/// is off, it answers as TextKit does.
final class WritingSelectionNavigation: NSTextSelectionNavigation {
    private weak var controller: WritingController?

    init(dataSource: any NSTextSelectionDataSource, controller: WritingController) {
        self.controller = controller
        super.init(dataSource: dataSource)
    }

    override func textSelections(
        interactingAt point: CGPoint,
        inContainerAt containerLocation: NSTextLocation,
        anchors: [NSTextSelection],
        modifiers: NSTextSelectionNavigation.Modifier,
        selecting: Bool,
        bounds: CGRect,
    ) -> [NSTextSelection] {
        let native = super.textSelections(
            interactingAt: point,
            inContainerAt: containerLocation,
            anchors: anchors,
            modifiers: modifiers,
            selecting: selecting,
            bounds: bounds,
        )
        guard let controller, Thread.isMainThread else {
            return native
        }
        let extending = modifiers.contains(.extend)
        let anchor = extending ? anchors.first?.textRanges.first : nil
        let granularity = native.first?.granularity ?? .character
        // NSTextSelection is not Sendable; this runs on the main thread.
        nonisolated(unsafe) var mapped: [NSTextSelection]?
        nonisolated(unsafe) let fixed = anchor
        MainActor.assumeIsolated {
            mapped = controller.selections(at: point, extending: fixed, granularity: granularity)
        }
        return mapped ?? native
    }
}

extension WritingController {
    /// The source position under `point` (container coordinates) when it lies
    /// in a rendered fragment or a pill; nil over source. In a rendered block it
    /// is the nearest glyph box's offset, after the character when the point is
    /// right of the box's middle. A generated glyph gives the block's start. A
    /// point near no box, and a pill, give the block's start, or its end while
    /// a selection whose fixed end `anchor` lies before the block is extended.
    func pointerHit(at point: CGPoint, anchor: Int? = nil) -> WritingPointerHit? {
        guard isRunning, let model, let editor, let fragment = writingFragment(at: point),
              let start = fragment.offset
        else {
            return nil
        }
        let frame = fragment.layoutFragmentFrame
        let block: NSRange
        let hit: WritingGlyphMap.Hit
        switch fragment.role {
        case .source, .collapsed:
            return nil
        case .pill:
            guard let range = model.blockRange(holding: start) else {
                return nil
            }
            block = range
            hit = .missed
        case let .rendered(rendering, range):
            block = range
            hit = fragment.glyphMap(rendering, block: range)
                .hit(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
        }
        let text = editor.string as NSString
        let offset = switch hit {
        case let .glyph(glyph, trailing):
            trailing && glyph < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: glyph)) : glyph
        case .generated:
            block.location
        case .missed:
            anchor.map { $0 <= block.location } == true ? NSMaxRange(block) : block.location
        }
        return WritingPointerHit(offset: min(max(offset, block.location), NSMaxRange(block)), block: block)
    }

    /// The selection for a press at `point`, or for extending `anchor` to it,
    /// when the point lies in a rendered fragment or a pill.
    func selections(
        at point: CGPoint,
        extending anchor: NSTextRange?,
        granularity: NSTextSelection.Granularity,
    ) -> [NSTextSelection]? {
        guard let manager = editor?.textLayoutManager else {
            return nil
        }
        let fixed = anchor.map {
            let start = TextKit2Geometry.offset(of: $0.location, in: manager)
            return NSRange(location: start, length: TextKit2Geometry.offset(of: $0.endLocation, in: manager) - start)
        }
        guard let hit = pointerHit(at: point, anchor: fixed?.location) else {
            return nil
        }
        guard let fixed else {
            return TextKit2Geometry.location(hit.offset, in: manager).map {
                [NSTextSelection($0, affinity: .downstream)]
            }
        }
        let range = hit.offset < fixed.location
            ? NSRange(location: hit.offset, length: NSMaxRange(fixed) - hit.offset)
            : NSRange(location: fixed.location, length: hit.offset - fixed.location)
        return TextKit2Geometry.textRange(range, in: manager).map {
            [NSTextSelection(range: $0, affinity: .downstream, granularity: granularity)]
        }
    }

    /// The laid-out fragment whose frame holds `point`, if it is ours.
    private func writingFragment(at point: CGPoint) -> WritingFragment? {
        guard let manager = editor?.textLayoutManager else {
            return nil
        }
        func holds(_ fragment: NSTextLayoutFragment) -> Bool {
            let frame = fragment.layoutFragmentFrame
            return frame.height > 0 && point.y >= frame.minY && point.y < frame.maxY
        }
        if let fragment = manager.textLayoutFragment(for: point), holds(fragment) {
            return fragment as? WritingFragment
        }
        // TextKit can answer with a zero-height fragment at a block's bottom.
        guard let viewport = manager.textViewportLayoutController.viewportRange else {
            return nil
        }
        var found: NSTextLayoutFragment?
        manager.enumerateTextLayoutFragments(from: viewport.location) { fragment in
            if holds(fragment) {
                found = fragment
                return false
            }
            return fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending
        }
        return found as? WritingFragment
    }

    // MARK: - Selection drawing

    /// The parts of `range` that NSTextView may draw its selection over: all
    /// of it except the paragraphs of rendered blocks and pills.
    func nativeSelectionPieces(of range: NSRange) -> [NSRange] {
        guard isRunning, let model else {
            return [range]
        }
        var pieces: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        for span in model.drawnSpans(intersecting: range) {
            if span.location > cursor {
                pieces.append(NSRange(location: cursor, length: span.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(span))
        }
        if cursor < end {
            pieces.append(NSRange(location: cursor, length: end - cursor))
        }
        return pieces
    }

    /// The selection changed: the editor redraws its highlight when the old
    /// or the new selection touches a rendered block or a pill in view.
    func selectionWillDraw(from old: [NSValue], to new: [NSValue]) {
        guard isRunning, let editor, !drawnSpansInView(of: (old + new).map(\.rangeValue)).isEmpty else {
            return
        }
        editor.needsDisplay = true
    }

    /// Fills the selection colour over the selected glyphs of rendered blocks
    /// and over selected pills in view. Collapsed lines draw nothing.
    func drawSelection(in dirty: NSRect) {
        guard isRunning, let editor, let manager = editor.textLayoutManager else {
            return
        }
        let selected = editor.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        let spans = drawnSpansInView(of: selected)
        guard !spans.isEmpty, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let origin = editor.textContainerOrigin
        context.saveGState()
        context.setFillColor(resolved(Theme.selection))
        var drawn = Set<Int>()
        for span in spans where drawn.insert(span.location).inserted {
            guard let location = TextKit2Geometry.location(span.location, in: manager),
                  let fragment = manager.textLayoutFragment(for: location) as? WritingFragment
            else {
                continue
            }
            let frame = fragment.layoutFragmentFrame
            for rect in fragment.selectionRects(for: selected) {
                let rect = rect.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
                if rect.intersects(dirty) {
                    context.fill(rect)
                }
            }
        }
        context.restoreGState()
    }

    /// The paragraphs of rendered blocks and pills in the viewport that
    /// `ranges` touch.
    private func drawnSpansInView(of ranges: [NSRange]) -> [NSRange] {
        guard let model, let manager = editor?.textLayoutManager else {
            return []
        }
        let view: NSRange? = manager.textViewportLayoutController.viewportRange.map {
            let start = TextKit2Geometry.offset(of: $0.location, in: manager)
            return NSRange(location: start, length: TextKit2Geometry.offset(of: $0.endLocation, in: manager) - start)
        }
        var spans: [NSRange] = []
        for range in ranges where range.length > 0 {
            let visible = view.map { NSIntersectionRange(range, $0) } ?? range
            if visible.length > 0 {
                spans += model.drawnSpans(intersecting: visible)
            }
        }
        return spans
    }
}

extension WritingFragment {
    /// The glyph boxes of `rendering` where this fragment draws them.
    func glyphMap(_ rendering: WritingRendering, block: NSRange) -> WritingGlyphMap {
        let column = columnWidth
        return WritingGlyphMap(
            rendering: rendering,
            block: block,
            imageOrigin: imageRect(rendering, column: column).origin,
            column: column,
        )
    }

    /// Where the selection is drawn in this fragment, from its top-left
    /// corner: over the selected glyphs of a rendered block, the whole pill of
    /// a selected pill, nothing elsewhere.
    func selectionRects(for selected: [NSRange]) -> [CGRect] {
        switch role {
        case let .rendered(rendering, block):
            glyphMap(rendering, block: block).selectionRects(for: selected)
        case .pill:
            selected.isEmpty ? [] : [CGRect(x: 0, y: 0, width: columnWidth, height: layoutFragmentFrame.height)]
        case .source, .collapsed:
            []
        }
    }
}

// MARK: - Tracking

extension ManuscriptTextView {
    /// What a drag through Prose's tracking loop extends: the fixed part of
    /// the selection, and the unit it grows by.
    private struct WritingDrag {
        let fixed: NSRange
        let granularity: NSTextSelection.Granularity
    }

    /// Handles a press in a rendered block or a pill, or the second and third
    /// press of a multi-click that began on one. Single click: the caret at
    /// the glyph's offset, and the block opens. Double-click: the word.
    /// Triple-click: the block's source. Shift-click extends the selection and
    /// opens nothing. A drag extends the selection, through glyph boxes in
    /// rendered fragments and through TextKit in source. Returns false for a
    /// press that AppKit should track.
    func trackWritingPointer(_ down: NSEvent) -> Bool {
        guard writing.isRunning, !hasMarkedText() else {
            return false
        }
        let clicks = max(1, down.clickCount)
        let hit: WritingPointerHit
        if let found = writing.pointerHit(at: containerPoint(of: down)) {
            hit = found
        } else if clicks > 1, let last = lastWritingClick, abs(last.location.x - down.locationInWindow.x) <= 4,
                  abs(last.location.y - down.locationInWindow.y) <= 4,
                  down.timestamp - last.time <= NSEvent.doubleClickInterval
        {
            hit = last.hit
        } else {
            lastWritingClick = nil
            return false
        }
        lastWritingClick = WritingClick(location: down.locationInWindow, time: down.timestamp, hit: hit)
        window?.makeFirstResponder(self)
        let selection = selectedRange()
        let extending = clicks == 1 && down.modifierFlags.contains(.shift)
        let drag = if extending {
            WritingDrag(
                fixed: NSRange(location: writing.fixedEnd(of: selection, toward: hit.offset), length: 0),
                granularity: .character,
            )
        } else if clicks == 1 {
            WritingDrag(fixed: NSRange(location: hit.offset, length: 0), granularity: .character)
        } else if clicks == 2 {
            WritingDrag(fixed: wordRange(at: hit.offset), granularity: .word)
        } else {
            WritingDrag(fixed: hit.block, granularity: .paragraph)
        }
        // A press inside the selection may start dragging the text itself.
        let movesSelection = clicks == 1 && !extending && selection.length > 0
            && NSLocationInRange(hit.offset, selection)
        selectingWithMouse = true
        var current = movesSelection ? selection : extend(drag, to: hit.offset, block: hit.block)
        selectInTracking(current, stillSelecting: true)
        while let event = nextPointerEvent(), event.type != .leftMouseUp {
            guard event.type == .leftMouseDragged else {
                continue
            }
            if movesSelection {
                let distance = hypot(
                    event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y,
                )
                if distance >= 3, pointerEvents == nil {
                    selectingWithMouse = false
                    _ = dragSelection(with: event, offset: .zero, slideBack: true)
                    return true
                }
                continue
            }
            autoscroll(with: event)
            prepareForPointerInteraction()
            let point = containerPoint(of: event)
            if let target = writing.pointerHit(at: point, anchor: drag.fixed.location) {
                current = extend(drag, to: target.offset, block: target.block)
            } else if let manager = textLayoutManager, let offset = TextKit2Geometry.insertionOffset(
                at: point,
                in: manager,
            ) {
                current = extend(drag, to: offset, block: nil)
            }
            selectInTracking(current, stillSelecting: true)
        }
        if movesSelection {
            // Pressed in the selection and let go without dragging.
            current = NSRange(location: hit.offset, length: 0)
        }
        selectInTracking(current, stillSelecting: false)
        selectingWithMouse = false
        selectionChanged(byPointer: true, anchor: drag.granularity == .character ? drag.fixed.location : nil)
        return true
    }

    /// The pointer in container coordinates.
    func containerPoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    /// The word that holds the character at `offset`, as TextKit selects
    /// words; empty at the end of the text.
    func wordRange(at offset: Int) -> NSRange {
        let text = string as NSString
        guard let manager = textLayoutManager, offset < text.length,
              let character = TextKit2Geometry.textRange(text.rangeOfComposedCharacterSequence(at: offset), in: manager)
        else {
            return NSRange(location: offset, length: 0)
        }
        let word = manager.textSelectionNavigation.textSelection(
            for: .word,
            enclosing: NSTextSelection(range: character, affinity: .downstream, granularity: .character),
        )
        guard let range = word.textRanges.first else {
            return NSRange(location: offset, length: 0)
        }
        let start = TextKit2Geometry.offset(of: range.location, in: manager)
        return NSRange(location: start, length: TextKit2Geometry.offset(of: range.endLocation, in: manager) - start)
    }

    private func extend(_ drag: WritingDrag, to offset: Int, block: NSRange?) -> NSRange {
        switch drag.granularity {
        case .word:
            return NSUnionRange(drag.fixed, wordRange(at: offset))
        case .paragraph:
            let text = string as NSString
            let paragraph = block ?? text.paragraphRange(for: NSRange(location: min(offset, text.length), length: 0))
            return NSUnionRange(drag.fixed, paragraph)
        default:
            let fixed = drag.fixed.location
            return NSRange(location: min(fixed, offset), length: abs(offset - fixed))
        }
    }

    private func nextPointerEvent() -> NSEvent? {
        if let pointerEvents {
            return pointerEvents()
        }
        return window?.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true,
        )
    }

    private func selectInTracking(_ range: NSRange, stillSelecting: Bool) {
        let length = (string as NSString).length
        let start = min(max(range.location, 0), length)
        let range = NSRange(location: start, length: min(max(NSMaxRange(range), start), length) - start)
        setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: stillSelecting)
    }
}
