import CoreGraphics
import Foundation

/// A rendered block's glyph boxes where its fragment draws them: points from
/// the fragment's top-left corner, with source offsets in today's text. Writing
/// mode maps pointer positions and draws selection highlights through it,
/// never through TextKit, whose lines inside a rendered block are the source
/// lines' (decisions 6 and 7 of the Phase 3 note).
public struct WritingGlyphMap: Sendable {
    public struct Box: Equatable, Sendable {
        public let rect: CGRect
        /// Nil for generated text: numbers, reference text.
        public let offset: Int?
    }

    public enum Hit: Equatable, Sendable {
        /// The glyph of the character at `offset`; `trailing` when the point
        /// lies right of the box's middle, so the caret goes after it.
        case glyph(offset: Int, trailing: Bool)
        /// The nearest glyph is generated text.
        case generated
        /// No glyph on the point's line and none within `reach`.
        case missed
    }

    /// How far, in points, a point off every glyph's line may lie from the
    /// nearest box and still hit it: about one line of body text at 1.3 times.
    public static let reach: CGFloat = 24

    /// The block's range now.
    public let block: NSRange
    public let boxes: [Box]
    /// The fragment's column, the image and every glyph box.
    public let bounds: CGRect

    /// `imageOrigin` is where the fragment draws the image's top-left corner,
    /// `column` the fragment's width.
    public init(rendering: WritingRendering, block: NSRange, imageOrigin: CGPoint, column: CGFloat) {
        self.block = block
        let scale = CGFloat(rendering.scale)
        let drawn = rendering.drawnRect
        var bounds = CGRect(x: 0, y: 0, width: column, height: rendering.height)
            .union(CGRect(origin: imageOrigin, size: rendering.size))
        var boxes: [Box] = []
        boxes.reserveCapacity(rendering.glyphs.count)
        for glyph in rendering.glyphs where glyph.rect.width > 0 || glyph.rect.height > 0 {
            let rect = CGRect(
                x: imageOrigin.x + (glyph.rect.minX - drawn.minX) * scale,
                y: imageOrigin.y + (glyph.rect.minY - drawn.minY) * scale,
                width: glyph.rect.width * scale,
                height: glyph.rect.height * scale,
            )
            // A source outside the block (a reference's target) is generated here.
            let offset = rendering.offset(of: glyph, blockAt: block.location)
                .flatMap { $0 >= block.location && $0 < NSMaxRange(block) ? $0 : nil }
            boxes.append(Box(rect: rect, offset: offset))
            bounds = bounds.union(rect)
        }
        self.boxes = boxes
        self.bounds = bounds
    }

    /// The glyph under or nearest `point`. A box whose line holds the point
    /// wins by horizontal distance; otherwise the nearest box within `reach`.
    public func hit(at point: CGPoint) -> Hit {
        func across(_ rect: CGRect) -> CGFloat {
            max(rect.minX - point.x, 0, point.x - rect.maxX)
        }
        func centre(_ rect: CGRect) -> CGFloat {
            hypot(rect.midX - point.x, rect.midY - point.y)
        }
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(across(rect), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        var best: (index: Int, score: (CGFloat, CGFloat))?
        for (index, box) in boxes.enumerated() where box.rect.minY - 1 <= point.y && point.y <= box.rect.maxY + 1 {
            let score = (across(box.rect), centre(box.rect))
            if best.map({ score < $0.score }) ?? true {
                best = (index, score)
            }
        }
        if best == nil {
            for (index, box) in boxes.enumerated() {
                let score = (distance(box.rect), centre(box.rect))
                if score.0 <= Self.reach, best.map({ score < $0.score }) ?? true {
                    best = (index, score)
                }
            }
        }
        guard let index = best?.index else {
            return .missed
        }
        let box = boxes[index]
        guard let offset = box.offset else {
            return .generated
        }
        // At the middle (to half a point) the caret goes before the character.
        return .glyph(offset: offset, trailing: point.x > box.rect.midX + 0.5)
    }

    /// Where the selection is drawn over the block: everything when one of
    /// `selected` covers the block; otherwise, on each line, from the first to
    /// the last selected glyph, as tall as the line's boxes.
    public func selectionRects(for selected: [NSRange]) -> [CGRect] {
        let selected = selected.filter { $0.length > 0 }
        guard !selected.isEmpty else {
            return []
        }
        if selected.contains(where: { $0.location <= block.location && NSMaxRange($0) >= NSMaxRange(block) }) {
            return [bounds]
        }
        func isSelected(_ box: Box) -> Bool {
            guard let offset = box.offset else {
                return false
            }
            return selected.contains { NSLocationInRange(offset, $0) }
        }
        var rects: [CGRect] = []
        for line in lines() {
            let chosen = line.filter(isSelected)
            guard let first = chosen.first else {
                continue
            }
            let top = line.map(\.rect.minY).min() ?? first.rect.minY
            let bottom = line.map(\.rect.maxY).max() ?? first.rect.maxY
            let left = chosen.map(\.rect.minX).min() ?? first.rect.minX
            let right = chosen.map(\.rect.maxX).max() ?? first.rect.maxX
            rects.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        return rects
    }

    /// The boxes grouped into lines: boxes whose vertical extents overlap.
    func lines() -> [[Box]] {
        let sorted = boxes.filter { $0.rect.height > 0 }.sorted { $0.rect.minY < $1.rect.minY }
        var lines: [[Box]] = []
        var bottom = -CGFloat.infinity
        for box in sorted {
            if box.rect.minY < bottom - 0.5, !lines.isEmpty {
                lines[lines.count - 1].append(box)
                bottom = max(bottom, box.rect.maxY)
            } else {
                lines.append([box])
                bottom = box.rect.maxY
            }
        }
        return lines
    }
}
