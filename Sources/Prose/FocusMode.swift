import AppKit
import SwiftUI

/// The panes Focus mode hides, as they were when it began.
struct FocusPanes: Equatable {
    var sidebarVisible: Bool
    var layout: EditorLayout
}

/// Focus mode is Writing mode plus view state (decision 2 of the Phase 4
/// note): the sidebar and preview hide, the column narrows and the blocks
/// draw larger, and the title row and status bar show only on demand.
extension Workspace {
    /// Saves and hides the panes on entering Focus, restores them exactly on
    /// leaving it, and gives the editor Focus mode's column or takes it back.
    /// SwiftUI lays the panes out on a later turn; if that changes the column
    /// again, Writing mode's entry waits for renders at the final width.
    func focusModeChanged(from old: EditorMode) {
        guard editorMode == .focus || old == .focus else {
            return
        }
        applyingFocusPanes = true
        if editorMode == .focus {
            focusSavedPanes = FocusPanes(sidebarVisible: sidebarVisible, layout: layout)
            sidebarVisible = false
            layout = .writing
        } else if let saved = focusSavedPanes {
            sidebarVisible = saved.sidebarVisible
            if layout != saved.layout {
                layout = saved.layout
            }
            focusSavedPanes = nil
        }
        applyingFocusPanes = false
        focusChrome.setActive(editorMode == .focus, in: window)
        editor?.focusColumn = editorMode == .focus
    }

    /// The sidebar or the layout changed while Focus was on (`⌘0`, `⌘⇧P`, a
    /// menu item, a command): Focus ends for Writing mode. The change stands,
    /// and the other pane comes back as it was before Focus.
    func paneChangedInFocus(sidebar: Bool) {
        guard editorMode == .focus, !applyingFocusPanes else {
            return
        }
        var panes = focusSavedPanes ?? FocusPanes(sidebarVisible: sidebarVisible, layout: layout)
        if sidebar {
            panes.sidebarVisible = sidebarVisible
        } else {
            panes.layout = layout
        }
        focusSavedPanes = panes
        setMode(.writing)
    }
}

/// The title row's document title, mode control and buttons, and the status
/// bar, while Focus mode is on: hidden, and shown while the pointer is over the
/// title row or within `statusBarReach` of the window's bottom edge. The status
/// bar hides `hideDelay` after the pointer leaves that strip. The floating
/// toolbar hides while the user types and shows again when the pointer moves.
@MainActor
final class FocusChrome: ObservableObject {
    static let statusBarReach: CGFloat = 34
    /// Tests shorten it.
    var hideDelay: Duration = .seconds(1)

    @Published private(set) var active = false
    @Published private(set) var titleShown = false
    @Published private(set) var statusBarShown = false
    /// Whether typing hid the floating toolbar (Focus mode only).
    @Published private(set) var toolbarHidden = false
    private var hideTask: Task<Void, Never>?
    /// Follows the pointer while Focus mode is on.
    private(set) var tracker: FocusPointerTracker?

    /// Whether the title row hides its document title, mode control and buttons.
    var hidesTitle: Bool {
        active && !titleShown
    }

    /// Whether the status bar is hidden.
    var hidesStatusBar: Bool {
        active && !statusBarShown
    }

    /// Turns Focus mode's chrome on or off, and follows the pointer over
    /// `window` while it is on.
    func setActive(_ on: Bool, in window: NSWindow?) {
        hideTask?.cancel()
        hideTask = nil
        titleShown = false
        statusBarShown = false
        toolbarHidden = false
        tracker?.detach()
        tracker = nil
        active = on
        if on, let window {
            tracker = FocusPointerTracker(chrome: self, window: window)
        }
    }

    /// The pointer is at `point` in window coordinates (origin at the bottom
    /// left), in a window whose content area ends at `contentTop`; above it
    /// lie the title row and the toolbar.
    func pointerMoved(to point: CGPoint, contentTop: CGFloat) {
        guard active else {
            return
        }
        if toolbarHidden {
            toolbarHidden = false
        }
        let overTitle = point.y >= contentTop
        if titleShown != overTitle {
            titleShown = overTitle
        }
        if point.y >= 0, point.y <= Self.statusBarReach {
            hideTask?.cancel()
            hideTask = nil
            if !statusBarShown {
                statusBarShown = true
            }
        } else {
            statusBarLeft()
        }
    }

    /// A key reached the editor: in Focus mode the floating toolbar fades out
    /// until the pointer moves. Command shortcuts are not typing.
    func keyTyped(_ event: NSEvent) {
        guard active, !toolbarHidden, !event.modifierFlags.contains(.command) else {
            return
        }
        toolbarHidden = true
    }

    /// The pointer left the window.
    func pointerExited() {
        guard active else {
            return
        }
        if titleShown {
            titleShown = false
        }
        statusBarLeft()
    }

    private func statusBarLeft() {
        guard statusBarShown, hideTask == nil else {
            return
        }
        let delay = hideDelay
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            hideTask = nil
            statusBarShown = false
        }
    }
}

/// Follows the pointer over the whole window, title row included, while
/// Focus mode is on: a tracking area on the content view's superview, the
/// window's frame view.
@MainActor
final class FocusPointerTracker: NSResponder {
    private weak var chrome: FocusChrome?
    private weak var window: NSWindow?
    private weak var view: NSView?
    private var area: NSTrackingArea?

    init(chrome: FocusChrome, window: NSWindow) {
        self.chrome = chrome
        self.window = window
        super.init()
        guard let view = window.contentView?.superview ?? window.contentView else {
            return
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        view.addTrackingArea(area)
        self.view = view
        self.area = area
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func detach() {
        if let area {
            view?.removeTrackingArea(area)
        }
        area = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window else {
            return
        }
        chrome?.pointerMoved(to: event.locationInWindow, contentTop: window.contentLayoutRect.maxY)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        chrome?.pointerExited()
    }
}

/// Hides a title row item while Focus mode's chrome hides the title.
struct FocusTitleItem: ViewModifier {
    @ObservedObject var chrome: FocusChrome

    func body(content: Content) -> some View {
        let hidden = chrome.hidesTitle
        content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
}
