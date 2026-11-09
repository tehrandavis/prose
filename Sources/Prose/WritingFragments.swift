import AppKit
import ProseCore

/// Sizes of what Writing mode draws in place of source paragraphs.
enum WritingMetrics {
    /// Blocks render at column width ÷ 1.3 and draw at 1.3 times (spec decision 2).
    static let scale = 1.3
    /// Focus mode draws 18/16 larger: 1.4625 (decision 3 of the Phase 4 note).
    static let focusScale = scale * 18 / 16
    /// A pill's rounded rectangle and the space above and below it.
    static let pillHeight: CGFloat = 24
    static let pillSpacing: CGFloat = 6
    static let pillRadius: CGFloat = 8
    static let pillPadding: CGFloat = 10
    static var pillFont: NSFont {
        NSFont.systemFont(ofSize: 12)
    }

    /// The amber bar of a stale render, in the margin left of the column.
    static let staleBar = CGRect(x: -9, y: 0, width: 3, height: 0)

    static var pillFragmentHeight: CGFloat {
        pillHeight + 2 * pillSpacing
    }

    /// Where a pill with `label` draws its rounded rectangle, from its
    /// fragment's top-left corner, in a column `column` wide.
    static func pillRect(label: String, column: CGFloat) -> CGRect {
        let size = NSAttributedString(string: label, attributes: [.font: pillFont]).size()
        let width = min(column, ceil(size.width) + 2 * pillPadding)
        return CGRect(x: 0, y: pillSpacing, width: max(width, 2 * pillRadius), height: pillHeight)
    }
}

/// One fragment class for every TextKit paragraph while Writing mode has been
/// used: it reads its paragraph's role from the layout model each time TextKit
/// reads its frame or draws, so `invalidateLayout(for:)` alone swaps it
/// between source, rendered, pill and collapsed (approved change 3 of the
/// Phase 3 note). Nothing is drawn into, or hidden in, the text storage.
final class WritingFragment: NSTextLayoutFragment {
    private weak var controller: WritingController?
    /// Draws by role, for tests.
    private(set) var draws: [String: Int] = [:]

