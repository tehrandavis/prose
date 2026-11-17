import AppKit
import ProseCore
import SwiftUI

/// Where the comments' cards go in an editor pane (Phase 8 decision 6).
enum CommentGutter: Equatable {
    /// No comment to show.
    case hidden
    /// The column stays centred and the gutter is to its right.
    case centred
    /// The column moves left by this much, its width unchanged, to make room.
    case shifted(CGFloat)
    /// No room for the gutter: an icon per comment in the right margin, and
    /// the card in a popover.
    case icons

    /// The gutter's width.
    static let width: CGFloat = 240
    /// Between the column's right edge and the gutter.
    static let gap: CGFloat = 12

    var shift: CGFloat {
        if case let .shifted(shift) = self {
            return shift
        }
        return 0
    }

    var showsCards: Bool {
        switch self {
        case .centred, .shifted: true
        case .hidden, .icons: false
        }
    }

    /// The layout for a pane `paneWidth` wide, from the column's margins in
    /// `ManuscriptLayout`. `hasComments` is whether the file has a comment
    /// to show, so the gutter never appears or vanishes while the writer
    /// scrolls.
    static func layout(paneWidth: CGFloat, focus: Bool, hasComments: Bool) -> Self {
        guard hasComments, paneWidth > 0 else {
            return .hidden
        }
        let inset = ManuscriptLayout.horizontalInset(for: paneWidth, focus: focus)
        let column = paneWidth - 2 * inset
        let needed = gap + width
        if inset >= needed {
            return .centred
        }
        let left = paneWidth - needed - column
        if left >= ManuscriptLayout.minimumInset {
            return .shifted((inset - left).rounded())
        }
        return .icons
    }
}

/// One comment the overlay shows, before any geometry.
struct CommentCardItem: Equatable {
    enum Kind: Equatable {
        case attached
        /// Attached, with no text left between the markers.
        case emptyAnchor
        /// One of the two markers is missing, or they are in the wrong order.
        case damaged
        case draft
    }

    let id: String
    /// The offset whose first drawn line the card is level with.
    let offset: Int
    let anchor: NSRange
    let kind: Kind
}

/// The comments' overlay (Phase 8 decision 6): an AppKit view over the
/// editor pane, a sibling of the scroll view, so it is outside the text view
/// and the text system. It holds one hosted SwiftUI card per comment whose
/// anchor is in the laid-out viewport, or an icon in the right margin. It
/// moves them when the clip view's bounds change, in the same turn of the
/// run loop. Clicks that miss a card or an icon pass through to the editor.
@MainActor
final class CommentOverlay: NSView {
    static let cardWidth: CGFloat = 224
    static let spacing: CGFloat = 8
    static let iconSize: CGFloat = 16
    static let iconHit: CGFloat = 24

    private(set) weak var editor: ManuscriptTextView?
    private(set) weak var workspace: Workspace?
    /// The layout of the last refresh.
    private(set) var gutter: CommentGutter = .hidden
    /// Each comment's card state, kept while its card is out of view so a
    /// reply being typed survives a scroll.
    private(set) var models: [String: CommentCardModel] = [:]
    private(set) var cards: [String: NSHostingView<CommentCardView>] = [:]
    private(set) var icons: [String: CommentIconView] = [:]
    /// Each card's height for its content, measured once per change.
    private var heights: [String: (key: CommentCardModel.LayoutKey, height: CGFloat)] = [:]
    /// The popover of the icon layout.
    private(set) var popover: NSPopover?
    private(set) var popoverID: String?
    /// For tests: full refreshes made.
    private(set) var refreshes = 0
    private var refreshScheduled = false
    /// Previous, Next and the count, pinned at the top of the gutter (or of
    /// the pane in the icon layout). It does not scroll with the cards.
    let navigator = CommentNavigatorView()
    /// Space between the navigator and the pane's top edge.
    static let navigatorTop: CGFloat = 8

    override var isFlipped: Bool {
        true
    }

