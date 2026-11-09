import AppKit
import ProseCore

/// Writing mode in one editor: runs the layout model (`WritingLayout`) for the
/// open file, forwards it the editor's edits, caret, marked text, viewport and
/// appearance, and swaps fragments when roles change. It never writes to the
/// text storage, the selection or the undo stack.
///
/// Swaps: every paragraph has a `WritingFragment`, which reads its role from
/// the model whenever TextKit reads its frame or draws, so a swap is
/// `invalidateLayout(for:)` of the changed ranges, with the top line (or the
/// caret's line, when the caret's own block opens) kept where it was.
@MainActor
final class WritingController: NSObject {
    /// The engine's default text colour in dark appearance (spec Section 4.1).
    static let darkTextColor = RenderColor(red: 0xE8 / 255, green: 0xE4 / 255, blue: 0xDE / 255)
    /// How long entering waits for the viewport's renders before drawing what
    /// it has (decision 4).
    static var entryBudget: Duration = .milliseconds(100)

    private(set) weak var editor: ManuscriptTextView?
    private(set) var model: WritingLayout?
    private(set) var renderer: BlockRenderer?
    private(set) var stale = false
    private(set) var visibleRange: NSRange?
    /// The moving end of the selection, as last sent to the model.
    private(set) var caret: Int?
    /// The selection's fixed end, to tell which end moved.
    var selectionAnchor: Int?
    /// The last selection the pointer made that opened no block (decision 6),
    /// or the keyboard's extension of one.
    private(set) var pointerSelection: NSRange?
    /// The selection a keyboard move is about to make from `pointerSelection`,
    /// and its fixed end; it opens no block either.
    var pointerExtension: (range: NSRange, fixed: Int)?
    /// The x a run of vertical keyboard moves keeps, and the selection the
    /// last one made.
    var verticalGoal: (range: NSRange, x: CGFloat)?
    /// The caret's line in the viewport before the model changed roles.
    private var caretLine: (offset: Int, y: CGFloat)?
    private var entering = false
    private var entryTask: Task<Void, Never>?
    private var held: [NSRange] = []
    private var pending: [NSRange] = []
    private var flushScheduled = false
    private var editing = false
    private var appearanceTask: Task<Void, Never>?

    /// For tests: swaps applied, and whether entry drew the viewport's renders
    /// at once (true) or ran out of time (false).
    private(set) var swapCount = 0
    /// For tests: redraws of the highlight asked for by key state changes.
    var highlightRedraws = 0
    private(set) var enteredWithRenders: Bool?
    /// Focus mode: blocks render at `WritingMetrics.focusScale` for the
    /// editor's Focus column (decision 3 of the Phase 4 note).
    private(set) var focused = false

    init(editor: ManuscriptTextView) {
        self.editor = editor
    }

    var isRunning: Bool {
        model?.isRunning == true
    }

    // MARK: - Lifecycle

    /// Enters Writing mode for `file` with `renderer`, or moves to another
    /// file of the same engine. `reload` means the editor's text was replaced.
    func start(renderer: BlockRenderer, file: URL, reload: Bool) {
        guard let editor, let manager = editor.textLayoutManager else {
            return
        }
        if let model, model.isRunning, self.renderer === renderer {
            guard model.file != file || reload else {
                return
            }
            restart { $0.switchFile(to: file, text: editor.string) }
            beginEntry()
            return
        }
        stop()
        let model: WritingLayout
        if let current = self.model, self.renderer === renderer {
            model = current
        } else {
            model = WritingLayout(renderer: renderer)
            model.hasMarkedText = { [weak editor] in editor?.hasMarkedText() ?? false }
            model.onChange = { [weak self] in self?.changed($0) }
            model.onStaleChange = { [weak self] in self?.staleChanged($0) }
            self.model = model
            self.renderer = renderer
        }
        install(manager)
        if let appearance = currentAppearance() {
            model.setAppearance(appearance)
        }
        model.start(file: file, text: editor.string)
        beginEntry()
    }

