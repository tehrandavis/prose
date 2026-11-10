import AppKit
import ProseCore
import SwiftUI

struct ManuscriptView: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = Theme.nativeEditor
        let editor = ManuscriptTextView.make(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.workspace = workspace
        editor.delegate = context.coordinator
        editor.textStorage?.delegate = context.coordinator
        editor.isRichText = false
        editor.registerForDraggedTypes(ResourcePasteboard.types)
        editor.isEditable = workspace.editorIsEditable
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.backgroundColor = Theme.nativeEditor
        editor.textColor = Theme.nativeText
        editor.insertionPointColor = Theme.nativeAccent
        editor.selectedTextAttributes = [.backgroundColor: Theme.selection, .foregroundColor: Theme.selectedText]
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(L10n.text("Document Editor"))
        scroll.documentView = editor
        editor.toolbarClearance = workspace.showsToolbarMode
        workspace.editor = editor
        editor.observeViewport(scroll.contentView)
        editor.load(workspace.text, selection: workspace.selection)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ManuscriptTextView else {
            return
        }
        workspace.editor = editor
        editor.isEditable = workspace.editorIsEditable
        editor.setAccessibilityLabel(L10n.text("Document Editor"))
        if editor.workspaceRevision != workspace.revision, !editor.hasMarkedText() {
            editor.load(
                workspace.text,
                selection: workspace.selection,
            )
        }
        if editor.appliedFontSize != workspace.fontSize || editor.styler?.isEnabled != workspace.styledSource {
            editor.highlight()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        let workspace: Workspace
        init(_ workspace: Workspace) {
            self.workspace = workspace
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ManuscriptTextView else {
                return
            }
            workspace.edited(editor.string, change: editor.takeCharacterEdit())
            editor.workspaceRevision = workspace.revision
            editor.applySpelling()
            editor.writing.editDidEnd()
            editor.scheduleTypingAssistance()
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int,
        ) {
            guard editedMask.contains(.editedCharacters) else {
                return
            }
            // The content storage processes the edit after this returns.
            workspace.editor?.writing.storageDidProcessCharacterEdit()
            workspace.editor?.recordCharacterEdit(in: textStorage, range: editedRange, delta: delta)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? ManuscriptTextView else {
                return
            }
            workspace.selection = editor.selectedRange()
            editor.selectionChanged()
            editor.scheduleTypingAssistance()
        }
    }
}