    func attach(editor: ManuscriptTextView, workspace: Workspace) {
        self.editor = editor
        self.workspace = workspace
        editor.commentOverlay = self
        editor.comments.showsComments = workspace.showsComments
        editor.comments.showsResolved = workspace.showsResolvedComments
        navigator.run = { [weak workspace] id in
            guard let workspace, let command = WritingCommand.all.first(where: { $0.id == id }) else {
                return
            }
            workspace.execute(command)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Comments"))
    }

    /// Only cards and icons take clicks; the rest of the pane is the editor's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for view in subviews.reversed() where !view.isHidden && view.frame.contains(local) {
            return view.hitTest(convert(local, to: view.superview)) ?? view
        }
        return nil
    }

    override func isAccessibilityElement() -> Bool {
        !subviews.isEmpty
    }

    override func resetCursorRects() {
        for view in subviews where !view.isHidden {
            addCursorRect(view.frame, cursor: .arrow)
        }
    }

    override func layout() {
        super.layout()
        refresh()
    }

    /// Asks for a refresh in this pass of the run loop's layout.
    func setNeedsRefresh() {
        guard !refreshScheduled else {
            return
        }
        refreshScheduled = true
        needsLayout = true
        // A change outside a layout pass (an index that arrived, a scroll
        // task) gets its own turn.
        Task { @MainActor [weak self] in
            guard let self, refreshScheduled else {
                return
            }
            refresh()
        }
    }

    /// The clip view's bounds changed: the cards move now.
    func viewportScrolled() {
        refresh()
    }

    // MARK: - What to show

    /// Every comment to show, in document order: attached comments (resolved
    /// ones only while they are shown), damaged ones at the marker that
    /// exists, and the draft. Empty while comments are hidden.
    static func items(_ comments: CommentController) -> [CommentCardItem] {
        guard comments.showsComments else {
            return []
        }
        var items: [CommentCardItem] = []
        for placed in comments.placed where comments.showsResolved || !placed.isResolved {
            let anchor = placed.anchor
            items.append(CommentCardItem(
                id: placed.id,
                offset: anchor.length > 0 ? anchor.location : placed.start.location,
                anchor: anchor,
                kind: anchor.length > 0 ? .attached : .emptyAnchor,
            ))
        }
        for comment in comments.lastComments.values where comment.state == .damaged && comments.isShown(comment) {
            guard let marker = comment.startMarker ?? comment.endMarker else {
                continue
            }
            items.append(CommentCardItem(
                id: comment.id,
                offset: marker.location,
                anchor: NSRange(location: marker.location, length: 0),
                kind: .damaged,
            ))
        }
        if let draft = comments.draft {
            items.append(CommentCardItem(
                id: CommentDraft.id,
                offset: draft.range.location,
                anchor: draft.range,
                kind: .draft,
            ))
        }
        return items.sorted { ($0.offset, $0.id) < ($1.offset, $1.id) }
    }

    /// The card state of comment `id`, made on first use.
    func model(for id: String) -> CommentCardModel {
        if let model = models[id] {
            return model
        }
        let model = CommentCardModel(id: id)
        models[id] = model
        return model
    }

    // MARK: - Refresh

    func refresh() {
        refreshScheduled = false
        guard let editor, let workspace, window != nil else {
            return
        }
        refreshes += 1
        let comments = editor.comments
        _ = comments.comments
        let items = workspace.layout == .preview || workspace.isLibraryHome ? [] : Self.items(comments)
        let gutter = CommentGutter.layout(
            paneWidth: editor.frame.width,
            focus: editor.focusColumn,
            hasComments: !items.isEmpty,
        )
        self.gutter = gutter
        if editor.commentColumnShift != gutter.shift {
            editor.commentColumnShift = gutter.shift
        }
        if workspace.commentColumnShift != gutter.shift {
            // Published for the floating outline's margin, after this pass:
            // the refresh can run inside a view update.
            let shift = gutter.shift
            Task { @MainActor [weak workspace] in
                if workspace?.commentColumnShift != shift {
                    workspace?.commentColumnShift = shift
                }
            }
        }
        updateModels(items, comments)
        place(items, gutter: gutter, editor: editor, comments: comments)
        placeNavigator(items, gutter: gutter, editor: editor, active: comments.activeID)
    }

    /// The navigator's count: "3 of 12" for the active comment's place
    /// among the comments Next and Previous visit, in document order, or
    /// the total when no comment is active.
    static func navigatorCount(_ items: [CommentCardItem], active: String?) -> String {
        let visited = items.filter { $0.kind != .draft }
        if let active, let position = visited.firstIndex(where: { $0.id == active }) {
            return L10n.format("%@ of %@", String(position + 1), String(visited.count))
        }
        return visited.count == 1 ? L10n.text("1 comment") : L10n.format("%@ comments", String(visited.count))
    }

    /// Shows the navigator while a comment can be visited: at the top of the
    /// gutter over the cards' column, or in the pane's top right corner in
    /// the icon layout.
    private func placeNavigator(
        _ items: [CommentCardItem],
        gutter: CommentGutter,
        editor: ManuscriptTextView,
        active: String?,
    ) {
        guard gutter != .hidden, items.contains(where: { $0.kind != .draft }), let container = editor.textContainer
        else {
            if navigator.superview != nil {
                navigator.removeFromSuperview()
            }
            return
        }
        navigator.count = Self.navigatorCount(items, active: active)
        let size = navigator.fittingSize
        let x: CGFloat
        if gutter.showsCards {
            let columnRight = convert(
                NSPoint(x: editor.textContainerOrigin.x + container.size.width, y: 0),
                from: editor,
            ).x
            x = columnRight + CommentGutter.gap + (CommentGutter.width - Self.cardWidth) / 2
        } else {
            // Clear of the vertical scroller.
            x = bounds.width - size.width - 16
        }
        navigator.frame = NSRect(x: x.rounded(), y: Self.navigatorTop, width: size.width, height: size.height)
        // Above the cards, which scroll beneath it.
        if subviews.last !== navigator {
            addSubview(navigator, positioned: .above, relativeTo: nil)
        }
    }

    private func updateModels(_ items: [CommentCardItem], _ comments: CommentController) {
        let author = workspace?.commentAuthor ?? "Author"
        for item in items {
            let model = model(for: item.id)
            let comment = item.kind == .draft ? nil : comments.lastComments[item.id]
            if model.comment != comment {
                model.comment = comment
            }
            if model.kind != item.kind {
                model.kind = item.kind
            }
            let active = comments.activeID == item.id
            if model.isActive != active {
                model.isActive = active
            }
            if item.kind == .draft, model.draftAuthor != author {
                model.draftAuthor = author
            }
        }
        // Forget the state of comments that are gone and hold no typing.
        let known = Set(comments.lastComments.keys).union([CommentDraft.id])
        for (id, model) in models where !known.contains(id) && !model.holdsTyping {
            models[id] = nil
        }
        if comments.draft == nil, let draft = models[CommentDraft.id] {
            draft.reset()
        }
    }

    /// The laid-out viewport's source range.
    private func viewportRange(_ editor: ManuscriptTextView) -> NSRange? {
        guard let manager = editor.textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange
        else {
            return nil
        }
        let start = TextKit2Geometry.offset(of: viewport.location, in: manager)
        return NSRange(location: start, length: TextKit2Geometry.offset(of: viewport.endLocation, in: manager) - start)
    }

    /// The top of the first drawn line of `item`, in container coordinates:
    /// the row of a closed fold or pill that holds it, the glyph boxes of a
    /// rendered block, else TextKit's segment frame in source.
    static func anchorTop(_ item: CommentCardItem, in editor: ManuscriptTextView) -> CGFloat? {
        let writing = editor.writing
        if writing.isRunning, let model = writing.model {
            if let fold = model.fold(holding: item.offset), !fold.isOpen {
                guard !fold.isHidden, let fragment = writing.fragment(at: fold.span.location) else {
                    return nil
                }
                return fragment.layoutFragmentFrame.minY
            }
            let range = item.anchor.length > 0 ? item.anchor : NSRange(location: item.offset, length: 0)
            if let drawn = writing.firstDrawnRect(of: range) {
                return drawn.rect.minY
            }
        }
        guard let manager = editor.textLayoutManager else {
            return nil
        }
        let length = (editor.string as NSString).length
        let probe = NSRange(location: item.offset, length: item.offset < length ? 1 : 0)
        let rects = TextKit2Geometry.segments(probe, type: .standard, in: manager)
        return (rects.first ?? TextKit2Geometry.caretRect(at: item.offset, in: manager))?.minY
    }

    /// Whether `anchor` touches a focus block.
    static func touches(_ anchor: NSRange, _ spans: [NSRange]) -> Bool {
        spans.contains {
            NSIntersectionRange($0, anchor).length > 0 || NSLocationInRange(anchor.location, $0) ||
                (anchor.length == 0 && anchor.location == NSMaxRange($0))
        }
    }

    /// Stacks cards in document order with `spacing` between them so none
    /// overlaps: each top is the lower of its anchor's line and the card
    /// above plus the spacing. The active card sits level with its anchor
    /// and the cards before it move up to make room.
    static func stack(tops: [CGFloat], heights: [CGFloat], active: Int?) -> [CGFloat] {
        var result = tops
        guard !tops.isEmpty else {
            return result
        }
        let first = active ?? 0
        result[first] = tops[first]
        if first + 1 < tops.count {
            for index in first + 1 ..< tops.count {
                result[index] = max(tops[index], result[index - 1] + heights[index - 1] + spacing)
            }
        }
        if first > 0 {
            for index in stride(from: first - 1, through: 0, by: -1) {
                result[index] = min(tops[index], result[index + 1] - spacing - heights[index])
            }
        }
        return result
    }

    private func place(
        _ items: [CommentCardItem],
        gutter: CommentGutter,
        editor: ManuscriptTextView,
        comments: CommentController,
    ) {
        guard gutter != .hidden, let viewport = viewportRange(editor), let container = editor.textContainer else {
            removeAll(keeping: nil)
            return
        }
        let focusSpans = editor.writing.focused ? editor.writing.focusSpans : nil
        var shownCards: [(item: CommentCardItem, top: CGFloat)] = []
        var shownIcons: [(item: CommentCardItem, top: CGFloat, dim: Bool)] = []
        let origin = editor.textContainerOrigin
        for item in items where NSLocationInRange(item.offset, viewport) || item.offset == NSMaxRange(viewport) {
            guard let top = Self.anchorTop(item, in: editor) else {
                continue
            }
            let y = convert(NSPoint(x: 0, y: top + origin.y), from: editor).y
            let dims = focusSpans.map { !Self.touches(item.anchor, $0) && item.kind != .draft } ?? false
            if gutter.showsCards, !dims {
                shownCards.append((item, y))
            } else {
                shownIcons.append((item, y, dims))
            }
        }
        let columnRight = convert(NSPoint(x: origin.x + container.size.width, y: 0), from: editor).x
        // Cards.
        let heights = shownCards.map { height(of: $0.item.id) }
        let active = shownCards.firstIndex { $0.item.id == comments.activeID }
        let tops = Self.stack(tops: shownCards.map(\.top), heights: heights, active: active)
        var keptCards = Set<String>()
        for (index, shown) in shownCards.enumerated() {
            let view = card(for: shown.item.id)
            view.frame = NSRect(
                x: (columnRight + CommentGutter.gap + (CommentGutter.width - Self.cardWidth) / 2).rounded(),
                y: tops[index].rounded(),
                width: Self.cardWidth,
                height: heights[index],
            )
            keptCards.insert(shown.item.id)
        }
        // Icons: the third layout's, and Focus mode's dimmed ones.
        var keptIcons = Set<String>()
        for shown in shownIcons {
            let view = icon(for: shown.item.id)
            let x = gutter.showsCards ? columnRight + CommentGutter.gap : columnRight + Self.spacing
            view.frame = NSRect(x: x.rounded(), y: shown.top.rounded(), width: Self.iconHit, height: Self.iconHit)
            view.alphaValue = shown.dim ? WritingFocus.dimmedAlpha : 1
            view.dimmed = shown.dim
            keptIcons.insert(shown.item.id)
        }
        // The active card keeps its view while it holds the keyboard.
        if let activeID = comments.activeID, let view = cards[activeID], view.containsFirstResponder {
            keptCards.insert(activeID)
        }
        removeAll(keeping: (keptCards, keptIcons))
        window?.invalidateCursorRects(for: self)
    }

    /// The card's height for its content, measured again only when the
    /// content changed.
    private func height(of id: String) -> CGFloat {
        let model = model(for: id)
        let key = model.layoutKey
        if let cached = heights[id], cached.key == key {
            return cached.height
        }
        let view = card(for: id)
        view.frame.size.width = Self.cardWidth
        let height = ceil(view.fittingSize.height)
        heights[id] = (key, height)
        return height
    }

    /// The card's text changed size: stack again.
    func cardContentChanged(_ id: String) {
        heights[id] = nil
        setNeedsRefresh()
    }

    private func card(for id: String) -> NSHostingView<CommentCardView> {
        if let view = cards[id] {
            return view
        }
        let view = NSHostingView(rootView: CommentCardView(model: model(for: id), overlay: self))
        view.setAccessibilityIdentifier("comment.card.\(id)")
        cards[id] = view
        addSubview(view)
        return view
    }

    private func icon(for id: String) -> CommentIconView {
        if let view = icons[id] {
            return view
        }
        let view = CommentIconView(id: id) { [weak self] icon in
            self?.iconClicked(icon)
        }
        let author = models[id]?.comment?.entries.first?.author
        view.setAccessibilityLabel(author.map { L10n.format("Comment by %@", $0) } ?? L10n.text("Comment"))
        icons[id] = view
        addSubview(view)
        return view
    }

    private func removeAll(keeping kept: (cards: Set<String>, icons: Set<String>)?) {
        for (id, view) in cards where !(kept?.cards.contains(id) ?? false) {
            view.removeFromSuperview()
            cards[id] = nil
        }
        for (id, view) in icons where !(kept?.icons.contains(id) ?? false) {
            view.removeFromSuperview()
            icons[id] = nil
        }
    }

    // MARK: - Clicks

    /// An icon was clicked: in Focus mode's dimmed margin it goes to the
    /// comment, which makes its block a focus block; in the third layout it
    /// opens the card in a popover.
    func iconClicked(_ icon: CommentIconView) {
        guard let workspace else {
            return
        }
        if icon.dimmed {
            workspace.goToComment(icon.id)
            return
        }
        workspace.activateComment(icon.id, reveal: false)
        showPopover(for: icon.id, relativeTo: icon)
    }

    func showPopover(for id: String, relativeTo view: NSView) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: CommentCardView(model: model(for: id), overlay: self))
        popover.contentViewController = host
        popover.contentSize = NSSize(width: Self.cardWidth, height: max(40, host.view.fittingSize.height))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        self.popover = popover
        popoverID = id
    }

    func closePopover() {
        popover?.close()
        popover = nil
        popoverID = nil
    }
}