    /// Enters or leaves Focus mode. A running model gets the new scale and
    /// column width through the entry path: swaps wait up to `entryBudget`
    /// for the viewport's renders, then blocks without one draw source and
    /// swap in as they arrive, with the top line kept in place.
    func setFocus(_ on: Bool) {
        guard on != focused else {
            return
        }
        focused = on
        guard isRunning else {
            return
        }
        beginEntry(keepingHeld: true)
        sendAppearance()
    }

    /// Holds swaps until the blocks in view have their renders, for at most
    /// `entryBudget`, so the switch does not draw source block by block.
    /// `keepingHeld` keeps swaps an entry still in progress was holding.
    private func beginEntry(keepingHeld: Bool = false) {
        entryTask?.cancel()
        entering = true
        enteredWithRenders = nil
        if !keepingHeld {
            held = []
        }
        viewportDidChange()
        selectionDidChange()
        entryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.entryBudget)
            guard !Task.isCancelled else {
                return
            }
            self?.endEntry(rendered: false)
        }
    }

    /// Leaves Writing mode: every paragraph draws source again.
    func stop() {
        entryTask?.cancel()
        entryTask = nil
        entering = false
        held = []
        appearanceTask?.cancel()
        appearanceTask = nil
        guard let model, model.isRunning else {
            return
        }
        restart { $0.stop() }
        stale = false
        caret = nil
        selectionAnchor = nil
        pointerSelection = nil
        pointerExtension = nil
        verticalGoal = nil
    }

    /// Stops and lets go of the engine.
    func detach() {
        stop()
        model = nil
        renderer = nil
    }

    /// Runs `body`, which resets the model without reporting, and swaps the
    /// paragraphs that were not source back.
    private func restart(_ body: (WritingLayout) -> Void) {
        guard let model else {
            return
        }
        let shown = shownSpans()
        body(model)
        stale = model.stale
        pending += shown
        flush()
    }

    /// The paragraphs of every block that does not draw source.
    private func shownSpans(rendered only: Bool = false) -> [NSRange] {
        guard let model, let editor else {
            return []
        }
        let text = editor.string as NSString
        var spans: [NSRange] = []
        for (index, block) in model.blocks.enumerated() where NSMaxRange(block.range) <= text.length {
            switch model.state(ofBlockAt: index) {
            case .source:
                continue
            case .pill:
                if only {
                    continue
                }
            case .rendered:
                break
            }
            spans.append(text.paragraphRange(for: block.range))
        }
        return spans
    }

    /// Gives every paragraph a `WritingFragment`. TextKit's own fragments never
    /// ask the model, and `invalidateLayout(for:)` keeps fragment objects, so
    /// the first entry replaces them once: an edit action over the whole text
    /// with the same range, which changes nothing in the storage, the
    /// selection or the undo stack (the spike's swap method).
    private func install(_ manager: NSTextLayoutManager) {
        guard manager.delegate !== self, let editor, let content = manager.textContentManager else {
            return
        }
        manager.delegate = self
        let navigation = manager.textSelectionNavigation
        let writingNavigation = WritingSelectionNavigation(dataSource: manager, controller: self)
        writingNavigation.allowsNonContiguousRanges = navigation.allowsNonContiguousRanges
        writingNavigation.rotatesCoordinateSystemForLayoutOrientation = navigation
            .rotatesCoordinateSystemForLayoutOrientation
        manager.textSelectionNavigation = writingNavigation
        let anchor = editor.writingAnchor(changing: [])
        let whole = manager.documentRange
        content.performEditingTransaction {
            content.recordEditAction(in: whole, newTextRange: whole)
        }
        editor.restoreWritingAnchor(anchor)
    }

    // MARK: - Input from the editor

    /// Forwarded from the text storage delegate when characters changed.
    func textDidChange(in storage: NSTextStorage, edited: NSRange, delta: Int) {
        guard let model, model.isRunning else {
            return
        }
        editing = true
        model.textDidChange(edited: edited, delta: delta, in: storage.string as NSString)
        editing = false
    }

    /// The edit is over; swaps it caused can be laid out.
    func editDidEnd() {
        if flushScheduled {
            flush()
        }
    }

    /// The selection or the marked text changed. The caret is the selection's
    /// moving end: the end away from the last fixed end (the caret before the
    /// selection grew), or the far end of a selection made at once.
    ///
    /// A selection the pointer made (`byPointer`: a click, shift-click or drag
    /// has ended) opens no block unless it is empty, so the text under the
    /// pointer does not move (decision 6); `anchor` is its fixed end when known.
    /// Later calls for the same selection leave it so, and so does the
    /// keyboard extending it (`keyboardDestination`, `page`).
    func selectionDidChange(byPointer: Bool = false, anchor: Int? = nil) {
        guard let model, model.isRunning, let editor, !editor.loading else {
            return
        }
        let selection = editor.selectedRange()
        let extended = pointerExtension
        pointerExtension = nil
        if !byPointer, selection.length > 0, let extended, extended.range == selection {
            pointerSelection = selection
            selectionAnchor = extended.fixed
            return
        }
        if selection.length > 0, byPointer || selection == pointerSelection {
            if byPointer {
                pointerSelection = selection
                if let anchor, anchor == selection.location || anchor == NSMaxRange(selection) {
                    selectionAnchor = anchor
                }
            }
            return
        }
        pointerSelection = nil
        let caret = movingEnd(of: selection)
        self.caret = caret
        caretLine = line(of: caret)
        model.selectionDidChange(caret: caret)
        caretLine = nil
    }

    /// The end of `selection` a shift-click at `offset` keeps: the end away
    /// from the click, or inside the selection its fixed end.
    func fixedEnd(of selection: NSRange, toward offset: Int) -> Int {
        guard selection.length > 0 else {
            return selection.location
        }
        if offset <= selection.location {
            return NSMaxRange(selection)
        }
        if offset >= NSMaxRange(selection) {
            return selection.location
        }
        return selectionAnchor == NSMaxRange(selection) ? NSMaxRange(selection) : selection.location
    }

    private func movingEnd(of selection: NSRange) -> Int {
        guard selection.length > 0 else {
            selectionAnchor = selection.location
            return selection.location
        }
        if selectionAnchor == NSMaxRange(selection) {
            return selection.location
        }
        selectionAnchor = selection.location
        return NSMaxRange(selection)
    }

    /// The viewport moved or was laid out again.
    func viewportDidChange() {
        guard let model, model.isRunning, let editor, let range = editor.visibleCharacterRange() else {
            return
        }
        visibleRange = range
        model.setVisibleRange(range)
    }

    /// The width, the backing scale or the appearance changed. During a live
    /// resize images keep their width; blocks render again when it ends.
    func appearanceDidChange(coalesced: Bool = false) {
        guard isRunning, let editor, !editor.inLiveResize else {
            return
        }
        appearanceTask?.cancel()
        guard coalesced else {
            sendAppearance()
            return
        }
        // The container takes its new width after the frame change returns.
        appearanceTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            self?.sendAppearance()
        }
    }

    private func sendAppearance() {
        appearanceTask = nil
        if let appearance = currentAppearance() {
            model?.setAppearance(appearance)
        }
    }

    /// Column width = the text container's width, 1.3 times scale (1.4625
    /// in Focus mode), a bitmap with one pixel per screen pixel, and the dark
    /// text colour in dark mode.
    func currentAppearance() -> WritingAppearance? {
        guard let editor, let container = editor.textContainer, container.size.width > 0 else {
            return nil
        }
        let backing = editor.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let dark = editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scale = focused ? WritingMetrics.focusScale : WritingMetrics.scale
        return WritingAppearance(
            columnWidth: container.size.width,
            bitmapScale: min(scale * backing, RenderOptions.maximumBitmapScale),
            scale: scale,
            textColor: dark ? Self.darkTextColor : nil,
        )
    }

    // MARK: - Roles and drawing

    /// The role of the paragraph that starts at `offset`.
    func role(ofParagraphAt offset: Int) -> WritingRole {
        guard let model, model.isRunning else {
            return .source
        }
        return model.role(forParagraph: NSRange(location: offset, length: 0))
    }

    func staleColor() -> CGColor? {
        guard stale else {
            return nil
        }
        return resolved(Theme.nativeAmber)
    }

    func pillColors(muted: Bool) -> WritingPillColors {
        let fill = resolved(Theme.nativeBorder)
        let text = resolved(Theme.nativeSecondary)
        return WritingPillColors(
            fill: fill.copy(alpha: muted ? 0.4 : 0.85) ?? fill,
            text: NSColor(cgColor: text.copy(alpha: muted ? 0.7 : 1) ?? text) ?? .secondaryLabelColor,
        )
    }

    /// A dynamic colour in the editor's appearance.
    func resolved(_ color: NSColor) -> CGColor {
        var value = color.cgColor
        (editor?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            value = color.cgColor
        }
        return value
    }

    /// Where the caret is drawn in the viewport while its block is rendered or
    /// a pill: from the glyph box of its character, or the block's top. Nil
    /// while it lies in source or out of view.
    private func line(of caret: Int) -> (offset: Int, y: CGFloat)? {
        guard let model, let editor, let manager = editor.textLayoutManager else {
            return nil
        }
        let text = editor.string as NSString
        guard caret <= text.length else {
            return nil
        }
        var paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        var role = model.role(forParagraph: paragraph)
        var steps = 0
        while case .collapsed = role, paragraph.location > 0, steps <= WritingLayout.longBlockLines {
            paragraph = text.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            role = model.role(forParagraph: paragraph)
            steps += 1
        }
        let inside: CGFloat
        switch role {
        case .source, .collapsed:
            return nil
        case .pill:
            inside = WritingMetrics.pillSpacing
        case let .rendered(rendering, block):
            let glyph = rendering.glyphs.filter {
                rendering.offset(of: $0, blockAt: block.location).map { $0 <= caret } ?? false
            }.max { ($0.source ?? 0) < ($1.source ?? 0) }
            inside = ((glyph?.rect.minY ?? rendering.drawnRect.minY) - rendering.drawnRect.minY) * rendering.scale
        }
        guard let location = TextKit2Geometry.location(paragraph.location, in: manager),
              let fragment = manager.textLayoutFragment(for: location)
        else {
            return nil
        }
        let y = fragment.layoutFragmentFrame.minY + inside
        let visible = editor.containerVisibleRect()
        guard y >= visible.minY, y <= visible.maxY else {
            return nil
        }
        return (caret, y - visible.minY)
    }

    // MARK: - Swaps

    private func changed(_ ranges: [NSRange]) {
        if entering {
            held += ranges
            if viewportReady() {
                endEntry(rendered: true)
            }
            return
        }
        pending += ranges
        if editing || editor?.textStorage?.editedMask.isEmpty == false {
            scheduleFlush()
        } else {
            flush()
        }
    }

    private func staleChanged(_ stale: Bool) {
        self.stale = stale
        guard !entering else {
            return
        }
        pending += shownSpans(rendered: true)
        flush()
    }

    /// Whether every block in view has what it draws: a render for today's
    /// appearance, a pill or a reason to stay source. (Entering or leaving
    /// Focus mode can change the column twice, once for the mode and once
    /// when the panes are laid out; a render for the first width is not ready.)
    private func viewportReady() -> Bool {
        guard let model, model.lastError == nil else {
            return true
        }
        let blocks = model.blocks
        guard !blocks.isEmpty, let visible = visibleRange else {
            return false
        }
        let appearance = currentAppearance()
        for (index, block) in blocks.enumerated()
            where NSMaxRange(block.range) >= visible.location && block.range.location <= NSMaxRange(visible)
        {
            switch model.state(ofBlockAt: index) {
            case .source(.waiting):
                return false
            case let .rendered(rendering):
                if let appearance, rendering.appearance != appearance {
                    return false
                }
            default:
                continue
            }
        }
        return true
    }

    private func endEntry(rendered: Bool) {
        guard entering else {
            return
        }
        entering = false
        entryTask?.cancel()
        entryTask = nil
        enteredWithRenders = rendered
        pending += held
        held = []
        flush()
    }

    /// Swaps after the storage has finished processing an edit.
    private func scheduleFlush() {
        guard !flushScheduled else {
            return
        }
        flushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                if self?.flushScheduled == true {
                    self?.flush()
                }
            }
        }
    }

    /// Lays out the changed paragraphs again, keeping the top line, or the
    /// caret's line when the caret's block opened, where it was.
    func flush() {
        flushScheduled = false
        guard !pending.isEmpty, let editor, let manager = editor.textLayoutManager else {
            pending = []
            return
        }
        let length = (editor.string as NSString).length
        var ranges: [NSRange] = []
        for range in pending.sorted(by: { $0.location < $1.location }) {
            let start = min(max(range.location, 0), length)
            let range = NSRange(location: start, length: min(max(NSMaxRange(range), start), length) - start)
            if let last = ranges.last, range.location <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        pending = []
        let anchor: WritingAnchor? = if let caretLine,
                                        ranges.contains(where: { NSLocationInRange(caretLine.offset, $0) }),
                                        opened(caretLine.offset)
        {
            WritingAnchor(offset: caretLine.offset, y: caretLine.y, caret: true)
        } else {
            editor.writingAnchor(changing: ranges)
        }
        for range in ranges {
            if let textRange = TextKit2Geometry.textRange(range, in: manager) {
                manager.invalidateLayout(for: textRange)
            }
        }
        editor.restoreWritingAnchor(anchor)
        swapCount += 1
    }

    /// Whether the paragraph of `offset` now lays out as source.
    private func opened(_ offset: Int) -> Bool {
        guard let model, let editor else {
            return false
        }
        let text = editor.string as NSString
        guard offset <= text.length else {
            return false
        }
        return model.role(forParagraph: text.paragraphRange(for: NSRange(location: offset, length: 0))) == .source
    }
}