@MainActor
final class ManuscriptTextView: NSTextView {
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        ResourcePasteboard.types + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        if !importResources(from: .general) {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if !importResources(from: .general) {
            super.pasteAsPlainText(sender)
        }
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if importResources(from: pasteboard) {
            return true
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    func importResources(from pasteboard: NSPasteboard, at range: NSRange? = nil) -> Bool {
        guard let resource = ResourcePasteboard(pasteboard) else {
            return false
        }
        // Consume file/image payloads even when input is blocked. Falling back
        // to NSTextView would turn the same payload into literal file paths.
        guard isEditable, !hasMarkedText(), let workspace,
              !workspace.applyingCommand, !workspace.documentTransitionInProgress
        else {
            return true
        }
        let range = range ?? selectedRange()
        setSelectedRange(range)
        workspace.insertResources(resource.inputs, kind: resource.kind, replacing: range)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            return isEditable && !hasMarkedText() && workspace?.applyingCommand != true ? .copy : []
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            return draggingEntered(sender)
        }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            return !draggingEntered(sender).isEmpty
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if ResourcePasteboard.containsResources(sender.draggingPasteboard) {
            prepareForPointerInteraction()
            let point = convert(sender.draggingLocation, from: nil)
            let range = NSRange(location: characterIndexForInsertion(at: point), length: 0)
            return importResources(from: sender.draggingPasteboard, at: range)
        }
        return super.performDragOperation(sender)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dynamic colors already live in storage and TextKit's rendering
        // attributes. Repaint only: changing appearance must not reflow or touch
        // source text.
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
        // Writing mode renders again with the dark or light text colour.
        writing.appearanceDidChange()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        writing.appearanceDidChange()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        writing.appearanceDidChange()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // A composition that replaced a selection in a rendered block opened
        // it; lay it out before the input method asks where the text is.
        writing.editDidEnd()
    }

    override func unmarkText() {
        super.unmarkText()
        // Swaps, renders and spelling results that waited for the
        // composition apply now.
        writing.selectionDidChange()
        workspace?.spelling.selectionDidChange(selectedRange())
    }

    weak var workspace: Workspace?
    var assistancePopover: NSPopover?
    lazy var sourceHover = SourceHoverController(editor: self)
    private var sourceTrackingArea: NSTrackingArea?
    /// While a mouse selection is tracked; its selection changes apply once it ends.
    var selectingWithMouse = false
    /// Where a pointer drag that Prose tracks reads its events: the window's
    /// queue when nil. Tests script it, because posted mouse events end a
    /// `swift test` run (Phase 3 spike).
    var pointerEvents: (() -> NSEvent?)?
    /// The last click Prose mapped through a rendered block, for the second
    /// and third clicks of a multi-click, which land after the block opened.
    var lastWritingClick: WritingClick?
    /// Clicks that would have entered AppKit's own tracking while
    /// `pointerEvents` was scripted; that loop would wait for posted events.
    private(set) var unhandledScriptedClicks = 0
    private var placeholders: [NSRange] = []
    private var placeholderIndex = 0
    var typingTask: Task<Void, Never>?
    var typingRequestID = UUID()
    var typingPanel: NSPanel?
    var typingList = CompletionList(items: [], prefix: "")
    var typingSignature: LanguageSignature?
    var typingSource = ""
    var typingSelection = NSRange(location: 0, length: 0)
    private(set) var appliedFontSize: CGFloat = 0
    /// The top line to keep in place until the layout pass after a re-wrap.
    private var resizeAnchor: (offset: Int, y: CGFloat)?
    /// In Focus mode, the caret whose line goes back to the typewriter line
    /// in the layout pass after the visible height changed.
    private var typewriterResize: Int?
    private var appliedSyntaxRevision = -1
    /// Reading styles and syntax colours.
    var styler: SourceStyler?
    private weak var observedUndoManager: UndoManager?
    var workspaceRevision = -1
    private(set) var loading = false
    /// Writing mode's layout model and fragments.
    lazy var writing = WritingController(editor: self)
    /// Ranges whose spelling underline changed during an edit, drawn once
    /// the text storage has finished processing it (`applySpelling`).
    var spellingPending: [NSRange] = []
    var spellingApplyScheduled = false
    /// While NSTextView builds the context menu of a rendered block, which
    /// must not change the selection (`contextMenuSelecting`).
    var holdsSelection = false
    private var characterEditCount = 0
    private var characterEdit: TextReplacement?

    private var viewportTask: Task<Void, Never>?
    private var hoverViewportBounds: NSRect?
    /// Whether AppKit switched this view to TextKit 1. Tests require false.
    var switchedToTextKit1 = false

    func observeViewport(_ clip: NSClipView) {
        hoverViewportBounds = clip.bounds
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportResized),
            name: NSView.frameDidChangeNotification,
            object: clip,
        )
    }

    /// The visible area changed size: Focus mode's typewriter space follows
    /// its height. With the caret's line in view it goes back to the
    /// typewriter line, now and after the layout pass the resize starts;
    /// otherwise the top line stays.
    @objc private func viewportResized(_: Notification) {
        guard focusColumn else {
            return
        }
        guard let caret = writing.typewriterCaretInView() else {
            applyColumnInset()
            return
        }
        updateColumnInset()
        resizeAnchor = nil
        typewriterResize = caret
        writing.visibleHeightChanged(caret: caret)
    }

    @objc private func viewportChanged(_ notification: Notification) {
        if let clip = notification.object as? NSClipView, hoverViewportBounds != clip.bounds {
            if sourceHover.panel != nil {
                workspace?.recordOperation("hover.viewportChanged", [
                    "previous": hoverViewportBounds.map(NSStringFromRect) ?? "none",
                    "current": NSStringFromRect(clip.bounds),
                ])
            }
            hoverViewportBounds = clip.bounds
            sourceHover.dismiss()
        }
        guard viewportTask == nil else {
            return
        }
        // Clip notifications also occur during TextKit layout. Coalesce them and
        // inspect settled geometry outside the layout callback.
        viewportTask = Task { [weak self] in
            await Task.yield()
            guard let self else {
                return
            }
            viewportTask = nil
            updateOutlineForViewport()
            writing.viewportDidChange()
            spellingViewportDidChange()
        }
    }

    func updateOutlineForViewport() {
        guard !loading, let workspace, !workspace.outline.isEmpty, let characters = visibleCharacterRange() else {
            return
        }
        let caret = selectedRange().location
        // Keep the editing section while the caret is visible. Once scrolling
        // carries it off screen, follow the first visible text instead.
        workspace.trackOutline(at: NSLocationInRange(caret, characters) ? caret : characters.location)
    }

    func recordCharacterEdit(in storage: NSTextStorage, range: NSRange, delta: Int) {
        guard !loading else {
            return
        }
        styler?.textDidChange(edited: range, delta: delta)
        writing.textDidChange(in: storage, edited: range, delta: delta)
        spellingTextDidChange(edited: range, delta: delta)
        workspace?.spelling.textDidChange(edited: range, delta: delta, in: storage.string as NSString)
        characterEditCount += 1
        guard characterEditCount == 1, range.length - delta >= 0,
              NSMaxRange(range) <= storage.length
        else {
            characterEdit = nil
            return
        }
        characterEdit = TextReplacement(
            range: NSRange(location: range.location, length: range.length - delta),
            text: (storage.string as NSString).substring(with: range),
        )
    }

    func takeCharacterEdit() -> TextReplacement? {
        defer { characterEditCount = 0
            characterEdit = nil
        }
        return characterEditCount == 1 ? characterEdit : nil
    }

    override func layout() {
        super.layout()
        // The pass after re-wrapping sizes the view from a partial estimate
        // first, and the clip view clamps the scroll to it.
        if let caret = typewriterResize {
            typewriterResize = nil
            resizeAnchor = nil
            writing.visibleHeightChanged(caret: caret)
        } else if let anchor = resizeAnchor {
            resizeAnchor = nil
            keepAtTop(anchor)
            // This pass is over; lay out the viewport where it now is.
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sourceHover.observeWindow()
        observeUndoManager()
        window?.invalidateCursorRects(for: self)
    }

    private func observeUndoManager() {
        let manager = window == nil ? nil : undoManager
        guard observedUndoManager !== manager else {
            return
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.NSUndoManagerDidUndoChange,
            object: nil,
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.NSUndoManagerDidRedoChange,
            object: nil,
        )
        observedUndoManager = manager
        if let undoManager = manager {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoOrRedoCompleted),
                name: NSNotification.Name.NSUndoManagerDidUndoChange,
                object: undoManager,
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(undoOrRedoCompleted),
                name: NSNotification.Name.NSUndoManagerDidRedoChange,
                object: undoManager,
            )
        }
    }

    @objc private func undoOrRedoCompleted(_ notification: Notification) {
        // AppKit can restore the text storage without a delegate textDidChange
        // after grouped programmatic edits. Reconcile only after the whole group.
        placeholders = []
        if let workspace, workspace.text != string {
            workspace.edited(string, change: takeCharacterEdit())
        } else {
            _ = takeCharacterEdit()
        }
        workspaceRevision = workspace?.revision ?? -1
        workspace?.selection = selectedRange()
        if writing.isRunning, let manager = textLayoutManager {
            // Lay out the text around the caret before Writing mode swaps and
            // places the caret's line, as a jump does. Without it, an undo
            // just above the viewport's top fragment can make the viewport's
            // next layout lay out the text from far above (7,700 paragraphs
            // of SICP in Focus, Phase 6 step D).
            TextKit2Geometry.layOutContext(around: selectedRange().location, in: manager)
        }
        // The undo's edits are processed; the open block can follow them.
        writing.storageEditDidEnd()
        selectionChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Re-wrapping discards TextKit 2's layout, and the next pass finds the
        // viewport by laying out every paragraph above it (all 80,000 of a long
        // document; each later edit then walks them). Keep the top line in
        // place by location instead, which also keeps the reader's place.
        let widened = newSize.width != frame.width
        let anchor = widened ? resizeAnchor ?? topLine() : nil
        super.setFrameSize(newSize)
        updateColumnInset()
        if let anchor {
            resizeAnchor = anchor
            keepAtTop(anchor)
        }
        if widened {
            writing.appearanceDidChange(coalesced: true)
        }
    }

    /// Focus mode's column (decision 3 of the Phase 4 note): narrower than
    /// Code and Writing mode's. Changing it re-wraps the source and keeps the
    /// top line in place, as a resize does.
    var focusColumn = false {
        didSet {
            guard focusColumn != oldValue else {
                return
            }
            applyColumnInset()
        }
    }

    /// Applies the margins for the view's width and mode, keeping the top
    /// line in place when they change.
    private func applyColumnInset() {
        let anchor = resizeAnchor ?? topLine()
        guard updateColumnInset(), let anchor else {
            return
        }
        resizeAnchor = anchor
        keepAtTop(anchor)
    }

    /// Writing and Focus mode keep room below the text for the floating
    /// toolbar, so the last line can scroll above it (decision 6 of the
    /// Phase 4 note). Changing it keeps the top line in place.
    var toolbarClearance = false {
        didSet {
            guard toolbarClearance != oldValue else {
                return
            }
            applyColumnInset()
        }
    }

    /// The space above the text: 42 pt, and in Focus mode 60 percent of the
    /// visible height, so the first line can reach the typewriter line
    /// (decision 5 of the Phase 4 note).
    var topInset: CGFloat {
        guard focusColumn else {
            return ManuscriptLayout.verticalInset
        }
        let visible = enclosingScrollView?.contentView.bounds.height ?? visibleRect.height
        return max(ManuscriptLayout.verticalInset, (visible * ManuscriptLayout.focusVerticalFraction).rounded())
    }

    /// The space below the text: the same as above it, and at least
    /// `ManuscriptLayout.toolbarClearance` while the floating toolbar can
    /// show. Neither inset changes the container's width, so no block renders
    /// again.
    var bottomInset: CGFloat {
        toolbarClearance ? max(topInset, ManuscriptLayout.toolbarClearance) : topInset
    }

    /// The container's top, applied with the insets.
    private var appliedTopInset = ManuscriptLayout.verticalInset

    /// NSTextView puts `textContainerInset.height` above and below the
    /// container (its frame is the text's height plus twice the inset). Prose
    /// sets that height to the mean of the two insets and moves the container
    /// up to `topInset`, so the space below is `bottomInset`. TextKit 2's
    /// fragment views, hit testing and Prose's geometry all read this origin.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: appliedTopInset)
    }

    /// Sets the margins around the column for the view's size and mode.
    /// Returns whether they changed.
    @discardableResult
    private func updateColumnInset() -> Bool {
        let top = topInset
        let inset = NSSize(
            width: ManuscriptLayout.horizontalInset(for: frame.width, focus: focusColumn),
            height: (top + bottomInset) / 2,
        )
        guard textContainerInset != inset || appliedTopInset != top else {
            return false
        }
        appliedTopInset = top
        if textContainerInset != inset {
            textContainerInset = inset
        } else {
            invalidateTextContainerOrigin()
        }
        return true
    }

    /// Lays out the text around `anchor` and scrolls its line back to where it
    /// was in the viewport.
    private func keepAtTop(_ anchor: (offset: Int, y: CGFloat)) {
        guard let manager = textLayoutManager else {
            return
        }
        TextKit2Geometry.layOutContext(around: anchor.offset, in: manager)
        if let line = TextKit2Geometry.caretRect(at: anchor.offset, in: manager) {
            scrollContainer(to: line.minY - anchor.y)
        }
    }

    /// The first visible line's offset and its height within the viewport,
    /// from the laid-out viewport; nil before the first layout or at the top.
    private func topLine() -> (offset: Int, y: CGFloat)? {
        let visible = containerVisibleRect()
        let top = CGPoint(x: 0, y: visible.minY)
        guard visible.minY > 0, let manager = textLayoutManager,
              let offset = TextKit2Geometry.viewportInsertionOffset(at: top, in: manager),
              let line = TextKit2Geometry.caretRect(at: offset, in: manager)
        else {
            return nil
        }
        return (offset, line.minY - visible.minY)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEditable {
            addCursorRect(visibleRect, cursor: .iBeam)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let sourceTrackingArea {
            removeTrackingArea(sourceTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        sourceTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Global button state can belong to another window or the test host.
        // AppKit sends drags separately; track only selection in this editor.
        guard !hasMarkedText(), !selectingWithMouse else {
            sourceHover.dismiss()
            return
        }
        prepareForPointerInteraction()
        sourceHover.move(to: sourceOffset(at: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        sourceHover.scheduleDismissal()
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEditable {
            NSCursor.iBeam.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        workspace?.dismissAssistance()
        prepareForPointerInteraction()
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
           !hasMarkedText(), workspace?.canNavigateSource == true,
           let offset = sourceOffset(at: event)
        {
            setSelectedRange(NSRange(location: offset, length: 0))
            window?.makeFirstResponder(self)
            workspace?.goToDefinition()
            return
        }
        // Writing mode: a press on a fold's row or margin icon opens or
        // closes it; a press in a rendered block or a pill maps through the
        // glyph boxes and runs Prose's own tracking loop.
        if writing.handleFoldPress(event, at: containerPoint(of: event)) {
            return
        }
        if trackWritingPointer(event) {
            return
        }
        lastWritingClick = nil
        guard pointerEvents == nil else {
            unhandledScriptedClicks += 1
            return
        }
        selectingWithMouse = true
        defer { selectingWithMouse = false
            selectionChanged(byPointer: true)
        }
        super.mouseDown(with: event)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard !holdsSelection else {
            return
        }
        let old = selectedRanges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        writing.selectionWillDraw(from: old, to: selectedRanges)
    }

    /// Writing mode steps over a closed fold (Phase 6 decision 3); every
    /// other vertical move is NSTextView's.
    override func moveDown(_ sender: Any?) {
        if !writing.stepOverFold(down: true) {
            super.moveDown(sender)
        }
    }

    override func moveUp(_ sender: Any?) {
        if !writing.stepOverFold(down: false) {
            super.moveUp(sender)
        }
    }

    /// Writing mode moves the caret by a page of drawn content. NSTextView's
    /// own page commands moved nothing with TextKit 2 in the test harness.
    override func pageDown(_ sender: Any?) {
        if !writing.page(down: true, extending: false) {
            super.pageDown(sender)
        }
    }

    override func pageUp(_ sender: Any?) {
        if !writing.page(down: false, extending: false) {
            super.pageUp(sender)
        }
    }

    override func pageDownAndModifySelection(_ sender: Any?) {
        if !writing.page(down: true, extending: true) {
            super.pageDownAndModifySelection(sender)
        }
    }

    override func pageUpAndModifySelection(_ sender: Any?) {
        if !writing.page(down: false, extending: true) {
            super.pageUpAndModifySelection(sender)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        writing.keyStateDidChange()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        writing.keyStateDidChange()
        return resigned
    }

    /// A window became or stopped being key: NSTextView changes its selection
    /// colour, and Writing mode's highlight follows it.
    @objc func windowKeyStateChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, let window else {
            return
        }
        var current: NSWindow? = changed
        while let candidate = current, candidate !== window {
            current = candidate.parent
        }
        if current != nil {
            writing.keyStateDidChange()
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Under the fragments: rendered blocks are transparent outside ink,
        // as NSTextView's own selection view lies under its text.
        writing.drawSelection(in: rect)
    }

    func load(_ content: String, selection: NSRange) {
        dismissTypingAssistance()
        // After `loading` is false again: Writing mode lays out the new text.
        defer { workspace?.updateWritingMode(reload: true) }
        loading = true
        defer { loading = false
            _ = takeCharacterEdit()
        }
        workspaceRevision = workspace?.revision ?? 0
        string = content
        placeholders = []
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: min(selection.location, (content as NSString).length), length: 0))
        restyle()
        highlight()
        spellingDidLoad(content)
        spellingChanged([NSRange(location: 0, length: (content as NSString).length)])
        // After the first layout pass. Revealing a distant caret before it
        // makes TextKit 2 lay out every paragraph above it, and each later
        // keystroke then pays for all of them (40 ms in War and Peace).
        let revision = workspaceRevision
        Task { [weak self] in
            guard let self, workspaceRevision == revision else {
                return
            }
            reveal(selectedRange())
            spellingViewportDidChange()
        }
    }

    /// The selection moved: apply styles that waited for a composition. A
    /// mouse drag updates once it ends; `byPointer` marks that update.
    func selectionChanged(byPointer: Bool = false, anchor: Int? = nil) {
        if !selectingWithMouse {
            styler?.selectionDidChange()
            writing.selectionDidChange(byPointer: byPointer, anchor: anchor)
            workspace?.spelling.selectionDidChange(selectedRange())
        }
    }

    /// Styles the whole text from scratch for the workspace's font size and
    /// reading mode, and drops its syntax colours until they are set again.
    private func restyle() {
        guard let styler else {
            return
        }
        let size = workspace?.fontSize ?? 16
        // While loading, the text was replaced and its spelling state with it.
        styler.open(
            fontSize: size,
            textColor: Theme.sourceText,
            isEnabled: workspace?.styledSource ?? true,
            keepsSpelling: !loading,
        )
        typingAttributes = styler.baseAttributes
        appliedFontSize = size
        appliedSyntaxRevision = -1
    }

    /// Brings the styles up to date with the workspace: font size, reading
    /// mode and the latest semantic colours for exactly this text.
    func highlight() {
        guard let styler else {
            return
        }
        if appliedFontSize != workspace?.fontSize ?? 16 || styler.isEnabled != workspace?.styledSource ?? true {
            // Explicit font and reading-mode changes are rare and must take
            // effect immediately.
            restyle()
        }
        if let workspace, let snapshot = workspace.syntaxSnapshot, workspace.syntaxRevision != appliedSyntaxRevision,
           workspace.syntaxDocumentRevision == workspaceRevision, snapshot.source.utf16.count == string.utf16.count
        {
            styler.colors.setColors(snapshot.tokens.map { ($0.range, Theme.color(for: $0)) })
            appliedSyntaxRevision = workspace.syntaxRevision
        }
    }

    func insertSnippet(_ snippet: Snippet, replacing range: NSRange, focus: Bool = true) {
        guard workspace?.canEditSource != false, range.location >= 0, range.location <= string.utf16.count,
              range.length >= 0, range.length <= string.utf16.count - range.location
        else {
            return
        }
        observeUndoManager()
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        // Use the native editing path so undo/redo also delivers textDidChange.
        // Direct NSTextStorage mutation only undid the buffer, leaving the model stale.
        insertText(snippet.text, replacementRange: range)
        observeUndoManager()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(L10n.text("Insert Content"))
        placeholders = snippet.selections.map { NSRange(location: range.location + $0.location, length: $0.length) }
        placeholderIndex = 0
        setSelectedRange(placeholders.first ?? NSRange(location: range.location + snippet.text.utf16.count, length: 0))
        if focus {
            reveal(selectedRange())
        }
        highlight()
        if focus {
            window?.makeFirstResponder(self)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard workspace?.canEditSource != false else {
            return false
        }
        let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if accepted {
            observeUndoManager()
        }
        if accepted, !placeholders.isEmpty {
            let delta = (replacementString ?? "").utf16.count - affectedCharRange.length
            if placeholderIndex < placeholders.count,
               affectedCharRange.location >= placeholders[placeholderIndex].location,
               NSMaxRange(affectedCharRange) <= NSMaxRange(placeholders[placeholderIndex])
            {
                placeholders[placeholderIndex].length += delta
                for index in (placeholderIndex + 1) ..< placeholders.count {
                    placeholders[index].location += delta
                }
            } else {
                placeholders = []
            }
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        workspace?.focusChrome.keyTyped(event)
        let hadHover = sourceHover.panel != nil
        sourceHover.dismiss()
        if hadHover, event.keyCode == 53, !hasMarkedText() {
            return
        }
        if handleTypingKey(event) {
            return
        }
        if event.keyCode == 111, event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
           !hasMarkedText(), workspace?.canNavigateSource == true
        {
            workspace?.goToDefinition()
            return
        }
        if !hasMarkedText(), event.keyCode == 48, !placeholders.isEmpty {
            placeholderIndex += event.modifierFlags.contains(.shift) ? -1 : 1
            if placeholderIndex >= 0, placeholderIndex < placeholders.count {
                setSelectedRange(placeholders[placeholderIndex])
                reveal(selectedRange())
            } else {
                let end = placeholders.last.map(NSMaxRange) ?? selectedRange().location
                placeholders = []
                setSelectedRange(NSRange(location: end, length: 0))
            }
            return
        }
        if !hasMarkedText(), event.keyCode == 53, !placeholders.isEmpty {
            placeholders = []
            setSelectedRange(NSRange(
                location: NSMaxRange(selectedRange()),
                length: 0,
            ))
            return
        }
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "."
        {
            workspace?.requestCompletion()
            return
        }
        super.keyDown(with: event)
    }

    /// `Esc` reaches the editor as `cancelOperation:` after every other owner
    /// (marked text, the command panel, the assistance and checks popups,
    /// hover, completion and placeholders) has passed on it. In Focus mode it
    /// leaves for Writing mode. Otherwise it does what it did before this
    /// override: NSTextView has no `cancelOperation:`, so its
    /// `doCommandBySelector:` sends the command up the responder chain and
    /// beeps when nothing there performs it.
    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText(), let workspace, workspace.editorMode == .focus {
            workspace.setMode(.writing)
            return
        }
        if nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender) != true {
            NSSound.beep()
        }
    }

    func setCompletionPlaceholders(_ selections: [NSRange]) {
        placeholders = selections
        placeholderIndex = 0
    }
}
