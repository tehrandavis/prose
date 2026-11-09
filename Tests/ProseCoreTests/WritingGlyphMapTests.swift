import CoreGraphics
import Foundation
@testable import ProseCore
import Testing

/// Two lines of glyphs, scale 1, in a block at 100 rendered when it began at 50.
/// Line one: "a", "b", "c" (sources 50 to 52); line two: "d" (53) and a
/// generated glyph.
private func sampleMap(scale: Double = 1, imageOrigin: CGPoint = .zero) -> WritingGlyphMap {
    let glyphs = [
        RenderedGlyph(rect: CGRect(x: 0, y: 0, width: 5, height: 10), source: 50),
        RenderedGlyph(rect: CGRect(x: 6, y: 0, width: 5, height: 10), source: 51),
        RenderedGlyph(rect: CGRect(x: 12, y: 0, width: 5, height: 10), source: 52),
        RenderedGlyph(rect: CGRect(x: 0, y: 20, width: 5, height: 10), source: 53),
        RenderedGlyph(rect: CGRect(x: 6, y: 20, width: 5, height: 10), source: nil),
        // A reference's target outside the block counts as generated.
        RenderedGlyph(rect: CGRect(x: 30, y: 20, width: 5, height: 10), source: 10),
        RenderedGlyph(rect: .zero, source: 50),
    ]
    let appearance = WritingAppearance(columnWidth: 40 * scale, bitmapScale: 2, scale: scale)
    let rendering = WritingRendering(
        image: nil,
        drawnRect: CGRect(x: 0, y: 0, width: 40, height: 30),
        glyphs: glyphs,
        scale: scale,
        origin: 50,
        blank: false,
        serial: 1,
        key: WritingRenderKey(appearance: appearance, epoch: 0),
        fingerprint: 0,
    )
    return WritingGlyphMap(
        rendering: rendering,
        block: NSRange(location: 100, length: 4),
        imageOrigin: imageOrigin,
        column: 40 * scale,
    )
}

@Test func writingGlyphMapPlacesBoxesWhereTheFragmentDrawsThem() {
    let map = sampleMap()
    #expect(map.boxes.count == 6)
    #expect(map.boxes.map(\.offset) == [100, 101, 102, 103, nil, nil])
    #expect(map.bounds == CGRect(x: 0, y: 0, width: 40, height: 30))
    let scaled = sampleMap(scale: 2, imageOrigin: CGPoint(x: 3, y: 0))
    #expect(scaled.boxes[1].rect == CGRect(x: 15, y: 0, width: 10, height: 20))
    #expect(scaled.bounds == CGRect(x: 0, y: 0, width: 83, height: 60))
}

@Test func writingGlyphMapHitsTheNearestGlyphOnTheLine() {
    let map = sampleMap()
    #expect(map.hit(at: CGPoint(x: 2.5, y: 5)) == .glyph(offset: 100, trailing: false))
    #expect(map.hit(at: CGPoint(x: 4.9, y: 5)) == .glyph(offset: 100, trailing: true))
    // Past the line's end: its last glyph, after the character.
    #expect(map.hit(at: CGPoint(x: 39, y: 5)) == .glyph(offset: 102, trailing: true))
    #expect(map.hit(at: CGPoint(x: -5, y: 25)) == .glyph(offset: 103, trailing: false))
    #expect(map.hit(at: CGPoint(x: 8.5, y: 25)) == .generated)
    // Between the lines: the nearest box within reach.
    #expect(map.hit(at: CGPoint(x: 2, y: 13)) == .glyph(offset: 100, trailing: false))
    #expect(map.hit(at: CGPoint(x: 2, y: 18)) == .glyph(offset: 103, trailing: false))
    #expect(map.hit(at: CGPoint(x: 2, y: 30 + WritingGlyphMap.reach + 5)) == .missed)
}

@Test func writingGlyphMapHighlightsSelectedGlyphsPerLineOrTheWholeBlock() {
    let map = sampleMap()
    #expect(map.selectionRects(for: []).isEmpty)
    #expect(map.selectionRects(for: [NSRange(location: 101, length: 0)]).isEmpty)
    #expect(map.selectionRects(for: [NSRange(location: 101, length: 1)]) == [
        CGRect(x: 6, y: 0, width: 5, height: 10),
    ])
    #expect(map.selectionRects(for: [NSRange(location: 101, length: 3)]) == [
        CGRect(x: 6, y: 0, width: 11, height: 10),
        CGRect(x: 0, y: 20, width: 5, height: 10),
    ])
    #expect(map.selectionRects(for: [NSRange(location: 90, length: 20)]) == [map.bounds])
    #expect(map.selectionRects(for: [NSRange(location: 0, length: 5)]).isEmpty)
    #expect(map.lines().map(\.count) == [3, 3])
}

@Test func writingGlyphMapGivesTheKeyboardItsDrawnLines() {
    let map = sampleMap()
    let lines = map.sourceLines()
    #expect(lines.count == 2)
    #expect(lines.map(\.boxes.count) == [3, 1])
    #expect(lines[0].minY == 0 && lines[0].maxY == 10 && lines[0].midY == 5)
    #expect(lines[0].first == 100 && lines[0].last == 102)
    #expect(lines[1].first == 103 && lines[1].last == 103)
    // A caret before a glyph, after the last glyph of a line, before the block.
    func caret(_ offset: Int, _ lines: [WritingGlyphMap.Line]) -> [CGFloat]? {
        map.caret(at: offset, in: lines).map { [CGFloat($0.line), $0.x] }
    }
    #expect(caret(101, lines) == [0, 6])
    #expect(caret(104, lines) == [1, 5])
    #expect(caret(90, lines) == [0, 0])
    #expect(caret(101, []) == nil)
    // The nearest glyph at an x, before or after its character.
    #expect(map.position(on: lines[0], nearest: 7) == .glyph(offset: 101, trailing: false))
    #expect(map.position(on: lines[0], nearest: 9.5) == .glyph(offset: 101, trailing: true))
    #expect(map.position(on: lines[0], nearest: 30) == .glyph(offset: 102, trailing: true))
    #expect(map.position(on: lines[1], nearest: 30) == .glyph(offset: 103, trailing: true))
    let empty = WritingGlyphMap.Line(minY: 0, maxY: 0, boxes: [])
    #expect(map.position(on: empty, nearest: 3) == .missed)
    #expect(empty.first == 0 && empty.last == 0)
}