/// A line to keep in place across a swap: a paragraph's top, or the caret.
struct WritingAnchor {
    let offset: Int
    /// From the top of the viewport.
    let y: CGFloat
    let caret: Bool
}

extension ManuscriptTextView {
    /// The first paragraph at the top of the viewport and its height in it,
    /// read from the laid-out viewport. A paragraph inside a changed range is
    /// replaced by the range's first paragraph, the top of its block. Nil at
    /// the top of the text.
    func writingAnchor(changing ranges: [NSRange]) -> WritingAnchor? {
        let visible = containerVisibleRect()
        guard visible.minY > 0, let manager = textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange
        else {
            return nil
        }
        var top: (offset: Int, y: CGFloat)?
        manager.enumerateTextLayoutFragments(from: viewport.location) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.height > 0, frame.maxY > visible.minY else {
                return fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending
            }
            top = (TextKit2Geometry.offset(of: fragment.rangeInElement.location, in: manager), frame.minY)
            return false
        }
        guard var top else {
            return nil
        }
        if let range = ranges.first(where: { NSLocationInRange(top.offset, $0) }), range.location != top.offset,
           let location = TextKit2Geometry.location(range.location, in: manager),
           let fragment = manager.textLayoutFragment(for: location)
        {
            top = (range.location, fragment.layoutFragmentFrame.minY)
        }
        return WritingAnchor(offset: top.offset, y: top.y - visible.minY, caret: false)
    }

    /// Lays out the viewport after a swap and scrolls `anchor` back to where it was.
    func restoreWritingAnchor(_ anchor: WritingAnchor?) {
        guard let manager = textLayoutManager else {
            return
        }
        defer {
            manager.textViewportLayoutController.layoutViewport()
            needsDisplay = true
        }
        guard let anchor else {
            return
        }
        TextKit2Geometry.layOutContext(around: anchor.offset, in: manager)
        for _ in 0 ..< 3 {
            let y: CGFloat? = if anchor.caret {
                TextKit2Geometry.caretRect(at: anchor.offset, in: manager)?.minY
            } else {
                TextKit2Geometry.location(anchor.offset, in: manager)
                    .flatMap { manager.textLayoutFragment(for: $0)?.layoutFragmentFrame.minY }
            }
            guard let y, abs(y - containerVisibleRect().minY - anchor.y) >= 0.5 else {
                return
            }
            scrollContainer(to: y - anchor.y)
            manager.textViewportLayoutController.layoutViewport()
        }
    }
}
