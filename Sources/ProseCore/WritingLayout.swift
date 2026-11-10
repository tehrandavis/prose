import CoreGraphics
import Foundation

/// The layout model of Writing mode for one open file: its blocks, which of
/// them draw rendered, as pills or as source, and the renders the viewport
/// needs. It reads the text it is given and never changes the text storage.
///
/// The view forwards edits, the caret, the visible range and the appearance;
/// the layout delegate asks `role(forParagraph:)` for each TextKit paragraph,
/// and `onChange` names the ranges whose roles changed. While text is marked,
/// no state changes and nothing is reported, except that a block whose text
/// the composition itself changes opens at once.
///
/// All engine calls run one at a time in this order of priority: sending the
/// text after edits settle, renders near the viewport (nearest first), and a
/// full compile (`refresh`) once on start and after edits pause.
@MainActor
public final class WritingLayout {
    /// Blocks with more source lines stay source.
    public static let longBlockLines = 400
    /// Characters of a pill's label.
    public static let pillLength = 60

    /// Whether the view is composing text.
    public var hasMarkedText: () -> Bool = { false }
    /// UTF-16 ranges whose paragraphs changed role, sorted and merged.
    public var onChange: (([NSRange]) -> Void)?
    /// The last full compile failed (true) or succeeded again (false).
    public var onStaleChange: ((Bool) -> Void)?

    public private(set) var isRunning = false {
        didSet { changedRoles() }
    }

    public private(set) var file: URL?
    /// The last full compile failed; renders keep the context of the one before.
    public private(set) var stale = false
    /// The engine refused the text or its blocks.
    public private(set) var lastError: String?

    private let renderer: any WritingRenderer
    private let timing: WritingTiming
    private let text = NSMutableString()
    private var entries: [WritingEntry] = [] {
        didSet { changedRoles() }
    }

    /// Changes whenever a paragraph's role may have changed: every change of
    /// the blocks, every edit, and starting and stopping. Unique across
    /// models, so a fragment can keep the role it read with the revision it
    /// read it at (`role(forParagraph:)` grows costly with the paragraphs
    /// TextKit has built, and TextKit reads each fragment's frame many times
    /// a frame).
    public private(set) var roleRevision = 0
    private static var roleRevisions = 0
    private var indexByID: [Int: Int] = [:]
    private var nextID = 0
    private var nextSerial = 0
    private var caret: Int?
    private var activeID: Int?
    /// The block the caret left; it renders first.
    private var leftID: Int?
    private var visible: NSRange?
    private var appearance: WritingAppearance?
    private var epoch = 0
    private var contextText: String?

    /// Increases with every start, stop and file switch; older replies are dropped.
    private var generation = 0
    /// Increases with every edit.
    private var revision = 0
    /// The revision whose text the engine holds.
    private var engineRevision = -1
    private var failedRevision = -1
    private var working = false
    private var settleTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshDue = false
    /// Files the document reads changed on disk since the last refresh began.
    private var filesChanged = false
    /// The next refresh runs as soon as the engine has the text, before any
    /// render (`refreshNow`).
    private var urgentRefresh = false
    /// Replies that waited for a composition to end.
    private var deferredBlocks: (revision: Int, blocks: [RenderBlock])?
    private var deferredRenders: [(request: RenderRequest, result: Result<RenderedBlock, BlockRendererError>)] = []
    private var restateWaits = false
    private var changed: [NSRange] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Folds runs of quiet blocks (Phase 6 decisions 1 and 3): `context` and
    /// `comment` blocks and blocks whose render has no ink, with nothing but
    /// blank text between them. Off, every role is what it was before folds.
    public var foldsEnabled = false {
        didSet { foldsToggled(from: oldValue) }
    }

    /// Focus mode (Phase 6 decision 4): every paragraph of a closed setup row
    /// is collapsed, except while the caret rests on its first character.
    public var hidesSetupRows = false {
        didSet { setupRowsHidingChanged(from: oldValue) }
    }

    /// Sorted, disjoint, rebuilt where block states are recomputed. Open
    /// state lives here (`pinned`) and in `caretOpen`, never in the entries.
    private var folds: [FoldRecord] = [] {
        didSet { changedRoles() }
    }

    /// The caret as the folds last saw it: frozen while text is marked, as
    /// the entries' states are, and rebased across edits.
    private var foldCaret: Int?
    /// The fold holding `foldCaret` was opened by the caret.
    private var caretOpen = false
    /// The fold holding `foldCaret` was closed by `setFold(open: false, ...)`
    /// with the caret in it; the caret opens it again only after leaving it.
    private var caretHeld = false
    /// The index of the first block of a rendering kind (`entries.count` if none).
    private var firstRendering = 0
    /// What the folds drew and which were pinned, kept by `apply(_:)` for the
    /// next rebuild: entry indices do not survive a new block list, text does.
    private var pendingFolds: (looks: [WritingFold], pins: [NSRange])?

    /// Replies received, for tests.
    public private(set) var syncReplies = 0
    public private(set) var renderReplies = 0
    public private(set) var refreshReplies = 0

    private struct RenderRequest {
        let id: Int
        let range: NSRange
        let text: String
        let key: WritingRenderKey
    }

    private enum Job {
        case sync(text: String, revision: Int)
        case render(RenderRequest)
        case refresh(filesChanged: Bool)
    }

    public init(renderer: any WritingRenderer, timing: WritingTiming = .standard) {
        self.renderer = renderer
        self.timing = timing
    }

    // MARK: - Lifecycle

    /// Writing mode was entered: lays out `text` of `file`, renders near the
    /// viewport and refreshes once.
    public func start(file: URL, text: String) {
        reset(file: file, text: text)
        isRunning = true
        refreshDue = true
        pump()
    }

