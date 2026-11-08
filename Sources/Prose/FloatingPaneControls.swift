import ProseCore
import SwiftUI

/// Overlay chrome never participates in editor or preview sizing. The small
/// label remains discoverable; pointer hover or keyboard activation reveals it.
struct FloatingPaneControls<Controls: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var controls: () -> Controls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var heldOpen = false
    @State private var dismissTask: Task<Void, Never>?
    private var expanded: Bool {
        hovering || heldOpen
    }

    var body: some View {
        HStack(spacing: 2) {
            if expanded {
                controls().transition(.opacity)
            }
            Button { heldOpen.toggle() } label: {
                HStack(spacing: 5) {
                    PhosphorIcon(name: icon, size: 12)
                    Text(title).font(.system(size: 10))
                }.padding(.horizontal, 7).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(QuietControlStyle()).accessibilityLabel(title).learningHelp(title)
                .accessibilityValue(L10n.text(expanded ? "Expanded" : "Collapsed"))
        }.foregroundStyle(Theme.secondary)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
            .onHover { inside in
                dismissTask?.cancel()
                if inside {
                    hovering = true
                } else {
                    dismissTask = Task {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        hovering = false
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: expanded)
            .onDisappear { dismissTask?.cancel() }
    }
}
