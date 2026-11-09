import AppKit
import ProseCore
import SwiftUI

/// The five actions of the floating toolbar (decision 6 of the Phase 4 note,
/// spec Section 3.3). Each is a step of the `⌘J` panel, so the toolbar is a
/// second entry point to the command registry, not a second implementation.
enum ToolbarAction: String, CaseIterable, Identifiable {
    case style
    case table
    case equation
    case image
    case insert

    var id: String {
        rawValue
    }

    /// The Phosphor icon (Regular).
    var icon: String {
        switch self {
        case .style: "text-aa"
        case .table: "table"
        case .equation: "function"
        case .image: "image"
        case .insert: "plus"
        }
    }

    var identifier: String {
        "toolbar.\(rawValue)"
    }

    /// The panel group the action opens, or the group its command lies in.
    var group: ProseCore.CommandGroup? {
        let id = self == .style ? "style" : "insert"
        return CommandGroup.all.first { $0.id == id }
    }

    /// The command the action selects; nil for the two group actions.
    var command: WritingCommand? {
        switch self {
        case .style, .insert: nil
        case .table, .equation, .image: WritingCommand.all.first { $0.id == rawValue }
        }
    }

    /// The panel entry's title: the command's, or the group's.
    var title: String {
        command?.title ?? group?.title ?? rawValue
    }

    /// The panel entry's description.
    var detail: String {
        command?.detail ?? group?.subtitle ?? ""
    }

    /// The keys after `⌘J` that reach the same entry in the panel.
    var keyPath: String {
        command?.keyPath ?? group?.key ?? ""
    }
}

extension Workspace {
    /// Whether the editor mode shows the floating toolbar: Writing and Focus.
    var showsToolbarMode: Bool {
        editorMode != .code
    }

    /// Whether the floating toolbar is on screen: in Writing and Focus mode,
    /// while the editor pane is shown.
    var showsFloatingToolbar: Bool {
        showsToolbarMode && layout != .preview && !isLibraryHome
    }

    /// The hover help's shortcut for `action`: its path through the panel.
    func toolbarShortcut(for action: ToolbarAction) -> String {
        "⌘\(commandKey.uppercased()) → \(action.keyPath)"
    }

    /// Runs a toolbar button: the same calls as `⌘J` and the action's keys.
    /// The panel opens (if closed) at the action's group, and a command
    /// action then selects its command, which runs at once (`equation`) or
    /// opens its parameter form (`table`) or resource picker (`image`). The
    /// command uses the editor's selection as it was at the click.
    func performToolbarAction(_ action: ToolbarAction) {
        recordOperation("toolbar.action", [
            "action": action.rawValue,
            "editorFirstResponder": String(editor.map { window?.firstResponder === $0 } ?? false),
        ])
        guard showsFloatingToolbar, let group = action.group else {
            return
        }
        if !paletteOpen {
            togglePalette()
            guard paletteOpen else {
                return
            }
        }
        enterGroup(group.id)
        if let command = action.command {
            selectCommand(command)
        }
    }
}

/// The floating toolbar: five quiet buttons at the bottom center of the
/// editor pane, 16 pt above its bottom edge, and above Focus mode's status
/// bar while that shows. In Focus mode it fades out while the user types and
/// comes back when the pointer moves. Its buttons never take keyboard focus.
struct FloatingToolbar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var chrome: FocusChrome
    static let bottomMargin: CGFloat = 16
    static let padding: CGFloat = 4
    static let radius: CGFloat = 8

    /// Whether typing in Focus mode hid it.
    private var hidden: Bool {
        chrome.active && chrome.toolbarHidden
    }

    /// Its distance from the pane's bottom edge: above Focus mode's status
    /// bar while that is drawn over the text.
    private var bottom: CGFloat {
        Self.bottomMargin + (chrome.active && !chrome.hidesStatusBar ? ContentView.statusBarHeight : 0)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ToolbarAction.allCases) { action in
                ToolbarButton(
                    action: action,
                    help: [action.detail, workspace.toolbarShortcut(for: action)].joined(separator: " · "),
                    enabled: !hidden,
                ) {
                    workspace.performToolbarAction(action)
                }
                .frame(width: ToolbarButtonView.hitSize, height: ToolbarButtonView.hitSize)
                .learningHelp(action.title, shortcut: workspace.toolbarShortcut(for: action), detail: action.detail)
            }
        }
        .padding(Self.padding)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Writing Toolbar"))
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .accessibilityHidden(hidden)
        .animation(.easeOut(duration: 0.2), value: hidden)
        .padding(.bottom, bottom)
    }
}

/// A toolbar button as an AppKit view, so that it can refuse to become first
/// responder: a click on it never takes keyboard focus from the editor, and
/// the command reads the editor's selection as it was. It runs its action on
/// mouse up inside it, and through accessibility's press.
private struct ToolbarButton: NSViewRepresentable {
    let action: ToolbarAction
    let help: String
    let enabled: Bool
    let perform: () -> Void

    func makeNSView(context _: Context) -> ToolbarButtonView {
        ToolbarButtonView(action: action)
    }

    func updateNSView(_ view: ToolbarButtonView, context _: Context) {
        view.perform = perform
        view.enabled = enabled
        view.help = help
    }
}

/// The view behind each toolbar button: a Phosphor icon with the quiet hover
/// and press wash of `QuietControlStyle`, the accessibility of a button, and
/// no keyboard focus.
@MainActor
final class ToolbarButtonView: NSView {
    static let iconSize: CGFloat = 16
    static let hitSize: CGFloat = 30
    let action: ToolbarAction
    var perform: (() -> Void)?
    /// False while the toolbar is hidden: no clicks, not in the accessibility tree.
    var enabled = true {
        didSet {
            if !enabled {
                hovering = false
                pressed = false
            }
        }
    }

    /// The description and key path, as the hover help shows them.
    var help = "" {
        didSet {
            setAccessibilityHelp(help)
        }
    }

    private var hovering = false {
        didSet {
            if hovering != oldValue {
                needsDisplay = true
            }
        }
    }

    private(set) var pressed = false {
        didSet {
            if pressed != oldValue {
                needsDisplay = true
            }
        }
    }

    private let icon = ToolbarIconView()
    private var tracking: NSTrackingArea?

    init(action: ToolbarAction) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.hitSize, height: Self.hitSize))
        icon.image = IconStore.image(action.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = Theme.nativeSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.title)
        setAccessibilityIdentifier(action.identifier)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.hitSize, height: Self.hitSize)
    }

    /// Never first responder, never in the key view loop: the editor keeps
    /// the keyboard and its selection.
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled ? super.hitTest(point) : nil
    }

    override func isAccessibilityElement() -> Bool {
        enabled
    }

    override func isAccessibilityHidden() -> Bool {
        !enabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled, let perform else {
            return false
        }
        perform()
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
        hovering = enabled
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
    }

    /// AppKit delivers each event; there is no tracking loop, so a click that
    /// tests send through the window behaves as a real one.
    override func mouseDown(with _: NSEvent) {
        pressed = enabled
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = enabled && bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside
        pressed = false
        if fire {
            perform?()
        }
    }

    override func draw(_: NSRect) {
        let alpha: CGFloat = pressed ? 0.14 : (hovering ? 0.08 : 0)
        guard alpha > 0 else {
            return
        }
        Theme.nativeSecondary.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

/// The button's icon. Clicks pass through it to the button.
private final class ToolbarIconView: NSImageView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
