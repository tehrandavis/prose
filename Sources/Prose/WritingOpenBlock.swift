import AppKit
import ProseCore

/// The document fonts of an open block: one engine's font at one scale.
struct OpenBlockFontKey: Equatable {
    let engine: UUID
    let font: BlockTextFont
    let scale: Double
}

/// What the open block changes to: its style (nil closes it), the fonts it
/// was made with (nil while they load), and the paragraphs TextKit must
/// build again.
struct OpenBlockPlan {
    let style: OpenBlockStyle?
    let fontKey: OpenBlockFontKey?
    let rebuild: [NSRange]
}

/// Writing mode's open block (Phase 6 decisions 5 to 8): the block that
/// holds the caret draws in the document's font and size, with faint
/// markers. The fonts come from the content storage delegate
/// (`SourceStyler.openBlock`, mechanism 1), the colours from rendering
/// attributes (`RenderingAttributes.setOverlay`). The text storage never
/// changes. A caret move between blocks rebuilds and recolours only the
/// block that closes and the one that opens; `flush()` does both in the
/// same pass as the swap, so the anchor logic keeps the caret's line.
extension WritingController {
    /// The open block the model asks for now, compared with the one shown:
    /// nil when nothing changes, or while text is marked (it waits for the
    /// composition to end, as swaps do).
    func openBlockPlan() -> OpenBlockPlan? {
        guard let editor, let styler = editor.styler, !editor.hasMarkedText() else {
            return nil
        }
        let shown = styler.openBlock
        guard let desired = model?.openBlock, let model, model.isRunning else {
            guard let shown else {
                return nil
            }
            return OpenBlockPlan(style: nil, fontKey: nil, rebuild: shown.fonts == nil ? [] : [shown.span])
        }
        let key = renderer.flatMap { renderer in
            model.textFont(at: desired.range.location).map {
                OpenBlockFontKey(engine: renderer.engineID, font: $0, scale: scale)
            }
        }
        // The common case, a caret move inside the open block: nothing to make.
        if let shown, shown.span == desired.span, shown.fonts != nil, key != nil, key == openFontKey {
            return nil
        }
        let fonts = key.flatMap(openBlockFonts)
        let fontKey = fonts == nil ? nil : key
        if let shown, shown.span == desired.span, fontKey == openFontKey, (shown.fonts == nil) == (fonts == nil) {
            return nil
        }
        var rebuild: [NSRange] = []
        if let shown, shown.fonts != nil {
            rebuild.append(shown.span)
        }
        if fonts != nil {
            rebuild.append(desired.span)
        }
        return OpenBlockPlan(
            style: OpenBlockStyle(span: desired.span, fonts: fonts),
            fontKey: fontKey,
            rebuild: rebuild,
        )
    }

    /// Shows `plan`: the delegate's new block, TextKit's paragraphs of the
    /// old and new spans built again on the next layout pass, and the
    /// colours. The caller lays the paragraphs out.
    func applyOpenBlock(_ plan: OpenBlockPlan) {
        guard let styler = editor?.styler else {
            return
        }
        let start = ContinuousClock.now
        styler.openBlock = plan.style
        openFontKey = plan.fontKey
        for range in plan.rebuild.sorted(by: { $0.location < $1.location }) {
            styler.rebuildParagraphs(in: range)
        }
        recolourOpenBlock()
        openBlockChanges += 1
        openBlockCost += ContinuousClock.now - start
    }

    /// Draws the open block's colours for the text it holds now: the text
    /// colour over its words, the faint colour over its markers, semantic
    /// colours over its code. Writes only where the colours differ, inside
    /// the block's span and the span of the block that closed.
    func recolourOpenBlock() {
        guard let editor, let styler = editor.styler, !editor.hasMarkedText() else {
            return
        }
        guard !mustDeferOpenBlock else {
            openBlockWaits = true
            return
        }
        let text = editor.string as NSString
        let overlay = styler.openBlock.flatMap { block -> RenderingAttributes.Overlay? in
            let span = NSIntersectionRange(block.span, NSRange(location: 0, length: text.length))
            guard span.length > 0 else {
                return nil
            }
            let ranges = block.ranges(in: text)
            return RenderingAttributes.Overlay(
                range: span,
                markers: ranges.markers,
                code: ranges.code,
                text: Theme.sourceText,
                faint: Theme.faintText,
            )
        }
        styler.colors.setOverlay(overlay)
        styler.colors.commit()
    }

