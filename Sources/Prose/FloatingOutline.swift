import ProseCore
import SwiftUI

struct FloatingOutline: View {
    @ObservedObject var workspace: Workspace
    let availableMargin: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dismissTask: Task<Void, Never>?

    /// Hover expands the outline. The sidebar holds the persistent outline, so
    /// this one is shown only while the sidebar is hidden.
    private var expanded: Bool {
        hovering
    }

    private var panelWidth: CGFloat {
        // The outline stays inside the existing margin. Hover can briefly
        // expand it for reading long headings without moving the manuscript.
        min(224, max(hovering ? 180 : 28, availableMargin - 24))
    }

    private var navigation: OutlineNavigation {
        workspace.outlineNavigation
    }

    private var current: Int? {
        workspace.activeOutlineIndex.map { navigation.visibleAncestor(of: $0) }
    }

    private var visible: [Int] {
        navigation.visibleIndices
    }

    var body: some View {
        if !workspace.outline.isEmpty, !workspace.sidebarVisible {
            VStack(alignment: .leading, spacing: 0) {
                if expanded {
                    HStack(spacing: panelWidth < 70 ? 0 : 8) {
                        if panelWidth >= 140 {
                            Text(L10n.text("Outline")).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        if panelWidth >= 140, !navigation.branches.isEmpty {
                            foldButton(expand: !navigation.branches.allSatisfy(navigation.isExpanded))
                        }
                        Button {
                            hovering = false
                            workspace.sidebarVisible = true
                        } label: {
                            PhosphorIcon(name: "sidebar-simple", size: 14)
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 28, height: 28)
                        }.buttonStyle(QuietControlStyle())
                            .accessibilityIdentifier("outline.sidebar")
                            .accessibilityLabel(L10n.text("Show in Sidebar"))
                            .learningHelp(L10n.text("Show in Sidebar"), shortcut: "⌘0")
                    }.padding(.horizontal, panelWidth < 70 ? 0 : 10).padding(.top, 6).padding(.bottom, 4)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                if workspace.outline.isEmpty {
                                    Text(L10n.text("Write your first heading with =")).font(.system(size: 11))
                                        .foregroundStyle(Theme.muted).padding(14)
                                }
                                ForEach(visible, id: \.self) { index in
                                    outlineRow(index).id(index)
                                }
                            }.padding(5)
                        }.frame(height: min(350, max(52, CGFloat(visible.count) * 42 + 10)))
                            .onAppear {
                                if let current {
                                    proxy.scrollTo(current)
                                }
                            }
                            .onChange(of: current) {
                                _, value in if let value {
                                    proxy.scrollTo(value)
                                }
                            }
                    }
                } else {
                    Button { workspace.sidebarVisible = true } label: {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(navigation.minimapBuckets(), id: \.lowerBound) { bucket in
                                let active = workspace.activeOutlineIndex.map { bucket.contains($0) } ?? false
                                Capsule().fill(active ? Theme.accent.opacity(0.9) : Theme.muted.opacity(0.45))
                                    .frame(
                                        width: bucket.contains(where: { navigation.parents[$0] == nil }) ? 16 : 9,
                                        height: 2,
                                    )
                            }
                        }.padding(.horizontal, 7).padding(.vertical, 15).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("Show outline"))
                }
            }
            .frame(width: expanded ? panelWidth : 30, alignment: .leading)
            .background {
                if expanded, panelWidth >= 70 {
                    // Opaque beside the text on narrow windows, blending into the
                    // existing margin on wide ones. No card, border or drop shadow.
                    LinearGradient(
                        stops: [.init(color: Theme.editor, location: 0), .init(color: Theme.editor, location: 0.88),
                                .init(
                                    color: Theme.editor.opacity(0),
                                    location: 1,
                                )],
                        startPoint: .leading,
                        endPoint: .trailing,
                    )
                }
            }
            .onHover { inside in
                dismissTask?.cancel()
                if inside {
                    hovering = true
                } else {
                    dismissTask = Task {
                        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                        hovering = false
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
            .onDisappear { dismissTask?.cancel() }
        }
    }

    private func foldButton(expand: Bool) -> some View {
        Button { workspace.expandOutline(expand) } label: {
            PhosphorIcon(name: expand ? "caret-double-down" : "caret-double-up", size: 14)
                .foregroundStyle(Theme.secondary).frame(width: 28, height: 28)
        }.buttonStyle(QuietControlStyle())
            .accessibilityIdentifier(expand ? "outline.expandAll" : "outline.collapseAll")
            .accessibilityLabel(L10n.text(expand ? "Expand All Headings" : "Collapse All Headings"))
            .learningHelp(
                L10n.text(expand ? "Expand All Headings" : "Collapse All Headings"),
                shortcut: "⌘\(workspace.commandKey.uppercased()) → v " + (expand ? "e" : "c"),
            )
    }

    private func outlineRow(_ index: Int) -> some View {
        let item = navigation.items[index]
        return HStack(spacing: 3) {
            Capsule().fill(index == current ? Theme.accent.opacity(0.8) : Color.clear).frame(width: 2, height: 11)
            if panelWidth >= 70 {
                if navigation.branches.contains(index) {
                    Button { workspace.toggleOutlineSection(index) } label: {
                        PhosphorIcon(name: "caret-right", size: 10)
                            .rotationEffect(.degrees(navigation.isExpanded(index) ? 90 : 0))
                            .frame(width: 16, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(L10n
                            .text(navigation.isExpanded(index) ? "Collapse section" : "Expand section") + ": " + item
                            .title)
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }
            }
            Button { workspace.jump(to: item.offset) } label: {
                HStack(spacing: 0) {
                    if panelWidth >= 70 {
                        Text(item.title).font(.system(size: 11, weight: index == current ? .medium : .regular))
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(item.title)
        }.foregroundStyle(index == current ? Theme.text : Theme.secondary)
            .padding(.leading, panelWidth < 70 ? 3 : CGFloat(3 + min(item.level - 1, 4) * 7)).padding(.trailing, 6)
    }
}