    /// Writing mode was left: stops all work and frees the images.
    public func stop() {
        guard isRunning else {
            return
        }
        reset(file: nil, text: "")
        isRunning = false
        resumeWaiters()
    }

    /// Another file of the same project was opened. Does nothing while stopped.
    public func switchFile(to file: URL, text: String) {
        guard isRunning else {
            return
        }
        start(file: file, text: text)
    }

    private func reset(file: URL?, text: String) {
        generation += 1
        settleTask?.cancel()
        refreshTask?.cancel()
        settleTask = nil
        refreshTask = nil
        self.file = file
        self.text.setString(text)
        folds = []
        entries = []
        indexByID = [:]
        caret = nil
        foldCaret = nil
        caretOpen = false
        caretHeld = false
        firstRendering = 0
        pendingFolds = nil
        activeID = nil
        leftID = nil
        contextText = nil
        revision = 0
        engineRevision = -1
        failedRevision = -1
        refreshDue = false
        filesChanged = false
        urgentRefresh = false
        deferredBlocks = nil
        deferredRenders = []
        restateWaits = false
        changed = []
        stale = false
        lastError = nil
    }

    // MARK: - Input from the view

    /// Forward from `NSTextStorageDelegate` `didProcessEditing` when characters
    /// changed. `edited` is in the new text, `source`; `delta` is its change in
    /// length.
    public func textDidChange(edited: NSRange, delta: Int, in source: NSString) {
        guard isRunning else {
            return
        }
        let original = NSRange(location: edited.location, length: edited.length - delta)
        guard original.location >= 0, original.length >= 0, NSMaxRange(original) <= text.length,
              NSMaxRange(edited) <= source.length, text.length + delta == source.length
        else {
            resynchronize(source)
            return
        }
        // Measured in the text before the edit.
        let pins = closedFolds(touchedBy: original)
        text.replaceCharacters(in: original, with: source.substring(with: edited))
        revision += 1
        // Paragraph offsets moved, even where no block did.
        changedRoles()
        let (touched, changedText) = rebase(editing: original, delta: delta)
        if let caret {
            let moved = SourceStyling.rebase(NSRange(location: caret, length: 0), editing: original, delta: delta)
            self.caret = moved.location
        }
        if let foldCaret {
            let moved = SourceStyling.rebase(NSRange(location: foldCaret, length: 0), editing: original, delta: delta)
            self.foldCaret = moved.location
        }
        changed = changed.map { SourceStyling.rebase($0, editing: original, delta: delta) }
        restartTimers()
        if hasMarkedText() {
            openComposing(changedText, pins: pins)
        } else {
            restate(touched, refolding: neighbourhood(of: edited), pinning: pins)
            flush()
        }
    }

    /// While text is marked nothing swaps, except that a block whose text the
    /// composition changes draws source at once: its render or label no
    /// longer matches its text, and the marked text is drawn only in source.
    /// That happens when a composition replaces a selection the pointer made,
    /// which opens no block. The block counts as active until the
    /// composition ends. A closed fold the composition changes opens at once
    /// and stays pinned; the folds are not rebuilt until the composition ends.
    private func openComposing(_ indices: [Int], pins: [ClosedRange<Int>]) {
        restateWaits = true
        var opened = false
        for index in pin(pins) {
            show(index)
            opened = true
        }
        for index in indices where !entries[index].shown.isSource {
            entries[index].shown = .source(.active)
            changed.append(entries[index].span)
            opened = true
        }
        if opened {
            report()
        }
    }

    /// The selection changed; `caret` is its moving end. Only the block that
    /// holds it opens. Applies what waited for a composition to end.
    public func selectionDidChange(caret: Int) {
        guard isRunning else {
            return
        }
        self.caret = caret
        guard !hasMarkedText() else {
            restateWaits = true
            return
        }
        if let (revision, blocks) = deferredBlocks {
            deferredBlocks = nil
            if revision == self.revision {
                apply(blocks)
            }
        }
        let renders = deferredRenders
        deferredRenders = []
        for (request, result) in renders {
            apply(result, for: request)
        }
        restate([])
        flush()
        pump()
    }

    /// The UTF-16 range of the text in view. Blocks within one screen of it
    /// render; images beyond three screens are freed.
    public func setVisibleRange(_ range: NSRange) {
        guard range != visible else {
            return
        }
        visible = range
        guard isRunning else {
            return
        }
        evict()
        pump()
    }

    /// A new width, scale or colour re-renders the blocks near the viewport.
    /// A new width or colour keeps the images shown until their new renders
    /// arrive. A new scale (Focus mode, Phase 4 decision 3) does not: a block
    /// whose render has another scale draws source until it renders again.
    public func setAppearance(_ appearance: WritingAppearance) {
        guard appearance != self.appearance else {
            return
        }
        let rescaled = self.appearance.map { $0.scale != appearance.scale } ?? false
        self.appearance = appearance
        guard isRunning else {
            return
        }
        if rescaled {
            restate(Array(entries.indices))
            flush()
        }
        pump()
    }

    private func changedRoles() {
        Self.roleRevisions &+= 1
        roleRevision = Self.roleRevisions
    }

    /// Files the document reads changed on disk, and the engine was told
    /// (`BlockRenderer.filesChanged`). Compiles the whole document again at
    /// once; then every block in view asks for its render again, as after any
    /// refresh, whether or not the compile succeeded, since renders that read a
    /// changed file are out of date. The engine's cache answers for the blocks
    /// whose result cannot have changed.
    public func filesChangedOnDisk() {
        guard isRunning else {
            return
        }
        filesChanged = true
        refreshDue = true
        pump()
    }