extension NSView {
    /// Whether the window's first responder is this view or inside it (a
    /// field editor counts for the field it edits).
    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else {
            return false
        }
        if responder.isDescendant(of: self) {
            return true
        }
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView
        {
            return field.isDescendant(of: self)
        }
        return false
    }
}

/// A comment's icon in the right margin (decision 6): `chat-circle`, quiet
/// like the toolbar's buttons. It never takes keyboard focus.
@MainActor
final class CommentIconView: NSView {
    let id: String
    var dimmed = false
    private let action: (CommentIconView) -> Void

    init(id: String, action: @escaping (CommentIconView) -> Void) {
        self.id = id
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: CommentOverlay.iconHit, height: CommentOverlay.iconHit))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("comment.icon.\(id)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with _: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            action(self)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action(self)
        return true
    }

    override func draw(_: NSRect) {
        guard let image = IconStore.image("chat-circle") else {
            return
        }
        let size = CommentOverlay.iconSize
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        let tinted = NSImage(size: rect.size, flipped: false) { frame in
            image.draw(in: frame)
            Theme.nativeSecondary.set()
            frame.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }
}

/// Previous, Next and the count, pinned at the top of the comments' gutter.
/// The buttons run Previous Comment and Next Comment through the same path
/// as their shortcuts, and never take the keyboard from the editor.
@MainActor
final class CommentNavigatorView: NSView {
    static let height: CGFloat = 24
    /// Runs the command with this id.
    var run: ((String) -> Void)?
    let previous = CommentNavigatorButton(
        icon: "arrow-up",
        command: "previousComment",
        label: L10n.text("Previous Comment"),
        shortcut: "⌃⌥P",
    )
    let next = CommentNavigatorButton(
        icon: "arrow-down",
        command: "nextComment",
        label: L10n.text("Next Comment"),
        shortcut: "⌃⌥N",
    )
    private let label = NSTextField(labelWithString: "")