    init(textElement: NSTextElement, range: NSTextRange?, controller: WritingController) {
        self.controller = controller
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// What the paragraph draws now; source while Writing mode is off.
    var role: WritingRole {
        guard let controller, let offset else {
            return .source
        }
        return MainActor.assumeIsolated { controller.role(ofParagraphAt: offset) }
    }

    /// The paragraph's UTF-16 offset.
    var offset: Int? {
        guard let manager = textLayoutManager else {
            return nil
        }
        return manager.offset(from: manager.documentRange.location, to: rangeInElement.location)
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        switch role {
        case .source:
            break
        case let .rendered(rendering, _):
            frame.size.height = rendering.height
        case .collapsed:
            frame.size.height = 0
        case .pill:
            frame.size.height = WritingMetrics.pillFragmentHeight
        }
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        switch role {
        case .source:
            return super.renderingSurfaceBounds
        case let .rendered(rendering, _):
            let width = columnWidth
            var bar = WritingMetrics.staleBar
            bar.size.height = rendering.height
            return imageRect(rendering, column: width).union(bar)
                .union(CGRect(x: 0, y: 0, width: width, height: rendering.height))
        case .collapsed:
            return .zero
        case .pill:
            return CGRect(x: 0, y: 0, width: columnWidth, height: WritingMetrics.pillFragmentHeight)
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let role = role
        switch role {
        case .source:
            count("source")
            dimming(layer: super.renderingSurfaceBounds, at: point, in: context) {
                super.draw(at: point, in: context)
            }
        case let .rendered(rendering, _):
            count("rendered")
            dimming(layer: nil, at: point, in: context) {
                drawRendered(rendering, at: point, in: context)
            }
        case .collapsed:
            count("collapsed")
        case let .pill(pill):
            count("pill")
            dimming(layer: renderingSurfaceBounds, at: point, in: context) {
                drawPill(pill, at: point, in: context)
            }
        }
    }

    private func count(_ role: String) {
        draws[role, default: 0] += 1
    }

    /// Whether Focus mode draws this paragraph dimmed: outside the focus
    /// blocks (decision 4 of the Phase 4 note).
    var dimmed: Bool {
        guard let controller, let offset else {
            return false
        }
        return MainActor.assumeIsolated { controller.dims(paragraphAt: offset) }
    }

    /// Runs `draw` at `WritingFocus.dimmedAlpha` opacity while the paragraph
    /// is dimmed. A rendered block's image and stale bar are separate single
    /// draws, so the alpha applies to each (`layer` nil). Source text and a
    /// pill draw overlapping marks (glyphs over backgrounds, a label over its
    /// fill), so they draw into a transparency layer over `layer` (from the
    /// fragment's origin) that is composited at that alpha as one, keeping
    /// exactly 45 percent of their contrast.
    private func dimming(layer: CGRect?, at point: CGPoint, in context: CGContext, _ draw: () -> Void) {
        guard dimmed else {
            draw()
            return
        }
        draws["dimmed", default: 0] += 1
        context.saveGState()
        context.setAlpha(WritingFocus.dimmedAlpha)
        if let layer {
            context.beginTransparencyLayer(in: layer.offsetBy(dx: point.x, dy: point.y), auxiliaryInfo: nil)
            draw()
            context.endTransparencyLayer()
        } else {
            draw()
        }
        context.restoreGState()
    }

    /// The text container's width: the column blocks render for.
    var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? super.layoutFragmentFrame.width
    }

    /// Where the block's image goes, from the fragment's origin. During a live
    /// resize, and until the new renders arrive, an image made for another
    /// column width is centered in this one.
    func imageRect(_ rendering: WritingRendering, column: CGFloat) -> CGRect {
        let scale = rendering.scale
        let drawn = rendering.drawnRect
        let shift = (column - rendering.appearance.columnWidth) / 2
        return CGRect(
            x: drawn.minX * scale + (abs(shift) < 0.5 ? 0 : shift),
            y: 0,
            width: drawn.width * scale,
            height: drawn.height * scale,
        )
    }

    private func drawRendered(_ rendering: WritingRendering, at point: CGPoint, in context: CGContext) {
        let column = columnWidth
        if let image = rendering.image {
            let rect = imageRect(rendering, column: column).offsetBy(dx: point.x, dy: point.y)
            context.saveGState()
            context.interpolationQuality = .high
            // TextKit draws with y pointing down; CGImage draws with y up.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        let controller = controller
        guard let colors = MainActor.assumeIsolated({ controller?.staleColor() }) else {
            return
        }
        var bar = WritingMetrics.staleBar.offsetBy(dx: point.x, dy: point.y)
        bar.size.height = rendering.height
        context.saveGState()
        context.setFillColor(colors)
        context.fill(bar)
        context.restoreGState()
    }

    private func drawPill(_ pill: WritingPill, at point: CGPoint, in context: CGContext) {
        let controller = controller
        guard let colors = MainActor.assumeIsolated({ controller?.pillColors(muted: pill.muted) }) else {
            return
        }
        let column = columnWidth
        let attributes: [NSAttributedString.Key: Any] = [
            .font: WritingMetrics.pillFont,
            .foregroundColor: colors.text,
        ]
        let label = NSAttributedString(string: pill.text, attributes: attributes)
        let size = label.size()
        let rect = WritingMetrics.pillRect(label: pill.text, column: column).offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: WritingMetrics.pillRadius,
            cornerHeight: WritingMetrics.pillRadius,
            transform: nil,
        ))
        context.setFillColor(colors.fill)
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let textRect = CGRect(
            x: rect.minX + WritingMetrics.pillPadding,
            y: rect.midY - size.height / 2,
            width: rect.width - 2 * WritingMetrics.pillPadding,
            height: size.height,
        )
        label.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

/// The colours a pill draws with, resolved for the editor's appearance.
struct WritingPillColors {
    let fill: CGColor
    let text: NSColor
}

/// Gives every paragraph a `WritingFragment` once Writing mode has been used.
/// NSTextView sets no layout manager delegate of its own.
extension WritingController: @preconcurrency NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _: NSTextLayoutManager,
        textLayoutFragmentFor _: NSTextLocation,
        in textElement: NSTextElement,
    ) -> NSTextLayoutFragment {
        WritingFragment(textElement: textElement, range: textElement.elementRange, controller: self)
    }
}
