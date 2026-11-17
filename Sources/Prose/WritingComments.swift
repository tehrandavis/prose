import AppKit
import ProseCore

/// Comments in Writing and Focus mode (Phase 8 decisions 4 and 6): the
/// highlight over a rendered block's glyphs, drawn in the editor's
/// `drawBackground(in:)` under the transparent images and before the
/// selection, and the caret's step over a marker. Source paragraphs get
/// their highlight from rendering attributes (`CommentController`), which
/// TextKit draws with the text, so they dim with it in Focus mode.
extension WritingController {
    /// The width of the outline round a rendered block whose anchor has no
    /// glyph box (an image, for example).
    static let commentOutlineWidth: CGFloat = 1.5

    /// The source range of the laid-out viewport.
    private func viewportRange() -> NSRange? {
        guard let manager = editor?.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange
        else {
            return nil
        }
        let start = TextKit2Geometry.offset(of: viewport.location, in: manager)
        return NSRange(location: start, length: TextKit2Geometry.offset(of: viewport.endLocation, in: manager) - start)
    }

    /// The highlights in view that lie over rendered blocks, by the offset
    /// of the block's first paragraph.
    private func renderedHighlightsInView() -> [Int: [CommentHighlight]] {
        guard isRunning, let model, let editor, let view = viewportRange() else {
            return [:]
        }
        var byBlock: [Int: [CommentHighlight]] = [:]
        for highlight in editor.comments.highlights(intersecting: view) {
            let visible = NSIntersectionRange(highlight.range, view)
            for span in model.drawnSpans(intersecting: visible) {
                byBlock[span.location, default: []].append(highlight)
            }
        }
        return byBlock
    }

    /// The comments' highlights changed: the editor draws them again where
    /// they lie over rendered blocks in view, now or before.
    func commentHighlightsChanged() {
        guard isRunning, let editor else {
            return
        }
        let shown = !renderedHighlightsInView().isEmpty
        if shown || commentHighlightsShown {
            editor.setNeedsDisplay(editor.visibleRect)
        }
        commentHighlightsShown = shown
    }

    /// Fills each anchor's glyphs in the rendered blocks in view, line by
    /// line, in its strength's colour; at Focus mode's dimmed alpha in a
    /// dimmed block. A block whose anchor holds text but no glyph box gets
    /// an outline round its image instead.
    func drawCommentHighlights(in dirty: NSRect) {
        let byBlock = renderedHighlightsInView()
        guard !byBlock.isEmpty, let editor, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let origin = editor.textContainerOrigin
        let text = editor.string as NSString
        context.saveGState()
        defer { context.restoreGState() }
        for (start, highlights) in byBlock {
            guard let fragment = fragment(at: start), case let .rendered(rendering, block) = fragment.role else {
                continue
            }
            let frame = fragment.layoutFragmentFrame
            let offset = CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y)
            let map = fragment.glyphMap(rendering, block: block)
            context.setAlpha(fragment.dimmed ? WritingFocus.dimmedAlpha : 1)
            for highlight in highlights {
                let color = resolved(highlight.strength.color)
                let rects = map.lineRects(for: [highlight.range])
                guard rects.isEmpty else {
                    context.setFillColor(color)
                    for rect in rects {
                        let rect = rect.offsetBy(dx: offset.x, dy: offset.y)
                        if rect.intersects(dirty) {
                            context.fill(rect)
                        }
                    }
                    continue
                }
                let inBlock = NSIntersectionRange(highlight.range, block)
                guard inBlock.length > 0,
                      !text.substring(with: inBlock).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
                let width = Self.commentOutlineWidth
                let image = fragment.imageRect(rendering, column: fragment.columnWidth)
                    .offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -width / 2, dy: -width / 2)
                if image.intersects(dirty) {
                    context.setStrokeColor(color)
                    context.setLineWidth(width)
                    context.stroke(image)
                }
            }
        }
    }

    // MARK: - Left and Right over a marker

    /// The marker of an attached comment that `offset` lies strictly inside,
    /// in Writing and Focus mode; nil in Code mode and elsewhere.
    func commentMarker(around offset: Int) -> NSRange? {
        guard isRunning, let editor else {
            return nil
        }
        let text = editor.string as NSString
        for comment in editor.comments.placed {
            for marker in [comment.start, comment.end]
                where marker.location < offset && offset < NSMaxRange(marker) && NSMaxRange(marker) <= text.length
            {
                if CommentSyntax.marker(in: text, at: marker)?.id == comment.id {
                    return marker
                }
            }
        }
        return nil
    }

    /// Whether an end of `selection` lies strictly inside a marker of an
    /// attached comment.
    func endsInsideCommentMarker(_ selection: NSTextSelection, in manager: NSTextLayoutManager) -> Bool {
        guard isRunning, let range = selection.textRanges.first else {
            return false
        }
        let start = TextKit2Geometry.offset(of: range.location, in: manager)
        let end = TextKit2Geometry.offset(of: range.endLocation, in: manager)
        return commentMarker(around: start) != nil || commentMarker(around: end) != nil
    }

    /// Where a Left or Right move from `previous` that landed on `offset`
    /// goes instead: past the whole marker it entered, in one step.
    func pastCommentMarker(_ offset: Int, from previous: Int) -> Int {
        guard let marker = commentMarker(around: offset) else {
            return offset
        }
        return offset > previous ? NSMaxRange(marker) : marker.location
    }
}

/// Resolved comments while Show Resolved Comments is on (decision 6): a 1 pt
/// underline in the secondary text colour under the anchor, no fill. Drawn
/// in `drawBackground(in:)` in every mode, so nothing reaches the storage.
extension ManuscriptTextView {
    static let resolvedUnderlineWidth: CGFloat = 1

    /// The underline rectangles of `range` in container coordinates: under
    /// each drawn line of its glyphs in rendered blocks and pills, and under
    /// each line of its source text elsewhere.
    func resolvedUnderlineRects(of range: NSRange) -> [CGRect] {
        guard let manager = textLayoutManager else {
            return []
        }
        var lines: [CGRect] = []
        var source = [range]
        if let drawn = writing.drawnRects(of: range) {
            lines = drawn.rects
            source = drawn.source
        }
        for piece in source where piece.length > 0 {
            lines += TextKit2Geometry.segments(piece, type: .standard, in: manager)
        }
        let width = Self.resolvedUnderlineWidth
        return lines.filter { $0.width > 0 }.map {
            CGRect(x: $0.minX, y: $0.maxY - 2 * width, width: $0.width, height: width)
        }
    }

    /// Draws the underline of every resolved comment in view.
    func drawResolvedCommentUnderlines(in dirty: NSRect) {
        let ranges = comments.resolvedUnderlines
        guard !ranges.isEmpty, let manager = textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange
        else {
            return
        }
        let start = TextKit2Geometry.offset(of: viewport.location, in: manager)
        let view = NSRange(
            location: start,
            length: TextKit2Geometry.offset(of: viewport.endLocation, in: manager) - start,
        )
        let origin = textContainerOrigin
        Theme.nativeSecondary.setFill()
        for range in ranges where NSIntersectionRange(range, view).length > 0 {
            for rect in resolvedUnderlineRects(of: NSIntersectionRange(range, view)) {
                let rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                if rect.intersects(dirty) {
                    rect.fill()
                }
            }
        }
    }
}
