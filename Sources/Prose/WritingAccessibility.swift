import AppKit
import ProseCore

/// VoiceOver and input methods in Writing mode (step G of the Phase 3 note).
///
/// What VoiceOver hears stays the source: the editor's value, its strings
/// for ranges, its lines and its insertion point are NSTextView's, read from
/// the text storage and from the source layout that TextKit keeps under every
/// rendered block. Lines are therefore the lines of the source layout, as in
/// Code mode, and their numbers do not change when a block swaps.
///
/// Geometry does not come from TextKit inside rendered blocks and pills,
/// because there TextKit lays out hidden source lines. Left to itself,
/// NSTextView answers a zero rectangle for the accessibility frame of a range
/// in a rendered block (`ManuscriptLayoutManager` drops its selection
/// segments there), the hidden source line for
/// `firstRect(forCharacterRange:actualRange:)`, and offset 0 for the range and
/// character at a point. So in Writing mode:
///
/// - `accessibilityFrame(for:)` (AXBoundsForRange) is the union of the glyph
///   boxes of the range's characters, the pill for a pill, and NSTextView's
///   frames for the parts in source.
/// - `firstRect(forCharacterRange:actualRange:)` is the first drawn line of
///   the range's glyphs.
/// - `accessibilityRange(for:)` (AXRangeForPosition) and
///   `characterIndex(for:)` map the point through the glyph boxes, as clicks
///   do.
///
/// A range with no glyph of its own (markup such as `$` or `=`, spaces, line
/// ends) is drawn where the caret would be: on its drawn line, between the
/// glyphs around it.
extension WritingController {
    /// The rectangles, in container coordinates, where the characters of
    /// `range` are drawn in rendered blocks and pills, and the parts of
    /// `range` that lie in source. Nil when no part of `range` is drawn
    /// rendered or as a pill.
    func drawnRects(of range: NSRange) -> (rects: [CGRect], source: [NSRange])? {
        guard isRunning, let model, let editor, range.location >= 0, range.location != NSNotFound,
              NSMaxRange(range) <= (editor.string as NSString).length
        else {
            return nil
        }
        if range.length == 0 {
            return drawnBlock(holding: range.location).map { ([caretRect(at: range.location, in: $0)], []) }
        }
        let spans = model.drawnSpans(intersecting: range)
        guard !spans.isEmpty else {
            return nil
        }
        var rects: [CGRect] = []
        for span in spans {
            if let drawn = drawnBlock(holding: span.location) {
                rects += self.rects(of: NSIntersectionRange(range, span), in: drawn).map(\.rect)
            }
        }
        return (rects, nativeSelectionPieces(of: range))
    }

    /// The first drawn line of `range` when it starts in a rendered block or
    /// a pill, in container coordinates, and the part of `range` it holds.
    func firstDrawnRect(of range: NSRange) -> (rect: CGRect, range: NSRange)? {
        guard isRunning, let editor, range.location >= 0, range.location != NSNotFound,
              NSMaxRange(range) <= (editor.string as NSString).length,
              let drawn = drawnBlock(holding: range.location)
        else {
            return nil
        }
        let span = (editor.string as NSString).paragraphRange(for: drawn.block)
        let piece = NSIntersectionRange(range, span)
        guard piece.length > 0 else {
            return (caretRect(at: range.location, in: drawn), NSRange(location: range.location, length: 0))
        }
        return rects(of: piece, in: drawn).first
    }

    /// Where the characters of `piece`, which lies in `drawn`, are drawn: one
    /// rectangle per drawn line that holds their glyphs, in order, with the
    /// part of `piece` up to that line's last glyph; the pill for a pill; the
    /// caret's place when no character of `piece` has a glyph.
    private func rects(of piece: NSRange, in drawn: WritingDrawnBlock) -> [(rect: CGRect, range: NSRange)] {
        guard let map = drawn.map else {
            return [(caretRect(at: piece.location, in: drawn), piece)]
        }
        let frame = drawn.frame
        var found: [(rect: CGRect, range: NSRange)] = []
        var start = piece.location
        for line in drawn.lines {
            let chosen = line.boxes.filter { $0.offset.map { NSLocationInRange($0, piece) } ?? false }
            guard let first = chosen.first else {
                continue
            }
            let rect = chosen.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            let last = chosen.compactMap(\.offset).max() ?? piece.location
            let end = min(max(characterEnd(of: last), start), NSMaxRange(piece))
            found.append((rect.offsetBy(dx: frame.minX, dy: frame.minY), NSRange(location: start, length: end - start)))
            start = end
        }
        guard found.isEmpty else {
            return found
        }
        // No glyph of its own: from the caret before it to the caret after it.
        let lines = drawn.lines
        var rect = caretRect(at: piece.location, in: drawn)
        let before = map.caret(at: piece.location, in: lines)
        let after = map.caret(at: NSMaxRange(piece), in: lines)
        if let before, let after, before.line == after.line, after.x > before.x {
            rect.size.width = after.x - before.x
        }
        return [(rect, piece)]
    }

