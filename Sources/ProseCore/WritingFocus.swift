import Foundation

/// Range arithmetic for Focus mode's dimming (decision 4 of the Phase 4
/// note). The focus blocks are kept as sorted, merged UTF-16 ranges of
/// paragraphs; a paragraph is drawn at full contrast when its first
/// character lies in one of them. When they change, only the paragraphs
/// whose first character changed sides need to draw again.
public enum WritingFocus {
    /// The opacity a paragraph outside the focus blocks is drawn with.
    public static let dimmedAlpha: CGFloat = 0.45

    /// `ranges` sorted, with overlapping and touching ranges joined and
    /// empty ones dropped.
    public static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Whether `offset` lies in one of the merged `ranges`.
    public static func contains(_ ranges: [NSRange], _ offset: Int) -> Bool {
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].location <= offset
    }

    /// The characters covered by exactly one of two merged lists. Each list's
    /// coverage changes at its range ends, so their difference changes where
    /// an odd number of ends meet.
    public static func symmetricDifference(_ first: [NSRange], _ second: [NSRange]) -> [NSRange] {
        var ends: [Int: Int] = [:]
        for range in merged(first) + merged(second) {
            ends[range.location, default: 0] += 1
            ends[NSMaxRange(range), default: 0] += 1
        }
        let points = ends.filter { !$0.value.isMultiple(of: 2) }.keys.sorted()
        return stride(from: 0, to: points.count - 1, by: 2).map {
            NSRange(location: points[$0], length: points[$0 + 1] - points[$0])
        }
    }

    /// The paragraphs of `text` whose first character lies in one of
    /// `ranges`, merged.
    public static func paragraphs(startingIn ranges: [NSRange], of text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        for range in merged(ranges) {
            let end = min(NSMaxRange(range), text.length)
            var start = min(range.location, text.length)
            let first = text.paragraphRange(for: NSRange(location: start, length: 0))
            if first.location != start {
                start = NSMaxRange(first)
            }
            while start < end {
                let paragraph = text.paragraphRange(for: NSRange(location: start, length: 0))
                result.append(paragraph)
                guard NSMaxRange(paragraph) > start else {
                    break
                }
                start = NSMaxRange(paragraph)
            }
        }
        return merged(result)
    }
}
