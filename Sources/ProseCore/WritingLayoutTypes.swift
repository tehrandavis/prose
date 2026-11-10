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
    /// Dark appearance: the engine maps the document's colours onto the dark
    /// page.
    public var dark: Bool

    public init(columnWidth: Double, bitmapScale: Double, scale: Double = 1.3, dark: Bool = false) {
        self.columnWidth = columnWidth
        self.scale = scale
        self.bitmapScale = bitmapScale
        self.dark = dark
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
    /// The font of the block's own text (`RenderedBlock.textFont`), in engine
    /// points: multiply the size and pitch by `scale` to draw.
    public internal(set) var textFont: BlockTextFont?

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

/// The collapsed label of a block that does not render, or of a closed fold.
public struct WritingPill: Hashable, Sendable {
    /// What a closed fold with no `context` block stands for.
    public enum Mark: Hashable, Sendable {
        /// Every block of the fold is a comment.
        case comment
        /// Some block of the fold is a call with no ink, such as `#v(7mm)`.
        case code
    }

    public enum Style: Hashable, Sendable {
        /// One block drawn as a pill: an `include` block once folds are on,
        /// and every block that does not render while they are off.
        case plain
        /// A closed fold with one or more `context` blocks. `lines` counts
        /// its source lines that are not blank; `document` is true when no
        /// block of a rendering kind comes before it in the file.
        case setup(lines: Int, document: Bool)
        /// A closed fold with no `context` block: a mark in the margin.
        case mark(Mark)
    }

    /// For a plain pill or a mark, the first `WritingLayout.pillLength`
    /// characters of the first block's first line; for a setup row, its label
    /// ("Document setup · 16 lines").
    public let text: String
    /// Comment-only blocks and renders with no ink. Setup rows and marks are
    /// always muted.
    public let muted: Bool
    public let style: Style

    public init(text: String, muted: Bool, style: Style = .plain) {
        self.text = text
        self.muted = muted
        self.style = style
    }

    /// A setup row of `lines` source lines that are not blank.
    static func setup(lines: Int, document: Bool) -> WritingPill {
        let name = document ? "Document setup" : "Setup"
        let count = lines == 1 ? "1 line" : "\(lines) lines"
        return WritingPill(text: "\(name) · \(count)", muted: true, style: .setup(lines: lines, document: document))
    }
}

/// A run of quiet blocks (`context` and `comment` blocks and blocks whose
/// render has no ink) with nothing but blank text between them, as
/// `WritingLayout` draws it now. Values describe one moment; ask again after
/// `onChange`.
public struct WritingFold: Hashable, Sendable {
    /// From the first block's first paragraph to the last block's last
    /// paragraph, its terminator included. A mark's span also takes the
    /// blank paragraphs after it, up to the next block.
    public let span: NSRange
    /// Open folds draw every paragraph as source.
    public let isOpen: Bool
    /// What a closed fold draws on its first paragraph: style `setup` or `mark`.
    public let pill: WritingPill
    /// A closed setup row that Focus mode hides: every paragraph collapsed.
    public let isHidden: Bool

    /// The fold's first character, where the caret rests without opening it.
    public var restingPosition: Int {
        span.location
    }

    /// The first offset after the fold.
    public var end: Int {
        NSMaxRange(span)
    }
}

/// The block that holds the caret, when it draws in the document's font
/// (`WritingLayout.openBlock`).
public struct WritingOpenBlock: Equatable, Sendable {
    /// The block's source.
    public let range: NSRange
    /// Its paragraphs, the last one's terminator included.
    public let span: NSRange
    public let kind: RenderBlock.Kind
}

/// Why a block lays out as source.
public enum WritingSourceReason: Equatable, Sendable {
    /// It holds the caret.
    case active
    /// It lies in an open fold (whether or not it holds the caret).
    case fold
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
    /// The text font of the block's last render that reported one. Kept when
    /// an edit drops the render, so the block that holds the caret keeps the
    /// font it was drawn in while its next render is on the way.
    var textFont: BlockTextFont?
    var label: String?
    /// What the delegate sees; changes only when no text is marked.
    var shown: WritingBlockState = .source(.waiting)
    /// The last render had no ink. Kept when an edit drops the render, so the
    /// block stays in its fold until its next render says otherwise.
    var wasBlank = false
}

/// One fold as the model keeps it: entry indices, which stay valid across
/// rebasing and are rebuilt with every new block list.
struct FoldRecord {
    var first: Int
    var last: Int
    /// One or more `context` blocks: a setup row, else a mark.
    var setup: Bool
    /// The blank UTF-16 units after the last block's span that a mark takes.
    var trail: Int
    var pill: WritingPill
    /// Opened by the pointer or by an edit; only `setFold(open: false, ...)`
    /// and closing every fold clear it.
    var pinned = false
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

    /// The lines `range` covers that hold a character other than white space.
    func nonBlankLineCount(in range: NSRange) -> Int {
        var count = 0
        var inked = false
        for index in range.location ..< NSMaxRange(range) {
            let unit = character(at: index)
            if unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x2028 {
                if inked {
                    count += 1
                }
                inked = false
            } else if !inked, unit != 0x20, unit != 0x09,
                      !(Unicode.Scalar(unit).map(CharacterSet.whitespaces.contains) ?? false)
            {
                inked = true
            }
        }
        return count + (inked ? 1 : 0)
    }

    /// The length of the blank paragraphs from `location` on, whole
    /// paragraphs only, ending at or before `limit`.
    func blankParagraphsLength(from location: Int, limit: Int) -> Int {
        var position = location
        while position < limit {
            let paragraph = paragraphRange(for: NSRange(location: position, length: 0))
            guard NSMaxRange(paragraph) <= limit, NSMaxRange(paragraph) > position, isBlank(paragraph) else {
                break
            }
            position = NSMaxRange(paragraph)
        }
        return position - location
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
