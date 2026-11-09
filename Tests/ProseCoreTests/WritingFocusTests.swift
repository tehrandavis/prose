import Foundation
@testable import ProseCore
import Testing

/// Focus mode's range arithmetic (decision 4 of the Phase 4 note).
@Test func writingFocusMergesRangesAndFindsOffsets() {
    let ranges = WritingFocus.merged([
        NSRange(location: 20, length: 5),
        NSRange(location: 0, length: 4),
        NSRange(location: 4, length: 2),
        NSRange(location: 22, length: 10),
        NSRange(location: 40, length: 0),
    ])
    #expect(ranges == [NSRange(location: 0, length: 6), NSRange(location: 20, length: 12)])
    #expect(WritingFocus.contains(ranges, 0) && WritingFocus.contains(ranges, 5))
    #expect(!WritingFocus.contains(ranges, 6) && !WritingFocus.contains(ranges, 19))
    #expect(WritingFocus.contains(ranges, 20) && WritingFocus.contains(ranges, 31))
    #expect(!WritingFocus.contains(ranges, 32) && !WritingFocus.contains([], 0))
    #expect(WritingFocus.dimmedAlpha == 0.45)
}

@Test func writingFocusSymmetricDifferenceCoversWhatOneListHas() {
    let first = [NSRange(location: 0, length: 10), NSRange(location: 20, length: 10)]
    let second = [NSRange(location: 5, length: 10), NSRange(location: 20, length: 10)]
    #expect(WritingFocus.symmetricDifference(first, second) == [
        NSRange(location: 0, length: 5),
        NSRange(location: 10, length: 5),
    ])
    #expect(WritingFocus.symmetricDifference(first, first).isEmpty)
    #expect(WritingFocus.symmetricDifference(first, []) == first)
    #expect(WritingFocus.symmetricDifference([], second) == second)
    // Random lists: the difference covers a character exactly when one of
    // the lists covers it.
    var generator = SystemRandomNumberGenerator()
    for _ in 0 ..< 50 {
        func list() -> [NSRange] {
            (0 ..< 4).map { _ in
                NSRange(
                    location: Int.random(in: 0 ..< 60, using: &generator),
                    length: Int.random(in: 0 ..< 15, using: &generator),
                )
            }
        }
        let a = list(), b = list()
        let difference = WritingFocus.symmetricDifference(a, b)
        let (left, right) = (WritingFocus.merged(a), WritingFocus.merged(b))
        for offset in 0 ..< 80 {
            let expected = WritingFocus.contains(left, offset) != WritingFocus.contains(right, offset)
            #expect(WritingFocus.contains(difference, offset) == expected, "\(a) \(b) at \(offset)")
        }
    }
}

@Test func writingFocusFindsTheParagraphsThatStartInARange() {
    let text = "One.\nTwo.\n\nThree.\nFour." as NSString
    let two = text.range(of: "Two.")
    let three = text.range(of: "Three.")
    // A range inside a paragraph holds no paragraph's first character.
    #expect(WritingFocus.paragraphs(startingIn: [NSRange(location: 1, length: 3)], of: text).isEmpty)
    #expect(WritingFocus.paragraphs(startingIn: [NSRange(location: two.location, length: 1)], of: text) == [
        NSRange(location: two.location, length: 5),
    ])
    // Consecutive paragraphs join; the blank line between them is one.
    #expect(WritingFocus.paragraphs(startingIn: [NSRange(location: 2, length: three.location - 1)], of: text) == [
        NSRange(location: two.location, length: NSMaxRange(three) + 1 - two.location),
    ])
    #expect(WritingFocus.paragraphs(startingIn: [NSRange(location: 0, length: 200)], of: text) == [
        NSRange(location: 0, length: text.length),
    ])
    #expect(WritingFocus.paragraphs(startingIn: [], of: text).isEmpty)
}
