import AppKit
import SwiftUI

extension View {
    /// The same quiet, keyboard-first help on every compact action.
    func learningHelp(_ title: String, shortcut: String? = nil, detail: String? = nil) -> some View {
        background(HoverHelp(title: title, shortcut: shortcut, detail: detail))
            .accessibilityHint([detail, shortcut].compactMap(\.self).joined(separator: " · "))
    }
}

private struct HoverHelp: NSViewRepresentable {
    let title: String
    let shortcut: String?
    let detail: String?

    func makeNSView(context: Context) -> HelpAnchor {
        HelpAnchor()
    }

    func updateNSView(_ view: HelpAnchor, context: Context) {
        view.title = title
        view.shortcut = shortcut
        view.detail = detail
    }

    static func dismantleNSView(_ view: HelpAnchor, coordinator: ()) {
        view.dismiss()
    }
}

@MainActor
final class HelpAnchor: NSView {
    var title = ""
    var shortcut: String?
    var detail: String?
    private var tracking: NSTrackingArea?
    private var pending: Task<Void, Never>?
    private(set) var popover: NSPopover?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.showHelp()
        }
    }

    override func mouseExited(with event: NSEvent) {
        dismiss()
    }

    override func viewDidMoveToWindow() {
        if window == nil {
            dismiss()
        }
    }

    func showHelp() {
        guard window != nil, popover == nil else {
            return
        }
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        let controller = NSHostingController(
            rootView:
            HStack(spacing: 12) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                if let shortcut {
                    Keycap(value: shortcut)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: true)
                .background(Theme.panel),
        )
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        popover?.close()
        popover = nil
    }
}
