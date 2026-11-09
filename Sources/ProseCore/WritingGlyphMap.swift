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

    // MARK: - Lines for the keyboard

    /// A drawn line that holds source glyphs: its vertical extent, generated
    /// glyphs included, and its source glyphs from left to right.
    public struct Line: Equatable, Sendable {
        public let minY: CGFloat
        public let maxY: CGFloat
        public let boxes: [Box]

        public var midY: CGFloat {
            (minY + maxY) / 2
        }

        /// The smallest and the largest source offset on the line.
        public var first: Int {
            boxes.compactMap(\.offset).min() ?? 0
        }

        public var last: Int {
            boxes.compactMap(\.offset).max() ?? 0
        }
    }

    /// The lines that hold source glyphs, top to bottom. Keyboard moves inside
    /// a rendered block step through these, not through TextKit's source lines.
    public func sourceLines() -> [Line] {
        lines().compactMap { line in
            let boxes = line.filter { $0.offset != nil }.sorted { $0.rect.minX < $1.rect.minX }
            guard !boxes.isEmpty else {
                return nil
            }
            return Line(
                minY: line.map(\.rect.minY).min() ?? 0,
                maxY: line.map(\.rect.maxY).max() ?? 0,
                boxes: boxes,
            )
        }
    }

    /// Where a caret at `offset` sits among `lines`: before the first glyph of
    /// its character, else after the last glyph of an earlier character, else
    /// before the block's first glyph. Nil when `lines` is empty.
    public func caret(at offset: Int, in lines: [Line]) -> (line: Int, x: CGFloat)? {
        guard let start = lines.first?.boxes.first else {
            return nil
        }
        var before: (line: Int, offset: Int, x: CGFloat)?
        for (index, line) in lines.enumerated() {
            for box in line.boxes {
                guard let source = box.offset else {
                    continue
                }
                if source == offset {
                    return (index, box.rect.minX)
                }
                if source < offset, before.map({ source >= $0.offset }) ?? true {
                    before = (index, source, box.rect.maxX)
                }
            }
        }
        return before.map { ($0.line, $0.x) } ?? (0, start.rect.minX)
    }

    /// The insertion position on `line` nearest `x`: its glyph and whether the
    /// caret goes after the character, as a click at that x would put it.
    public func position(on line: Line, nearest x: CGFloat) -> Hit {
        func across(_ rect: CGRect) -> CGFloat {
            max(rect.minX - x, 0, x - rect.maxX)
        }
        var best: Box?
        for box in line.boxes {
            guard let current = best else {
                best = box
                continue
            }
            let score = (across(box.rect), abs(box.rect.midX - x))
            if score < (across(current.rect), abs(current.rect.midX - x)) {
                best = box
            }
        }
        guard let best, let offset = best.offset else {
            return .missed
        }
        return .glyph(offset: offset, trailing: x > best.rect.midX + 0.5)
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
