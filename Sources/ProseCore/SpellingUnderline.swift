import CoreGraphics
import Foundation

/// The dotted spelling underline that Writing mode draws under a misspelled
/// word in a rendered block (decision 9 of the Phase 4 note), copied from the
/// one TextKit 2 draws for `.spellingState` in source.
///
/// Measured on macOS 27 (`cacheDisplay` of a TextKit 2 view at 1x, 2x and 3x,
/// system font and Times New Roman from 8 to 48 pt): the dots are rounded
/// squares in points, the same at every backing scale. From 12 pt their side
/// is `ceil(size / 7.5)`, at least 3 and at most 6 points, with corner radius
/// 0.37 times the side, one point apart. Below 12 pt they are 2.75 by 2
/// points, still 4 points apart. The dots start at the baseline and go down.
/// As many dots as fit across the word with one point between them are
/// centred under it, so a word's first and last dots sit inside its ends.
public enum SpellingUnderline {
    /// One dot's size, the corner radius and the distance from one dot's
    /// start to the next.
    public struct Pattern: Equatable, Sendable {
        public let width: CGFloat
        public let height: CGFloat
        public let radius: CGFloat
        public let period: CGFloat
    }

    /// The share of a glyph box's height (ascender to descender) below the
    /// baseline. The engine's glyph boxes carry no baseline; for the system
    /// font this share is 0.18 and for Libertinus Serif, Typst's default, 0.22.
    public static let descenderShare: CGFloat = 0.2

    /// A glyph box's height (ascender to descender) per point of font size,
    /// between the system font's 1.18 and Libertinus Serif's 1.14.
    public static let boxHeightPerPoint: CGFloat = 1.16

    /// The pattern TextKit draws for text of `fontSize` points.
    public static func pattern(fontSize: CGFloat) -> Pattern {
        guard fontSize >= 12 else {
            return Pattern(width: 2.75, height: 2, radius: 0.74, period: 4)
        }
        let side = min(6, max(3, ceil(fontSize / 7.5 - 0.001)))
        return Pattern(width: side, height: side, radius: (0.37 * side * 100).rounded() / 100, period: side + 1)
    }

    /// The dots under a word drawn from `minX` to `maxX` on a line whose
    /// glyph boxes end at `bottom` and are `boxHeight` tall, in the same
    /// coordinates (y pointing down). The baseline is estimated from the
    /// boxes; `snap` moves a y to a device pixel.
    public static func dots(
        minX: CGFloat,
        maxX: CGFloat,
        bottom: CGFloat,
        boxHeight: CGFloat,
        snap: (CGFloat) -> CGFloat = \.self,
    ) -> [CGRect] {
        let width = maxX - minX
        guard width > 0, boxHeight > 0 else {
            return []
        }
        let pattern = pattern(fontSize: boxHeight / boxHeightPerPoint)
        let gap = pattern.period - pattern.width
        let count = max(1, Int(((width + gap) / pattern.period).rounded(.down)))
        let span = CGFloat(count) * pattern.period - gap
        let start = minX + (width - span) / 2
        let top = snap(bottom - descenderShare * boxHeight)
        return (0 ..< count).map { index in
            CGRect(
                x: start + CGFloat(index) * pattern.period,
                y: top,
                width: pattern.width,
                height: pattern.height,
            )
        }
    }
}

public extension WritingGlyphMap {
    /// Where one misspelled range is drawn on one line: from its first glyph's
    /// left edge to its last glyph's right edge, the bottom of those glyphs'
    /// boxes, and their height.
    struct Underline: Equatable, Sendable {
        public let range: NSRange
        public let minX: CGFloat
        public let maxX: CGFloat
        public let bottom: CGFloat
        public let height: CGFloat
    }

    /// The underlines of `ranges`: for each range, one per drawn line that
    /// holds its glyphs, under the union of those glyphs' boxes. Generated
    /// text (numbers, reference text) has no source and is never underlined.
    func underlines(for ranges: [NSRange]) -> [Underline] {
        let ranges = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard !ranges.isEmpty else {
            return []
        }
        var result: [Underline] = []
        for line in lines() {
            for range in ranges {
                let chosen = line.filter { $0.offset.map { NSLocationInRange($0, range) } ?? false }
                guard let first = chosen.first else {
                    continue
                }
                let union = chosen.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                result.append(Underline(
                    range: range,
                    minX: union.minX,
                    maxX: union.maxX,
                    bottom: union.maxY,
                    height: chosen.map(\.rect.height).max() ?? union.height,
                ))
            }
        }
        return result
    }
}
