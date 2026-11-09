import CoreGraphics
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

// MARK: - Dimmed images (step D)

/// An sRGB image with opaque, translucent and clear pixels of several colours.
private func patternImage(width: Int = 24, height: Int = 10) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ))
    for x in 0 ..< width {
        for y in 0 ..< height where !(x * 7 + y * 3).isMultiple(of: 4) {
            context.setFillColor(CGColor(
                srgbRed: Double(x % 3) / 2, green: Double(y % 5) / 4, blue: 0.3, alpha: Double((x + y) % 4 + 1) / 4,
            ))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return try #require(context.makeImage())
}

/// `image` drawn over white, optionally with a global alpha, as RGBA bytes.
private func overWhite(_ image: CGImage, alpha: CGFloat = 1) throws -> [UInt8] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setAlpha(alpha)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    let count = image.width * image.height * 4
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
}

@Test func writingFocusDimmedImageDrawsAsTheImageAtTheDimmedAlpha() throws {
    let image = try patternImage()
    let dimmed = try #require(WritingFocus.dimmed(image))
    #expect(dimmed.width == image.width && dimmed.height == image.height)
    let expected = try overWhite(image, alpha: WritingFocus.dimmedAlpha)
    let actual = try overWhite(dimmed)
    let difference = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(difference <= 1, "Dimmed copy differs from the alpha blend by \(difference)")
    #expect(try overWhite(image) != actual, "The copy is not dimmed")
    // A grey image has no RGB copy.
    let gray = try #require(CGContext(
        data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue,
    )?.makeImage())
    #expect(WritingFocus.dimmed(gray) == nil)
}

@Test func dimmedImageCacheKeepsTheMostRecentlyUsedCopies() throws {
    let cache = DimmedImageCache(limit: 2)
    let first = try patternImage(), second = try patternImage(width: 12), third = try patternImage(width: 8)
    let copy = try #require(cache.dimmed(first))
    #expect(cache.dimmed(first) === copy && cache.count == 1)
    _ = cache.dimmed(second)
    // Using the first again makes the second the oldest; the third evicts it.
    #expect(cache.dimmed(first) === copy)
    _ = cache.dimmed(third)
    #expect(cache.count == 2)
    #expect(cache.dimmed(first) === copy, "The most recently used copy was evicted")
    let secondAgain = try #require(cache.dimmed(second))
    #expect(secondAgain.width == 12 && cache.count == 2)
    cache.removeAll()
    #expect(cache.count < 1, "removeAll kept copies")
    #expect(cache.dimmed(first) !== copy, "A copy outlived removeAll")
    #expect(DimmedImageCache(limit: 0).limit == 1)
}