    /// An edit whose final text only the full compile gives, such as a
    /// citation the picker inserted (citations note, decision 4): compiles
    /// the document as soon as the engine has the new text, before any
    /// render and without waiting for the pause after edits. The renders that
    /// follow then carry the new citation texts; until then the edited block
    /// draws source, as the caret is in it.
    public func refreshNow() {
        guard isRunning else {
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshDue = true
        urgentRefresh = true
        pump()
    }

    // MARK: - Queries

    /// The role of the TextKit paragraph at UTF-16 `range`.
    public func role(forParagraph range: NSRange) -> WritingRole {
        if let fold = foldIndex(at: range.location) {
            let look = foldLook(fold)
            if look.isOpen {
                return .source
            }
            return range.location == look.span.location && !look.isHidden ? .pill(look.pill) : .collapsed
        }
        guard let index = lastEntry(spanAtMost: range.location) else {
            return .source
        }
        let entry = entries[index]
        guard range.location < NSMaxRange(entry.span) else {
            return .source
        }
        let first = range.location == entry.span.location
        switch entry.shown {
        case .source:
            return .source
        case let .rendered(rendering):
            return first ? .rendered(rendering, block: entry.range) : .collapsed
        case let .pill(pill):
            return first ? .pill(pill) : .collapsed
        }
    }

    /// The paragraphs of each block that does not draw source (rendered blocks
    /// and pills) and that shares characters with `range`, in order. NSTextView
    /// draws no selection there; the view draws it from the glyph boxes.
    /// A closed fold counts once, with its whole span (blank paragraphs
    /// included), and an open fold not at all.
    public func drawnSpans(intersecting range: NSRange) -> [NSRange] {
        let blocks = entries(intersecting: range)
            .filter { foldIndex(ofEntry: $0) == nil && !entries[$0].shown.isSource }
        let closed = foldIndices(intersecting: range).map(foldLook).filter { !$0.isOpen }
        return ordered(blocks.map { entries[$0].span } + closed.map(\.span))
    }

    /// The paragraphs of every block that shares characters with `range`, in
    /// order, whatever it draws: Focus mode's focus blocks for a selection.
    /// A fold, open or closed, counts once with its whole span, so it dims and
    /// undims as one unit.
    public func spans(intersecting range: NSRange) -> [NSRange] {
        let blocks = entries(intersecting: range).filter { foldIndex(ofEntry: $0) == nil }
        return ordered(blocks.map { entries[$0].span } + foldIndices(intersecting: range).map(foldSpan))
    }

    private func ordered(_ spans: [NSRange]) -> [NSRange] {
        folds.isEmpty ? spans : spans.sorted { $0.location < $1.location }
    }

    /// The fold that holds `offset`: from its first character through the end
    /// of its last line's content (the line break after it belongs to the
    /// next paragraph's side, as for blocks). Nil when folds are off or no
    /// fold holds it. Usable for any offset, for example where a vertical
    /// caret move would land.
    public func fold(holding offset: Int) -> WritingFold? {
        foldIndex(holding: offset).map(foldLook)
    }

    /// The folds whose spans share characters with `range`, in order: the
    /// margin marks in view, for example.
    public func folds(intersecting range: NSRange) -> [WritingFold] {
        foldIndices(intersecting: range).map(foldLook)
    }

    /// Opens or closes the fold holding `offset`, for the pointer. Opening
    /// pins it: it stays open until this call closes it. Closing unpins it
    /// and closes it even with the caret inside; the caret then opens it
    /// again only after it leaves the fold and comes back. Returns false,
    /// changing nothing, when no fold holds `offset`, folds are off or text
    /// is marked.
    @discardableResult
    public func setFold(open: Bool, at offset: Int) -> Bool {
        guard isRunning, foldsEnabled, !hasMarkedText() else {
            return false
        }
        if restateWaits {
            restate([])
        }
        guard let fold = foldIndex(holding: offset) else {
            return false
        }
        let before = foldLook(fold)
        folds[fold].pinned = open
        if !open, let foldCaret, holds(before.span, foldCaret) {
            caretOpen = false
            caretHeld = true
        }
        lookChanged(fold, from: before).forEach(show)
        flush()
        return true
    }

    /// Opens a closed fold or closes an open one, as `setFold(open:at:)`.
    @discardableResult
    public func toggleFold(at offset: Int) -> Bool {
        guard let fold = fold(holding: offset) else {
            return false
        }
        return setFold(open: !fold.isOpen, at: offset)
    }

    /// The paragraphs of block `index`.
    public func span(ofBlockAt index: Int) -> NSRange {
        entries[index].span
    }

    private func entries(intersecting range: NSRange) -> [Int] {
        var indices: [Int] = []
        var index = firstEntry(spanEndAtLeast: range.location)
        let end = NSMaxRange(range)
        while index < entries.count, entries[index].span.location < end {
            if NSIntersectionRange(entries[index].span, range).length > 0 {
                indices.append(index)
            }
            index += 1
        }
        return indices
    }

    /// The range of the block whose paragraphs hold `offset`.
    public func blockRange(holding offset: Int) -> NSRange? {
        entry(holding: offset).map { entries[$0].range }
    }

    /// How many blocks above `textFont(at:)` looks through for a paragraph's font.
    public static let textFontSearchLimit = 64

    /// The document font to draw the block that holds `offset` in, in engine
    /// points: the font of that block's last render that reported one (kept
    /// across edits, so a block being typed in keeps its font), else the font
    /// of the nearest paragraph above it that has one, looking at no more than
    /// `textFontSearchLimit` blocks. An offset between blocks looks above
    /// itself. Nil when none is found: use the editor's font.
    public func textFont(at offset: Int) -> BlockTextFont? {
        let holding = entry(holding: offset)
        if let holding, let font = entries[holding].textFont {
            return font
        }
        // The block that holds the offset, or else the last one above it.
        guard let last = lastEntry(spanAtMost: offset) else {
            return nil
        }
        var index = holding == nil ? last : last - 1
        var looked = 0
        while index >= 0, looked < Self.textFontSearchLimit {
            if entries[index].kind == .paragraph, let font = entries[index].textFont {
                return font
            }
            index -= 1
            looked += 1
        }
        return nil
    }

    /// The blocks in order, with ranges in today's text.
    public var blocks: [RenderBlock] {
        entries.map { RenderBlock(range: $0.range, kind: $0.kind) }
    }

    /// What block `index` draws now.
    public func state(ofBlockAt index: Int) -> WritingBlockState {
        entries[index].shown
    }

    /// The index of the block that holds the caret.
    public var activeBlock: Int? {
        activeID.flatMap { indexByID[$0] }
    }

    /// Bytes of the bitmaps held.
    public var bytesHeld: Int {
        entries.reduce(0) { total, entry in
            let shown = entry.shown.rendering
            let extra = shown.map { $0.serial == entry.rendering?.serial ? 0 : $0.bytes } ?? 0
            return total + (entry.rendering?.bytes ?? 0) + extra
        }
    }

    /// Returns once nothing is waiting: no timer, no engine call, no render
    /// the viewport needs.
    public func idle() async {
        pump()
        guard isRunning, working || settleTask != nil || refreshTask != nil else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The text as the model holds it, for tests.
    var source: String {
        text as String
    }

    // MARK: - Blocks across edits

    /// Moves every block across a native edit and returns the indices whose
    /// paragraphs it touched, and those whose text it changed.
    private func rebase(editing edit: NSRange, delta: Int) -> (touched: [Int], changed: [Int]) {
        let end = NSMaxRange(edit)
        var touched: [Int] = []
        var changedText: [Int] = []
        var index = firstEntry(spanEndAtLeast: edit.location)
        while index < entries.count {
            let old = entries[index]
            if old.span.location > end {
                break
            }
            let range = SourceStyling.rebase(old.range, editing: edit, delta: delta)
            entries[index].range = range
            entries[index].span = SourceStyling.rebase(old.span, editing: edit, delta: delta)
            let overlaps = edit.location < NSMaxRange(old.range) && end > old.range.location
            if overlaps || range.length != old.range.length {
                entries[index].rendering = nil
                entries[index].failure = nil
                entries[index].label = nil
                entries[index].lines = text.paragraphCount(in: range, limit: Self.longBlockLines)
                changedText.append(index)
            }
            touched.append(index)
            index += 1
        }
        while index < entries.count {
            entries[index].range.location += delta
            entries[index].span.location += delta
            index += 1
        }
        for index in touched {
            (entries[index].span, entries[index].aligned) = text.blockSpan(entries[index].range)
        }
        return (touched, changedText)
    }

    /// Replaces the list with the engine's for today's text. Blocks with the
    /// same range and kind keep their renders.
    private func apply(_ blocks: [RenderBlock]) {
        let old = entries
        var fresh: [WritingEntry] = []
        fresh.reserveCapacity(blocks.count)
        var cursor = 0
        func drop(_ entry: WritingEntry) {
            if !entry.shown.isSource {
                changed.append(entry.span)
            }
        }
        for block in blocks {
            while cursor < old.count, old[cursor].range.location < block.range.location {
                drop(old[cursor])
                cursor += 1
            }
            if cursor < old.count, old[cursor].range == block.range, old[cursor].kind == block.kind {
                fresh.append(old[cursor])
                cursor += 1
                continue
            }
            if cursor < old.count, old[cursor].range.location == block.range.location {
                drop(old[cursor])
                cursor += 1
            }
            let (span, aligned) = text.blockSpan(block.range)
            nextID += 1
            fresh.append(WritingEntry(
                id: nextID,
                range: block.range,
                kind: block.kind,
                span: span,
                lines: text.paragraphCount(in: block.range, limit: Self.longBlockLines),
                aligned: aligned,
            ))
        }
        old[cursor...].forEach(drop)
        if foldsEnabled {
            // Carried by text: the old entries are rebased to today's text.
            let pins = folds.filter(\.pinned).map {
                NSUnionRange(entries[$0.first].span, entries[$0.last].span)
            }
            pendingFolds = (folds.indices.map(foldLook), pins)
            folds = []
        }
        firstRendering = fresh.firstIndex { $0.kind.renders } ?? fresh.count
        entries = fresh
        indexByID = Dictionary(uniqueKeysWithValues: entries.indices.map { (entries[$0].id, $0) })
        let context = entries.filter { $0.kind == .context }.map { text.substring(with: $0.range) }
            .joined(separator: "\n")
        if let contextText, contextText != context {
            epoch += 1
        }
        contextText = context
        restate(Array(entries.indices))
        evict()
    }

    /// Starts over from `source` when an edit does not fit the text held.
    private func resynchronize(_ source: NSString) {
        if entries.contains(where: { !$0.shown.isSource }) {
            changed = [NSRange(location: 0, length: source.length)]
        }
        text.setString(source as String)
        folds = []
        pendingFolds = nil
        entries = []
        indexByID = [:]
        revision += 1
        deferredBlocks = nil
        restartTimers()
        flush()
    }

    // MARK: - States

    /// Recomputes the active block and the states of `indices` and of the
    /// blocks the caret entered or left; all of them after a composition.
    /// With folds on, also rebuilds the folds over `indices` and `refolding`
    /// (entries next to an edit), pins the folds over `pinning` (entry ranges
    /// of closed folds an edit changed) and applies the caret to the folds.
    private func restate(
        _ indices: [Int],
        refolding dirty: ClosedRange<Int>? = nil,
        pinning pins: [ClosedRange<Int>] = [],
    ) {
        guard !hasMarkedText() else {
            restateWaits = true
            return
        }
        var indices = indices
        var dirty = dirty
        if restateWaits {
            restateWaits = false
            indices = Array(entries.indices)
        }
        if foldsEnabled {
            if let low = indices.min(), let high = indices.max() {
                dirty = dirty.map { min(low, $0.lowerBound) ... max(high, $0.upperBound) } ?? low ... high
            }
            if pendingFolds != nil {
                dirty = entries.isEmpty ? nil : 0 ... entries.count - 1
            }
            indices += refold(dirty)
            indices += pin(pins)
            indices += moveFoldCaret()
        }
        let active = caret.flatMap(entry(holding:)).map { entries[$0].id }
        if active != activeID {
            for id in [activeID, active].compactMap(\.self) {
                if let index = indexByID[id] {
                    indices.append(index)
                }
            }
            if activeID != nil {
                leftID = activeID
            }
            activeID = active
        }
        indices.forEach(show)
    }

    /// Gives block `index` the state it should draw and reports its
    /// paragraphs if that changes what they draw.
    private func show(_ index: Int) {
        let state = desiredState(index)
        let shown = entries[index].shown
        if state != shown {
            if !state.isSource || !shown.isSource {
                changed.append(entries[index].span)
            }
            entries[index].shown = state
        }
    }

    private func desiredState(_ index: Int) -> WritingBlockState {
        let entry = entries[index]
        if let fold = foldIndex(ofEntry: index) {
            // A block of a closed fold draws the fold even with the caret in
            // it, so the caret can rest on the row.
            return foldLook(fold).isOpen ? .source(.fold) : .pill(folds[fold].pill)
        }
        if entry.id == activeID {
            return .source(.active)
        }
        if entry.kind == .raw {
            return .source(.raw)
        }
        if entry.lines > Self.longBlockLines {
            return .source(.long)
        }
        if !entry.aligned {
            return .source(.unaligned)
        }
        if !entry.kind.renders {
            return .pill(WritingPill(text: label(index), muted: entry.kind == .comment))
        }
        if let failure = entry.failure {
            return .source(.failed(failure.message))
        }
        guard let rendering = entry.rendering, rendering.scale == appearance?.scale ?? rendering.scale else {
            return .source(.waiting)
        }
        return rendering.blank ? .pill(WritingPill(text: label(index), muted: true)) : .rendered(rendering)
    }

    private func label(_ index: Int) -> String {
        if let label = entries[index].label {
            return label
        }
        let label = text.firstLine(of: entries[index].range, length: Self.pillLength)
        entries[index].label = label
        return label
    }

    /// Reports the changed ranges unless text is marked.
    private func flush() {
        guard !hasMarkedText() else {
            return
        }
        report()
    }

    /// Reports the changed ranges, sorted and merged.
    private func report() {
        guard !changed.isEmpty else {
            return
        }
        let length = text.length
        var ranges: [NSRange] = []
        for range in changed.sorted(by: { $0.location < $1.location }) {
            let start = min(max(range.location, 0), length)
            let range = NSRange(location: start, length: min(max(NSMaxRange(range), start), length) - start)
            if let last = ranges.last, range.location <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        changed = []
        onChange?(ranges)
    }

    // MARK: - Folds

    private func foldsToggled(from old: Bool) {
        guard foldsEnabled != old, isRunning else {
            return
        }
        if !foldsEnabled {
            changed += folds.indices.map(foldLook).filter { !$0.isOpen }.map(\.span)
            folds = []
            pendingFolds = nil
            foldCaret = nil
            caretOpen = false
            caretHeld = false
        }
        restate(Array(entries.indices))
        flush()
    }

    private func setupRowsHidingChanged(from old: Bool) {
        guard hidesSetupRows != old, isRunning else {
            return
        }
        // A closed setup row away from the caret hides or shows; nothing else.
        let affected = folds.indices.filter { folds[$0].setup }.map(foldLook)
            .filter { !$0.isOpen && foldCaret != $0.restingPosition }
        guard !affected.isEmpty else {
            return
        }
        changed += affected.map(\.span)
        changedRoles()
        flush()
    }

    /// Whether block `index` is quiet: it would draw as a pill without folds
    /// and is not an `include` block. A block whose render was dropped by an
    /// edit stays quiet until a render says it has ink, so a fold does not
    /// split while it waits.
    private func isQuiet(_ index: Int) -> Bool {
        let entry = entries[index]
        guard entry.kind != .include, entry.kind != .raw, entry.aligned, entry.lines <= Self.longBlockLines else {
            return false
        }
        guard entry.kind.renders else {
            return true
        }
        return entry.failure == nil && (entry.rendering?.blank ?? entry.wasBlank)
    }

    /// Whether only blank text lies between block `index` and the next.
    private func gapIsBlank(after index: Int) -> Bool {
        let start = NSMaxRange(entries[index].span), end = entries[index + 1].span.location
        return end >= start && text.isBlank(NSRange(location: start, length: end - start))
    }

    private func foldRecord(_ first: Int, _ last: Int) -> FoldRecord {
        let blocks = entries[first ... last]
        if blocks.contains(where: { $0.kind == .context }) {
            let start = entries[first].range.location
            let extent = NSRange(location: start, length: NSMaxRange(entries[last].range) - start)
            let pill = WritingPill.setup(lines: text.nonBlankLineCount(in: extent), document: firstRendering >= first)
            return FoldRecord(first: first, last: last, setup: true, trail: 0, pill: pill)
        }
        let end = NSMaxRange(entries[last].span)
        let limit = last + 1 < entries.count ? entries[last + 1].span.location : text.length
        let mark: WritingPill.Mark = blocks.allSatisfy { $0.kind == .comment } ? .comment : .code
        let pill = WritingPill(
            text: text.firstLine(of: entries[first].range, length: Self.pillLength),
            muted: true,
            style: .mark(mark),
        )
        let trail = text.blankParagraphsLength(from: end, limit: max(end, limit))
        return FoldRecord(first: first, last: last, setup: false, trail: trail, pill: pill)
    }

    private func foldSpan(_ fold: Int) -> NSRange {
        let start = entries[folds[fold].first].span.location
        let end = min(NSMaxRange(entries[folds[fold].last].span) + folds[fold].trail, text.length)
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// What fold `fold` draws now.
    private func foldLook(_ fold: Int) -> WritingFold {
        let record = folds[fold]
        let span = foldSpan(fold)
        let open = record.pinned || caretOpen && foldCaret.map { holds(span, $0) } ?? false
        let hidden = !open && hidesSetupRows && record.setup && foldCaret != span.location
        return WritingFold(span: span, isOpen: open, pill: record.pill, isHidden: hidden)
    }

    /// Whether the caret at `offset` is in `span`: its first character through
    /// the end of its last line's content.
    private func holds(_ span: NSRange, _ offset: Int) -> Bool {
        offset >= span.location && offset <= text.contentEnd(of: span)
    }

    /// Reports fold `fold` if it draws otherwise than `before`, and returns
    /// its blocks to restate.
    private func lookChanged(_ fold: Int, from before: WritingFold) -> [Int] {
        let after = foldLook(fold)
        guard after != before else {
            return []
        }
        changed += [before.span, after.span]
        changedRoles()
        return Array(folds[fold].first ... folds[fold].last)
    }

    /// The entry ranges of the closed folds an edit of `edit` (in the text
    /// before it) changes: it shares characters with the span, or inserts
    /// from the resting position through the end of the last line's content.
    /// An edit before a fold only moves it.
    private func closedFolds(touchedBy edit: NSRange) -> [ClosedRange<Int>] {
        guard !folds.isEmpty else {
            return []
        }
        var ranges: [ClosedRange<Int>] = []
        var fold = lastFold(startingAtMost: edit.location) ?? 0
        while fold < folds.count {
            let look = foldLook(fold)
            guard look.span.location <= NSMaxRange(edit) else {
                break
            }
            if !look.isOpen, NSIntersectionRange(edit, look.span).length > 0 || holds(look.span, edit.location) {
                ranges.append(folds[fold].first ... folds[fold].last)
            }
            fold += 1
        }
        return ranges
    }

    /// The blocks whose quietness or neighbouring blank text an edit that
    /// is now `edited` can have changed.
    private func neighbourhood(of edited: NSRange) -> ClosedRange<Int>? {
        guard foldsEnabled, !entries.isEmpty else {
            return nil
        }
        let low = lastEntry(spanAtMost: edited.location) ?? 0
        return low ... max(low, lastEntry(spanAtMost: NSMaxRange(edited)) ?? 0)
    }

    /// Rebuilds the folds over the blocks `dirty` and their neighbours, keeps
    /// the pins of the folds they replace (by block, or by text after a new
    /// block list), reports every fold that draws otherwise and returns the
    /// blocks to restate. Costs the folds it touches, not the file, except
    /// after a new block list.
    private func refold(_ dirty: ClosedRange<Int>?) -> [Int] {
        let pending = pendingFolds
        pendingFolds = nil
        guard !entries.isEmpty, let dirty else {
            changed += (pending?.looks ?? []).filter { !$0.isOpen }.map(\.span)
            return []
        }
        var low = max(0, dirty.lowerBound - 1), high = min(entries.count - 1, dirty.upperBound + 1)
        if let fold = foldIndex(ofEntry: low) {
            low = folds[fold].first
        }
        if let fold = foldIndex(ofEntry: high) {
            high = folds[fold].last
        }
        var built: [FoldRecord] = []
        var index = low
        while index <= high {
            guard isQuiet(index) else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < entries.count, gapIsBlank(after: last), isQuiet(last + 1) {
                last += 1
            }
            built.append(foldRecord(index, last))
            index = last + 1
        }
        high = max(high, built.last?.last ?? high)
        let start = firstFold(lastAtLeast: low)
        var end = start
        while end < folds.count, folds[end].first <= high {
            end += 1
        }
        let replaced = folds[start ..< end]
        for fold in built.indices {
            let blocks = built[fold].first ... built[fold].last
            let extent = NSUnionRange(entries[blocks.lowerBound].span, entries[blocks.upperBound].span)
            built[fold].pinned = replaced.contains { $0.pinned && blocks.overlaps($0.first ... $0.last) }
                || (pending?.pins ?? []).contains { NSIntersectionRange($0, extent).length > 0 }
        }
        let before = pending?.looks ?? (start ..< end).map(foldLook)
        folds.replaceSubrange(start ..< end, with: built)
        let after = (start ..< start + built.count).map(foldLook)
        changed += Set(before).symmetricDifference(after).map(\.span)
        return Array(low ... high)
    }

    /// Pins every fold over the entry ranges `ranges`; returns the blocks to
    /// restate.
    private func pin(_ ranges: [ClosedRange<Int>]) -> [Int] {
        var restated: [Int] = []
        for range in ranges {
            var fold = firstFold(lastAtLeast: range.lowerBound)
            while fold < folds.count, folds[fold].first <= range.upperBound {
                if !folds[fold].pinned {
                    let before = foldLook(fold)
                    folds[fold].pinned = true
                    restated += lookChanged(fold, from: before)
                }
                fold += 1
            }
        }
        return restated
    }

    /// Applies the caret to the folds: entering a fold past its first
    /// character opens it, and it stays open anywhere in it, its first
    /// character included, until the caret leaves. Returns the blocks to
    /// restate.
    private func moveFoldCaret() -> [Int] {
        let old = foldCaret.flatMap(foldIndex(holding:))
        let new = caret.flatMap(foldIndex(holding:))
        let before = Set([old, new].compactMap(\.self)).map { ($0, foldLook($0)) }
        if old != new || new == nil {
            caretOpen = false
            caretHeld = false
        }
        foldCaret = caret
        if let new, let caret, !caretHeld, caret > foldSpan(new).location {
            caretOpen = true
        }
        return before.flatMap { lookChanged($0.0, from: $0.1) }
    }

    /// The last fold whose span starts at or before `location`.
    private func lastFold(startingAtMost location: Int) -> Int? {
        var low = 0, high = folds.count
        while low < high {
            let middle = (low + high) / 2
            if entries[folds[middle].first].span.location <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The first fold whose last block is `index` or later.
    private func firstFold(lastAtLeast index: Int) -> Int {
        var low = 0, high = folds.count
        while low < high {
            let middle = (low + high) / 2
            if folds[middle].last < index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The fold block `index` belongs to.
    private func foldIndex(ofEntry index: Int) -> Int? {
        let fold = firstFold(lastAtLeast: index)
        return fold < folds.count && folds[fold].first <= index ? fold : nil
    }

    /// The fold whose span holds the paragraph starting at `location`.
    private func foldIndex(at location: Int) -> Int? {
        guard let fold = lastFold(startingAtMost: location), location < NSMaxRange(foldSpan(fold)) else {
            return nil
        }
        return fold
    }

    /// The fold that holds the caret offset `offset` (see `holds`).
    private func foldIndex(holding offset: Int) -> Int? {
        guard let fold = lastFold(startingAtMost: offset), holds(foldSpan(fold), offset) else {
            return nil
        }
        return fold
    }

    /// The folds whose spans share characters with `range`.
    private func foldIndices(intersecting range: NSRange) -> [Int] {
        guard !folds.isEmpty else {
            return []
        }
        var indices: [Int] = []
        var fold = lastFold(startingAtMost: range.location) ?? 0
        while fold < folds.count {
            let span = foldSpan(fold)
            guard span.location < NSMaxRange(range) else {
                break
            }
            if NSIntersectionRange(span, range).length > 0 {
                indices.append(fold)
            }
            fold += 1
        }
        return indices
    }

    // MARK: - Searching

    /// The last block whose paragraphs start at or before `location`.
    private func lastEntry(spanAtMost location: Int) -> Int? {
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].span.location <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The first block whose paragraphs end at or after `location`.
    private func firstEntry(spanEndAtLeast location: Int) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(entries[middle].span) < location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The block whose paragraphs hold `offset`, the end of the last line included.
    private func entry(holding offset: Int) -> Int? {
        guard let index = lastEntry(spanAtMost: offset),
              offset <= text.contentEnd(of: entries[index].span)
        else {
            return nil
        }
        return index
    }

    // MARK: - Engine work

    private var key: WritingRenderKey? {
        appearance.flatMap { $0.canRender ? WritingRenderKey(appearance: $0, epoch: epoch) : nil }
    }

    private func restartTimers() {
        settleTask?.cancel()
        settleTask = timer(timing.settle) { $0.settleTask = nil }
        if let pause = timing.refreshPause {
            refreshTask?.cancel()
            refreshTask = timer(pause) {
                $0.refreshTask = nil
                $0.refreshDue = true
            }
        }
    }

    private func timer(_ delay: Duration, _ fire: @escaping (WritingLayout) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            fire(self)
            pump()
        }
    }

    /// The next engine call, without starting it.
    private func nextJob() -> Job? {
        if settleTask == nil, engineRevision != revision, failedRevision != revision, !hasMarkedText() {
            return .sync(text: text as String, revision: revision)
        }
        guard engineRevision == revision else {
            return nil
        }
        if urgentRefresh, refreshDue {
            return .refresh(filesChanged: filesChanged)
        }
        if let request = nextRender() {
            return .render(request)
        }
        return refreshDue ? .refresh(filesChanged: filesChanged) : nil
    }

    /// Starts the next engine call unless one is running.
    private func pump() {
        guard isRunning, let file else {
            resumeWaiters()
            return
        }
        guard !working else {
            return
        }
        guard let job = nextJob() else {
            if settleTask == nil, refreshTask == nil {
                resumeWaiters()
            }
            return
        }
        working = true
        let generation = generation, renderer = renderer
        if case .refresh = job {
            refreshDue = false
            filesChanged = false
            urgentRefresh = false
        }
        Task {
            switch job {
            case let .sync(text, revision):
                let reply: Result<[RenderBlock], any Error>
                do {
                    try await renderer.setText(text, of: file)
                    reply = try await .success(renderer.blocks(in: file))
                } catch {
                    reply = .failure(error)
                }
                received(reply, revision: revision, generation: generation)
            case let .render(request):
                let options = RenderOptions(
                    dark: request.key.appearance.dark,
                    bitmapScale: request.key.appearance.bitmapScale,
                )
                let width = request.key.appearance.renderWidth
                let result = await renderer.render(request.range, in: file, width: width, options: options)
                received(result, for: request, generation: generation)
            case let .refresh(filesChanged):
                let result = await renderer.refresh()
                received(result, filesChanged: filesChanged, generation: generation)
            }
            working = false
            pump()
        }
    }

    private func received(_ reply: Result<[RenderBlock], any Error>, revision: Int, generation: Int) {
        guard generation == self.generation else {
            return
        }
        syncReplies += 1
        switch reply {
        case let .failure(error):
            failedRevision = revision
            lastError = error.localizedDescription
        case let .success(blocks):
            engineRevision = revision
            lastError = nil
            // A reply for an older text is dropped; the newer text follows.
            guard revision == self.revision else {
                return
            }
            if hasMarkedText() {
                deferredBlocks = (revision, blocks)
                return
            }
            apply(blocks)
            flush()
        }
    }

    private func received(
        _ result: Result<RenderedBlock, BlockRendererError>,
        for request: RenderRequest,
        generation: Int,
    ) {
        guard generation == self.generation else {
            return
        }
        renderReplies += 1
        if hasMarkedText() {
            deferredRenders.append((request, result))
            return
        }
        apply(result, for: request)
        flush()
    }

    private func received(_ refresh: RenderRefresh, filesChanged: Bool, generation: Int) {
        guard generation == self.generation else {
            return
        }
        refreshReplies += 1
        if refresh.succeeded || filesChanged {
            // Numbers, references and citations may have changed; after a
            // change on disk, so may anything a render read.
            epoch += 1
        }
        if stale != !refresh.succeeded {
            stale = !refresh.succeeded
            onStaleChange?(stale)
        }
    }

    /// Keeps a render if its block still has the text it was asked for.
    private func apply(_ result: Result<RenderedBlock, BlockRendererError>, for request: RenderRequest) {
        guard let index = indexByID[request.id], request.key == key,
              text.substring(with: entries[index].range) == request.text
        else {
            return
        }
        if leftID == request.id {
            leftID = nil
        }
        switch result {
        case let .success(block) where block.bitmap != nil || block.drawnRect.isEmpty:
            nextSerial += 1
            let blank = block.ink.isNull || block.ink.isEmpty
            let rendering = WritingRendering(
                image: blank ? nil : block.bitmap,
                drawnRect: block.drawnRect,
                glyphs: block.glyphs,
                scale: request.key.appearance.scale,
                origin: request.range.location,
                blank: blank,
                serial: nextSerial,
                key: request.key,
                fingerprint: block.svg.hashValue,
                text: block.text,
                textFont: block.textFont,
            )
            if var old = entries[index].rendering, old.image != nil || old.blank, old.draws(like: rendering) {
                // The same picture: keep the one the view holds.
                old.key = request.key
                entries[index].rendering = old
            } else {
                entries[index].rendering = rendering
            }
            entries[index].failure = nil
            entries[index].wasBlank = blank
            if let font = block.textFont {
                entries[index].textFont = font
            }
        case .success:
            entries[index].rendering = nil
            entries[index].failure = ("The block is too large to draw.", request.key)
            entries[index].wasBlank = false
        case let .failure(error):
            entries[index].rendering = nil
            entries[index].failure = (error.message, request.key)
            entries[index].wasBlank = false
        }
        restate([index])
        evict()
    }

    /// The nearest block within a screen of the viewport that needs a render;
    /// the block the caret left comes first.
    private func nextRender() -> RenderRequest? {
        guard let key, let visible else {
            return nil
        }
        if let leftID {
            if let index = indexByID[leftID], needsRender(index, key) {
                return request(index, key)
            }
            self.leftID = nil
        }
        let screen = max(visible.length, 1)
        let low = visible.location - screen, high = NSMaxRange(visible) + screen
        var best: (distance: Int, index: Int)?
        var index = firstEntry(spanEndAtLeast: low)
        while index < entries.count, entries[index].range.location <= high {
            if needsRender(index, key) {
                let range = entries[index].range
                let distance = max(0, visible.location - NSMaxRange(range), range.location - NSMaxRange(visible))
                if best.map({ distance < $0.distance }) ?? true {
                    best = (distance, index)
                }
            }
            index += 1
        }
        return best.map { request($0.index, key) }
    }

    private func needsRender(_ index: Int, _ key: WritingRenderKey) -> Bool {
        let entry = entries[index]
        guard entry.kind.renders, entry.kind != .raw, entry.range.length > 0, entry.aligned,
              entry.lines <= Self.longBlockLines, entry.failure?.key != key,
              !deferredRenders.contains(where: { $0.request.id == entry.id })
        else {
            return false
        }
        guard let rendering = entry.rendering else {
            return true
        }
        return rendering.key != key || (rendering.image == nil && !rendering.blank)
    }

    private func request(_ index: Int, _ key: WritingRenderKey) -> RenderRequest {
        let range = entries[index].range
        return RenderRequest(id: entries[index].id, range: range, text: text.substring(with: range), key: key)
    }

    /// Frees the images of blocks more than three screens from the viewport.
    /// Their geometry stays, so their height does not change.
    private func evict() {
        guard let visible else {
            return
        }
        let screen = max(visible.length, 1)
        let keep = NSRange(location: visible.location - 3 * screen, length: visible.length + 6 * screen)
        for index in entries.indices {
            let range = entries[index].range
            guard range.location > NSMaxRange(keep) || NSMaxRange(range) < keep.location else {
                continue
            }
            entries[index].rendering?.image = nil
            if case var .rendered(rendering) = entries[index].shown, rendering.image != nil {
                rendering.image = nil
                entries[index].shown = .rendered(rendering)
            }
        }
    }

    private func resumeWaiters() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}