    /// Lays out the open block again if the model's caret, blocks, fonts or
    /// scale call for it: after a selection change, when fonts finish
    /// loading, after an edit.
    func refreshOpenBlock() {
        guard editor != nil else {
            return
        }
        if mustDeferOpenBlock {
            openBlockWaits = true
        } else if openBlockPlan() != nil {
            flush()
        } else {
            recolourOpenBlock()
        }
    }

    /// Whether the text system is processing an edit now: the text
    /// storage's edit, an editing transaction, or the content storage's
    /// processing of a character edit that the text storage's delegate saw
    /// (an undo moves the selection from there). The open block's paragraphs
    /// are not rebuilt and its colours not written then.
    var mustDeferOpenBlock: Bool {
        guard let editor else {
            return false
        }
        return storageEditInProgress || editing || editor.textStorage?.editedMask.isEmpty == false
            || editor.textLayoutManager?.textContentManager?.hasEditingTransaction == true
    }

    /// The text storage's delegate saw a character edit; the content storage
    /// processes it next. Ends with the edit (`editDidEnd`, an undo's
    /// completion) or, at the latest, on the run loop's next pass.
    func storageDidProcessCharacterEdit() {
        storageEditInProgress = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.storageEditDidEnd()
            }
        }
    }

    /// The edit is processed: the open block catches up if it waited.
    func storageEditDidEnd() {
        storageEditInProgress = false
        guard openBlockWaits, !mustDeferOpenBlock else {
            return
        }
        openBlockWaits = false
        refreshOpenBlock()
    }

    /// Writing mode's on-screen scale: 1.3, or 1.4625 in Focus.
    private var scale: Double {
        focused ? WritingMetrics.focusScale : WritingMetrics.scale
    }

    /// The fonts for `key`, or nil while they load (the load starts here).
    /// Sizes are the engine's times the scale. Code and raw text take the
    /// editor's monospace font at 0.9 times the size, which puts its
    /// x-height near a book face's. Lines are the engine's baseline distance
    /// apart, or 1.4 times the size for a block of one line.
    private func openBlockFonts(_ key: OpenBlockFontKey) -> OpenBlockStyle.Fonts? {
        guard let renderer, let fonts = editor?.workspace?.documentFonts else {
            return nil
        }
        let id = key.font.id
        guard loadedFonts.contains(id) else {
            loadDocumentFonts(id)
            return nil
        }
        let size = CGFloat(key.font.size * key.scale)
        guard let base = fonts.font(id, size: size, in: renderer) else {
            return nil
        }
        let pitch = key.font.linePitch.map { CGFloat($0 * key.scale) } ?? size * 1.4
        return OpenBlockStyle.Fonts(
            base: base,
            strong: fonts.font(id, size: size, in: renderer, strong: true),
            emphasis: fonts.font(id, size: size, in: renderer, emphasis: true),
            strongEmphasis: fonts.font(id, size: size, in: renderer, strong: true, emphasis: true),
            code: .monospacedSystemFont(ofSize: (size * 0.9).rounded(), weight: .regular),
            paragraphStyle: OpenBlockStyle.Fonts.paragraphStyle(pitch: pitch, font: base),
        )
    }

    /// Makes the four faces of font `id` off the main thread's critical
    /// path; the open block lays out again once they are ready.
    func loadDocumentFonts(_ id: Int) {
        guard let renderer, let fonts = editor?.workspace?.documentFonts, !loadedFonts.contains(id),
              fontLoads[id] == nil
        else {
            return
        }
        fontLoads[id] = Task { [weak self] in
            await fonts.load(id, in: renderer)
            await fonts.load(id, in: renderer, strong: true)
            await fonts.load(id, in: renderer, emphasis: true)
            await fonts.load(id, in: renderer, strong: true, emphasis: true)
            guard let self, self.renderer === renderer, !Task.isCancelled else {
                return
            }
            fontLoads[id] = nil
            loadedFonts.insert(id)
            refreshOpenBlock()
        }
    }

    /// Starts loading the fonts of the blocks at the top, middle and bottom
    /// of the viewport, so the first block opened there has them.
    func preloadDocumentFonts() {
        guard let model, model.isRunning, let visible = visibleRange else {
            return
        }
        for offset in [visible.location, visible.location + visible.length / 2, NSMaxRange(visible)] {
            if let font = model.textFont(at: offset) {
                loadDocumentFonts(font.id)
            }
        }
    }

    /// Lets go of the fonts of the engine Writing mode used.
    func forgetDocumentFonts() {
        for task in fontLoads.values {
            task.cancel()
        }
        fontLoads = [:]
        loadedFonts = []
    }
}
