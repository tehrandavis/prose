import CoreGraphics
import Foundation

/// What `WritingLayout` needs from a renderer. `BlockRenderer` conforms; tests
/// can script one.
public protocol WritingRenderer: Sendable {
    func setText(_ text: String, of file: URL) async throws
    func blocks(in file: URL) async throws -> [RenderBlock]
    func render(
        _ range: NSRange,
        in file: URL,
        width: Double,
        options: RenderOptions,
    ) async -> Result<RenderedBlock, BlockRendererError>
    func refresh() async -> RenderRefresh
}

extension BlockRenderer: WritingRenderer {}

/// How long `WritingLayout` waits after the last edit.
public struct WritingTiming: Sendable {
    /// Before the text goes to the engine and the block list is replaced.
    public var settle: Duration
    /// Before a full compile (`refresh`); nil never refreshes after edits.
    public var refreshPause: Duration?

    public init(settle: Duration = .milliseconds(150), refreshPause: Duration? = .milliseconds(1500)) {
        self.settle = settle
        self.refreshPause = refreshPause
    }

    public static let standard = WritingTiming()
}

/// How blocks are drawn: they render at `columnWidth / scale` points and draw
/// at `scale` times.
public struct WritingAppearance: Equatable, Sendable {
    public var columnWidth: Double
    public var scale: Double
    /// Bitmap pixels per engine point: `scale` times the backing scale.
    public var bitmapScale: Double
    /// The default text colour; nil for light appearance.
    public var textColor: RenderColor?

    public init(columnWidth: Double, bitmapScale: Double, scale: Double = 1.3, textColor: RenderColor? = nil) {
        self.columnWidth = columnWidth
        self.scale = scale
        self.bitmapScale = bitmapScale
        self.textColor = textColor
    }

    public var renderWidth: Double {
        columnWidth / scale
    }

    var canRender: Bool {
        renderWidth > 0 && renderWidth.isFinite && bitmapScale > 0
    }
}

/// What a render was made for: the appearance, and an epoch that changes when
/// the context changes (a context line edited, a refresh).
struct WritingRenderKey: Equatable {
    let appearance: WritingAppearance
    let epoch: Int
}

/// A block's render as Writing mode draws it.
public struct WritingRendering: Sendable {
    /// The bitmap of `drawnRect`; nil once evicted far from the viewport. The
    /// geometry stays, so heights do not change.
    public internal(set) var image: CGImage?
    /// In engine points from the block's top-left corner.
    public let drawnRect: CGRect
    /// In engine points from the block's top-left corner.
    public let glyphs: [RenderedGlyph]
    /// Points drawn per engine point.
    public let scale: Double
    /// The block's location when it was rendered; glyph sources are relative to it.
    public let origin: Int
    /// No ink: drawn as a muted pill.
    let blank: Bool
    let serial: Int
    var key: WritingRenderKey
    let fingerprint: Int
    /// What the block shows as plain text (`RenderedBlock.text`).
    public internal(set) var text = ""

    /// `drawnRect`'s size in points.
    public var size: CGSize {
        CGSize(width: drawnRect.width * scale, height: drawnRect.height * scale)
    }

    public var height: Double {
        drawnRect.height * scale
    }

    /// The appearance the block was rendered for: its column width and colour.
    public var appearance: WritingAppearance {
        key.appearance
    }

    /// The UTF-16 offset of a glyph's character now that the block starts at
    /// `location`; nil for generated text.
    public func offset(of glyph: RenderedGlyph, blockAt location: Int) -> Int? {
        glyph.source.map { $0 - origin + location }
    }

    var bytes: Int {
        image.map { $0.bytesPerRow * $0.height } ?? 0
    }

    /// Whether `other` draws the same thing at the same appearance.
    func draws(like other: WritingRendering) -> Bool {
        fingerprint == other.fingerprint && drawnRect == other.drawnRect && glyphs == other.glyphs
            && key.appearance == other.key.appearance && blank == other.blank
    }
}

extension WritingRendering: Equatable {
    public static func == (lhs: WritingRendering, rhs: WritingRendering) -> Bool {
        lhs.serial == rhs.serial && (lhs.image == nil) == (rhs.image == nil)
    }
}