    var count: String {
        get { label.stringValue }
        set {
            if label.stringValue != newValue {
                label.stringValue = newValue
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var isFlipped: Bool {
        true
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.height))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Theme.nativeSecondary
        label.lineBreakMode = .byClipping
        label.setAccessibilityIdentifier("comment.navigator.count")
        for button in [previous, next] {
            button.action = { [weak self] id in self?.run?(id) }
            addSubview(button)
        }
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Go to a comment"))
        setAccessibilityIdentifier("comment.navigator")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var fittingSize: NSSize {
        intrinsicContentSize
    }

    override var intrinsicContentSize: NSSize {
        let side = CommentNavigatorButton.side
        return NSSize(width: ceil(2 * side + 6 + label.intrinsicContentSize.width + 8), height: Self.height)
    }

    override func layout() {
        super.layout()
        let side = CommentNavigatorButton.side
        let top = (bounds.height - side) / 2
        previous.frame = NSRect(x: 0, y: top, width: side, height: side)
        next.frame = NSRect(x: side, y: top, width: side, height: side)
        let text = label.intrinsicContentSize
        label.frame = NSRect(
            x: 2 * side + 6,
            y: ((bounds.height - text.height) / 2).rounded(),
            width: max(0, bounds.width - 2 * side - 6),
            height: text.height,
        )
    }

    /// The page colour behind it, so cards that scroll under it do not show
    /// through.
    override func draw(_: NSRect) {
        Theme.nativeEditor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

/// An up or down button of the navigator: a Phosphor icon with the quiet
/// hover and press wash, the accessibility of a button and no keyboard
/// focus. It runs on mouse up inside it.
@MainActor
final class CommentNavigatorButton: NSView {
    static let side: CGFloat = 22
    static let iconSize: CGFloat = 13
    let command: String
    var action: ((String) -> Void)?
    private var tracking: NSTrackingArea?

    private var hovering = false {
        didSet {
            if hovering != oldValue {
                needsDisplay = true
            }
        }
    }

    private var pressed = false {
        didSet {
            if pressed != oldValue {
                needsDisplay = true
            }
        }
    }

    private let icon: String

    init(icon: String, command: String, label: String, shortcut: String) {
        self.icon = icon
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        toolTip = label + " (" + shortcut + ")"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(toolTip)
        setAccessibilityIdentifier("comment.navigator." + command)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var canBecomeKeyView: Bool {
        false
    }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        action?(command)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
    }

    override func mouseDown(with _: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire {
            action?(command)
        }
    }

    override func draw(_: NSRect) {
        let alpha: CGFloat = pressed ? 0.14 : (hovering ? 0.08 : 0)
        if alpha > 0 {
            Theme.nativeSecondary.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        guard let image = IconStore.image(icon) else {
            return
        }
        let size = Self.iconSize
        let rect = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        let tinted = NSImage(size: rect.size, flipped: false) { frame in
            image.draw(in: frame)
            Theme.nativeSecondary.set()
            frame.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }
}
