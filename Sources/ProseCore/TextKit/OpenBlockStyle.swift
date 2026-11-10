import AppKit
import Foundation

/// How Writing mode's open block lays out (Phase 6 decisions 5 to 8): the
/// block that holds the caret draws in the document's own font and size, so
/// it looks like the paragraph it replaces.
///
/// The text storage never changes. `SourceStyler`, the content storage's
/// delegate, asks `paragraph(_:from:)` for each paragraph of `span` that
/// TextKit builds, and hands TextKit a copy of the storage's paragraph with
/// the same characters and these fonts (mechanism 1 of decision 5).
///
/// Each run keeps its `ProseSourceStyle`: plain text and headings take the
/// block's font (the engine reports a heading block's font as rendered),
/// strong and emphasis take the faces Typst picks for them, and raw text and
/// code (`MarkerRanges.code`: math, call arguments, strings) take the
/// editor's monospace font at `Fonts.code`'s size. Characters a face lacks
/// (CJK, emoji) get fallback fonts, as the storage's own text does.
@MainActor
public final class OpenBlockStyle {
    public struct Fonts {
        public var base: NSFont
        public var strong: NSFont?
        public var emphasis: NSFont?
        public var strongEmphasis: NSFont?
        /// Raw text and code inside the block.
        public var code: NSFont
        public var paragraphStyle: NSParagraphStyle

        public init(
            base: NSFont,
            strong: NSFont?,
            emphasis: NSFont?,
            strongEmphasis: NSFont?,
            code: NSFont,
            paragraphStyle: NSParagraphStyle,
        ) {
            self.base = base
            self.strong = strong
            self.emphasis = emphasis
            self.strongEmphasis = strongEmphasis
            self.code = code
            self.paragraphStyle = paragraphStyle
        }

        /// The font of a run with the style code `code` (`SourceStyler.code(for:)`).
        func font(forStyle code: Int) -> NSFont {
            if code & 32 != 0 {
                return self.code
            }
            switch (code & 8 != 0, code & 16 != 0) {
            case (true, true): return strongEmphasis ?? strong ?? emphasis ?? base
            case (true, false): return strong ?? base
            case (false, true): return emphasis ?? base
            case (false, false): return base
            }
        }

        /// A paragraph style whose lines are `pitch` points apart (the
        /// engine's baseline distance on screen), with no space between
        /// paragraphs, for text in `font`.
        public static func paragraphStyle(pitch: CGFloat, font: NSFont) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            let natural = ceil(font.ascender - font.descender + font.leading)
            if pitch >= natural {
                style.lineSpacing = pitch - natural
            } else {
                style.maximumLineHeight = pitch
            }
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            return style
        }
    }

    /// The block's paragraphs, the last one's terminator included. Moves
    /// with edits (`SourceStyler.textDidChange`).
    public private(set) var span: NSRange
    /// Nil until the document's fonts are loaded: the block keeps the
    /// editor's fonts and only its colours change.
    public let fonts: Fonts?
    private var cached: (text: NSString, ranges: MarkerRanges.Result)?

    public init(span: NSRange, fonts: Fonts?) {
        self.span = span
        self.fonts = fonts
    }

    /// The block's markers and code in `source`'s offsets, for the text the
    /// block holds now. Parsed again only when that text changed.
    public func ranges(in source: NSString) -> MarkerRanges.Result {
        let span = NSIntersectionRange(span, NSRange(location: 0, length: source.length))
        // Compared in place as UTF-16: TextKit asks again for each of the
        // block's paragraphs it builds.
        if let cached, cached.text.length == span.length,
           source.compare(cached.text as String, options: .literal, range: span) == .orderedSame
        {
            return cached.ranges.offset(by: span.location)
        }
        let text = source.substring(with: span)
        let ranges = MarkerRanges.ranges(ofBlock: text)
        cached = (text as NSString, ranges)
        return ranges.offset(by: span.location)
    }

    /// Follows a native replacement of `edit` (old coordinates) that changed
    /// the length by `delta`. Text typed at the block's first character
    /// joins the block.
    func rebase(editing edit: NSRange, delta: Int) {
        span = Self.rebase(span, editing: edit, delta: delta)
    }

    /// `range` after an edit, as `SourceStyling.rebase`, except that an
    /// insertion at its start joins it.
    static func rebase(_ range: NSRange, editing edit: NSRange, delta: Int) -> NSRange {
        if edit.length == 0, edit.location == range.location {
            return NSRange(location: range.location, length: range.length + delta)
        }
        return SourceStyling.rebase(range, editing: edit, delta: delta)
    }

    /// The storage's paragraph at `range` with the open block's fonts over
    /// the part of it that lies in `span`; nil when it shares nothing with
    /// the block or the fonts are not loaded.
    func paragraph(_ range: NSRange, from storage: NSTextStorage) -> NSAttributedString? {
        guard let fonts, NSMaxRange(range) <= storage.length else {
            return nil
        }
        let inside = NSIntersectionRange(range, span)
        guard inside.length > 0 || (range.length == 0 && NSLocationInRange(range.location, span)) else {
            return nil
        }
        let copy = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let local = NSRange(location: inside.location - range.location, length: inside.length)
        copy.enumerateAttribute(SourceStyler.styleKey, in: local) { value, run, _ in
            copy.addAttribute(.font, value: fonts.font(forStyle: value as? Int ?? 0), range: run)
        }
        for code in ranges(in: storage.string as NSString).code {
            let piece = NSIntersectionRange(code, inside)
            if piece.length > 0 {
                copy.addAttribute(
                    .font,
                    value: fonts.code,
                    range: NSRange(location: piece.location - range.location, length: piece.length),
                )
            }
        }
        if local.length > 0 {
            copy.addAttribute(.paragraphStyle, value: fonts.paragraphStyle, range: local)
            // The document's faces have no CJK or emoji; substitute as
            // NSTextStorage does for the storage's own text.
            copy.fixFontAttribute(in: local)
        }
        return copy
    }
}