/// The collapsed label of a block that does not render.
public struct WritingPill: Equatable, Sendable {
    /// The first `WritingLayout.pillLength` characters of the block's first line.
    public let text: String
    /// Comment-only blocks and renders with no ink.
    public let muted: Bool
}

/// Why a block lays out as source.
public enum WritingSourceReason: Equatable, Sendable {
    /// It holds the caret.
    case active
    case raw
    /// More than `WritingLayout.longBlockLines` source lines.
    case long
    /// It starts or ends inside a paragraph, or shares one with another block.
    case unaligned
    case failed(String)
    /// No render for its text yet.
    case waiting
}

public enum WritingBlockState: Equatable, Sendable {
    case source(WritingSourceReason)
    case rendered(WritingRendering)
    case pill(WritingPill)

    var isSource: Bool {
        if case .source = self {
            true
        } else {
            false
        }
    }

    var rendering: WritingRendering? {
        if case let .rendered(rendering) = self {
            rendering
        } else {
            nil
        }
    }
}

/// What one TextKit paragraph draws.
public enum WritingRole: Equatable, Sendable {
    case source
    /// The first paragraph of a rendered block: draws `rendering` and takes its
    /// height. `block` is the block's range now.
    case rendered(WritingRendering, block: NSRange)
    /// A later paragraph of a rendered block or pill: no height, draws nothing.
    case collapsed
    /// The first paragraph of a pill.
    case pill(WritingPill)
}

/// One block as the model keeps it.
struct WritingEntry {
    let id: Int
    var range: NSRange
    let kind: RenderBlock.Kind
    /// The paragraphs the block lies in, the last one's terminator included.
    var span: NSRange
    /// Source lines, counted up to one past `WritingLayout.longBlockLines`.
    var lines: Int
    var aligned: Bool
    var rendering: WritingRendering?
    var failure: (message: String, key: WritingRenderKey)?
    var label: String?
    /// What the delegate sees; changes only when no text is marked.
    var shown: WritingBlockState = .source(.waiting)
}

extension NSString {
    /// Whether every UTF-16 unit of `range` is white space or a line break.
    func isBlank(_ range: NSRange) -> Bool {
        guard range.length > 0 else {
            return true
        }
        for index in range.location ..< NSMaxRange(range) {
            guard let scalar = Unicode.Scalar(character(at: index)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar)
            else {
                return false
            }
        }
        return true
    }

    /// The paragraphs `range` covers, counted up to `limit + 1`.
    func paragraphCount(in range: NSRange, limit: Int) -> Int {
        var count = 1
        var index = range.location
        let end = NSMaxRange(range)
        while index < end, count <= limit {
            let unit = character(at: index)
            if unit == 0x0A || unit == 0x2029 {
                count += 1
            } else if unit == 0x0D {
                count += 1
                if index + 1 < end, character(at: index + 1) == 0x0A {
                    index += 1
                }
            }
            index += 1
        }
        return count
    }

    /// `range`'s paragraphs and whether the text around the block on its first
    /// and last line is only white space.
    func blockSpan(_ range: NSRange) -> (span: NSRange, aligned: Bool) {
        let span = paragraphRange(for: range)
        let leading = NSRange(location: span.location, length: range.location - span.location)
        let trailing = NSRange(location: NSMaxRange(range), length: NSMaxRange(span) - NSMaxRange(range))
        return (span, range.length > 0 && isBlank(leading) && isBlank(trailing))
    }

    /// The end of `span`'s content, before its terminator.
    func contentEnd(of span: NSRange) -> Int {
        let end = NSMaxRange(span)
        guard end > span.location else {
            return end
        }
        switch character(at: end - 1) {
        case 0x0A:
            return end - span.location >= 2 && character(at: end - 2) == 0x0D ? end - 2 : end - 1
        case 0x0D, 0x2029:
            return end - 1
        default:
            return end
        }
    }

    /// The first line of `range`, at most `length` characters.
    func firstLine(of range: NSRange, length: Int) -> String {
        let head = substring(with: NSRange(location: range.location, length: min(range.length, length * 4)))
        let line = head.prefix { !$0.isNewline }
        return String(line.prefix(length))
    }
}
