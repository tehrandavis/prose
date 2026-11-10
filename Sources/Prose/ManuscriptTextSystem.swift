import AppKit
import ProseCore

/// The manuscript's TextKit 2 stack and its reading styles (`SourceStyler`).
/// Never touch `layoutManager`: one access, ours or AppKit's, switches the view
/// to TextKit 1 for good. SwiftLint rejects it in the app.
extension ManuscriptTextView {
    static func make(frame: NSRect) -> ManuscriptTextView {
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        let content = NSTextContentStorage()
        let manager = ManuscriptLayoutManager()
        content.addTextLayoutManager(manager)
        manager.textContainer = container
        let editor = ManuscriptTextView(frame: frame, textContainer: container)
        manager.writing = editor.writing
        editor.styler = SourceStyler(
            contentStorage: content,
            textLayoutManager: manager,
            fontSize: 16,
            textColor: Theme.sourceText,
        )
        editor.styler?.hasMarkedText = { [weak editor] in editor?.hasMarkedText() ?? false }
        editor.styler?.viewport = (
            visible: { [weak editor] in editor?.containerVisibleRect() ?? .zero },
            scroll: { [weak editor] in editor?.scrollContainer(to: $0) },
        )
        NotificationCenter.default.addObserver(
            editor,
            selector: #selector(switchingToTextKit1),
            name: NSTextView.willSwitchToNSLayoutManagerNotification,
            object: editor,
        )
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                editor,
                selector: #selector(windowKeyStateChanged),
                name: name,
                object: nil,
            )
        }
        return editor
    }

    @objc func switchingToTextKit1(_: Notification) {
        switchedToTextKit1 = true
        workspace?.recordOperation("editor.textKit1Fallback", [
            "symbols": Thread.callStackSymbols.prefix(12).joined(separator: " | "),
        ])
    }

    /// Lays out the visible text before AppKit interprets a pointer.
    func prepareForPointerInteraction() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// The character under the pointer, not the nearest insertion position in the margin.
    func sourceOffset(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard let manager = textLayoutManager else {
            return nil
        }
        return TextKit2Geometry.character(
            at: CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y),
            in: manager,
            text: string as NSString,
        )
    }

    /// Source of the lines intersecting the visible rect.
    func visibleCharacterRange() -> NSRange? {
        textLayoutManager.flatMap {
            TextKit2Geometry.characterRange(
                in: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y),
                manager: $0,
            )
        }
    }

    /// Scrolls `range` into view without changing the selection. Every jump
    /// (outline, preview sync, diagnostics, definitions, placeholders) uses it;
    /// see `TextKit2Geometry.reveal` for why not `scrollRangeToVisible`.
    func reveal(_ range: NSRange) {
        guard let manager = textLayoutManager else {
            return
        }
        TextKit2Geometry.reveal(range.location, in: manager, visible: containerVisibleRect, scroll: scrollContainer)
    }

    func containerVisibleRect() -> CGRect {
        visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
    }

    /// Scrolls so that container-y `y` is at the top of the viewport, or as
    /// near as the text allows. TextKit 2 resizes the view lazily, so a target
    /// laid out just now can lie past the frame: grow it to the text's extent,
    /// never beyond. A viewport past the end of the text makes macOS 15 lay out
    /// the whole document trying to fill it (all 41,302 paragraphs of War and
    /// Peace after revealing a caret restored at its end).
    func scrollContainer(to y: CGFloat) {
        guard let scroll = enclosingScrollView else {
            return
        }
        let clip = scroll.contentView
        if let manager = textLayoutManager {
            let text = manager.usageBoundsForTextContainer.maxY + 2 * textContainerInset.height
            if frame.height < text {
                setFrameSize(NSSize(width: frame.width, height: text))
            }
        }
        let top = max(0, min(y + textContainerOrigin.y, frame.height - visibleRect.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    /// Glyph frame of the character at `offset`, in view coordinates.
    func characterRect(at offset: Int) -> NSRect? {
        let text = string as NSString
        guard let manager = textLayoutManager, offset >= 0, offset < text.length else {
            return nil
        }
        return TextKit2Geometry.segments(
            text.rangeOfComposedCharacterSequence(at: offset),
            type: .standard,
            in: manager,
        )
        .first?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// What TextKit draws at `offset`: a rendering attribute (semantic colour),
    /// else the source text's own attribute.
    func drawnAttribute(_ key: NSAttributedString.Key, at offset: Int) -> Any? {
        guard let manager = textLayoutManager, let location = TextKit2Geometry.location(offset, in: manager) else {
            return nil
        }
        var value: Any?
        manager.enumerateRenderingAttributes(from: location, reverse: false) { manager, attributes, range in
            if TextKit2Geometry.offset(of: range.location, in: manager) <= offset {
                value = attributes[key]
            }
            return false
        }
        if value == nil, let storage = textStorage, offset < storage.length {
            value = storage.attribute(key, at: offset, effectiveRange: nil)
        }
        return value
    }

    func drawnColor(at offset: Int) -> NSColor? {
        drawnAttribute(.foregroundColor, at: offset) as? NSColor
    }
}

/// The editor's layout manager. In Writing mode it leaves the paragraphs of
/// rendered blocks and pills out of selection segments, because NSTextView
/// draws its selection highlight from them: `-[NSTextView
/// _updateTextLayoutManagerSelectionLayers]`, run from the view's `layout`,
/// asks `enumerateTextSegments(in:type: .selection, options: .rangeNotRequired)`
/// for the selected range and draws one line view per segment. Inside a
/// rendered block those segments are the source lines' rectangles, and the
/// collapsed lines' lie over the paragraph below the block (Phase 3 spike).
/// Every other segment type passes through, and so does everything while
/// Writing mode is off. An empty range (the caret) passes through too, except
/// in a closed fold, where it lies on the fold's row or beside its mark
/// (`WritingController.foldCaretRect`), since TextKit's lines there are
/// collapsed source. NSTextView's
/// accessibility frames read the same segments; Writing mode answers those
/// for rendered blocks itself (`WritingAccessibility.swift`).
final class ManuscriptLayoutManager: NSTextLayoutManager {
    weak var writing: WritingController?

    override func enumerateTextSegments(
        in textRange: NSTextRange,
        type: NSTextLayoutManager.SegmentType,
        options: NSTextLayoutManager.SegmentOptions = [],
        using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool,
    ) {
        guard Thread.isMainThread, let writing else {
            super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
            return
        }
        if textRange.isEmpty {
            // The caret in a closed fold draws on its row or by its mark.
            let offset = offset(from: documentRange.location, to: textRange.location)
            guard MainActor.assumeIsolated({ writing.closedFold(holding: offset) != nil }) else {
                super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
                return
            }
            var width: CGFloat = 0
            super.enumerateTextSegments(in: textRange, type: type, options: options) { _, frame, _, _ in
                width = frame.width
                return false
            }
            if let container = textContainer,
               let rect = MainActor.assumeIsolated({ writing.foldCaretRect(at: offset, width: width) })
            {
                _ = block(options.contains(.rangeNotRequired) ? nil : textRange, rect, rect.height * 0.8, container)
                return
            }
            super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
            return
        }
        guard type == .selection else {
            super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
            return
        }
        let start = offset(from: documentRange.location, to: textRange.location)
        let range = NSRange(location: start, length: offset(from: textRange.location, to: textRange.endLocation))
        let pieces = MainActor.assumeIsolated { writing.nativeSelectionPieces(of: range) }
        guard pieces != [range] else {
            super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
            return
        }
        var stopped = false
        for piece in pieces {
            guard let begin = location(documentRange.location, offsetBy: piece.location),
                  let end = location(begin, offsetBy: piece.length),
                  let pieceRange = NSTextRange(location: begin, end: end)
            else {
                continue
            }
            super
                .enumerateTextSegments(
                    in: pieceRange,
                    type: type,
                    options: options,
                ) { range, frame, baseline, container in
                    stopped = !block(range, frame, baseline, container)
                    return !stopped
                }
            if stopped {
                return
            }
        }
    }
}

extension Theme {
    static func color(for token: HighlightToken) -> NSColor {
        let kind = token.kind.replacingOccurrences(of: "hljs-", with: "").components(separatedBy: " ").first ?? token
            .kind
        return switch kind {
        case "comment", "punct", "delim", "meta": sourceComment
        case "string", "regexp", "escape": sourceString
        case "keyword", "operator", "selector-tag": sourceKeyword
        case "number", "bool", "literal", "symbol", "bullet": sourceNumber
        case "function", "title", "built_in", "type", "namespace", "link", "ref", "label": sourceFunction
        case "heading", "strong": sourceStrong
        case "raw", "code": sourceCode
        default: token.modifiers.contains("math") ? sourceNumber : sourceText
        }
    }
}