    /// The caret's rectangle at `offset` in `drawn`, in container
    /// coordinates: on its drawn line, as tall as the line; the pill for a
    /// pill; the block's frame for a block with no source glyph.
    private func caretRect(at offset: Int, in drawn: WritingDrawnBlock) -> CGRect {
        let frame = drawn.frame
        if let pill = drawn.pill {
            let column = editor?.textContainer?.size.width ?? frame.width
            return WritingMetrics.pillRect(label: pill.text, column: column).offsetBy(dx: frame.minX, dy: frame.minY)
        }
        let lines = drawn.lines
        guard let caret = drawn.map?.caret(at: offset, in: lines) else {
            return frame
        }
        let line = lines[caret.line]
        return CGRect(x: frame.minX + caret.x, y: frame.minY + line.minY, width: 0, height: line.maxY - line.minY)
    }

    private func characterEnd(of offset: Int) -> Int {
        let text = (editor?.string ?? "") as NSString
        guard offset < text.length else {
            return offset
        }
        return NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
    }
}

extension ManuscriptTextView {
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let drawn = writing.drawnRects(of: range), !drawn.rects.isEmpty else {
            return super.accessibilityFrame(for: range)
        }
        var frame = drawn.rects.dropFirst().reduce(drawn.rects[0]) { $0.union($1) }
        guard let screen = screenRect(fromContainer: frame) else {
            return super.accessibilityFrame(for: range)
        }
        frame = screen
        for piece in drawn.source where piece.length > 0 {
            let native = super.accessibilityFrame(for: piece)
            if !native.isEmpty {
                frame = frame.union(native)
            }
        }
        return frame
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let local = containerPoint(fromScreen: point), let offset = writing.characterHit(at: local) else {
            return super.accessibilityRange(for: point)
        }
        let text = string as NSString
        guard offset < text.length else {
            return NSRange(location: text.length, length: 0)
        }
        return text.rangeOfComposedCharacterSequence(at: offset)
    }

    override func characterIndex(for point: NSPoint) -> Int {
        guard let local = containerPoint(fromScreen: point), let offset = writing.characterHit(at: local) else {
            return super.characterIndex(for: point)
        }
        return offset
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let first = writing.firstDrawnRect(of: range), let screen = screenRect(fromContainer: first.rect) else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        actualRange?.pointee = first.range
        return screen
    }

    // MARK: - Parameterized attributes

    // Assistive apps ask through `accessibilityAttributeValue(_:forParameter:)`,
    // which dispatches AXBoundsForRange and AXRangeForPosition to these
    // selectors. NSTextView implements them itself, without calling
    // `accessibilityFrame(for:)` or `accessibilityRange(for:)`, so in Writing
    // mode they answer through those overrides; otherwise NSTextView answers.

    @objc(accessibilityBoundsForRangeAttributeForParameter:)
    func writingAccessibilityBounds(forRange parameter: AnyObject?) -> AnyObject? {
        guard let range = (parameter as? NSValue)?.rangeValue, writing.drawnRects(of: range) != nil else {
            return nativeAccessibility(#selector(writingAccessibilityBounds(forRange:)), parameter)
        }
        return NSValue(rect: accessibilityFrame(for: range))
    }

    @objc(accessibilityRangeForPositionAttributeForParameter:)
    func writingAccessibilityRange(forPosition parameter: AnyObject?) -> AnyObject? {
        guard let point = (parameter as? NSValue)?.pointValue,
              let local = containerPoint(fromScreen: point), writing.characterHit(at: local) != nil
        else {
            return nativeAccessibility(#selector(writingAccessibilityRange(forPosition:)), parameter)
        }
        return NSValue(range: accessibilityRange(for: point))
    }

    /// NSTextView's own answer for a parameterized attribute selector.
    private func nativeAccessibility(_ selector: Selector, _ parameter: AnyObject?) -> AnyObject? {
        typealias Answer = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else {
            return nil
        }
        let answer = unsafeBitCast(method_getImplementation(method), to: Answer.self)
        return answer(self, selector, parameter)?.takeUnretainedValue()
    }

    /// `rect` in container coordinates, on the screen.
    func screenRect(fromContainer rect: CGRect) -> NSRect? {
        guard let window else {
            return nil
        }
        let local = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return window.convertToScreen(convert(local, to: nil))
    }

    /// A screen point in container coordinates.
    func containerPoint(fromScreen point: NSPoint) -> CGPoint? {
        guard let window else {
            return nil
        }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return CGPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
    }
}
