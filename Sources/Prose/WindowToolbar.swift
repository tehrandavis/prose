import AppKit
import Combine
import ProseCore
import SwiftUI

@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    private let workspace: Workspace
    private let navigationID = NSToolbarItem.Identifier("ProseNavigation")
    private let documentID = NSToolbarItem.Identifier("ProseDocument")
    private let actionsID = NSToolbarItem.Identifier("ProseActions")

    private let titleSize = ToolbarTitleSize()
    private var subscriptions: Set<AnyCancellable> = []

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        Publishers.CombineLatest3(workspace.$managedTitle, workspace.$fileURL, workspace.$isPackageSource)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.resizeTitle() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: workspace.window)
            .sink { [weak self] _ in self?.resizeTitle() }.store(in: &subscriptions)
        resizeTitle()
    }

    private func resizeTitle() {
        // The widest font the title uses (a folder project's file name).
        let textWidth = (workspace.title as NSString).size(withAttributes: [.font: NSFont.systemFont(
            ofSize: 14,
            weight: .semibold,
        )]).width
        let projectWidth = ((workspace.project?.name ?? "") as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        // Reserve the traffic lights, the three buttons on the left, the status
        // dot and the fixed actions on the right, and the toolbar's spacing.
        // The whole name shows when the window has the room for it.
        let available = max(140, (workspace.window?.frame.width ?? 820) - 600)
        let badgeWidth = workspace.isPackageSource ?
            (L10n.text("Read-only") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
            .width + 36 : 0
        let width = min(available, max(120, ceil(max(textWidth, projectWidth) + badgeWidth) + 40))
        if titleSize.width != width {
            titleSize.width = width
        }
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ProseToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // The document's name sits in the middle of the window, as in other Mac apps.
        toolbar.centeredItemIdentifiers = [documentID]
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [navigationID, .flexibleSpace, documentID, .flexibleSpace, actionsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool,
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == navigationID {
            item.label = L10n.text("Headings Around the Caret")
            item.view = NSHostingView(rootView: TitleNavigation(workspace: workspace).frame(height: 30)
                .modifier(FocusTitleItem(chrome: workspace.focusChrome)))
        } else if identifier == documentID {
            item.label = L10n.text("Current Document")
            item.view = NSHostingView(rootView: AdaptiveDocumentTitle(workspace: workspace, size: titleSize)
                .modifier(FocusTitleItem(chrome: workspace.focusChrome)))
        } else if identifier == actionsID {
            item.label = L10n.text("Writing Views and Export")
            item.view = NSHostingView(rootView: WritingActions(workspace: workspace).frame(height: 30)
                .modifier(FocusTitleItem(chrome: workspace.focusChrome)))
        } else {
            return nil
        }
        // AppKit adds Liquid Glass behind custom toolbar views on macOS 26,
        // independently of SwiftUI's button style. Keep both groups unframed.
        item.isBordered = false
        return item
    }
}

@MainActor
private final class ToolbarTitleSize: ObservableObject {
    @Published var width: CGFloat = 240
}

private struct AdaptiveDocumentTitle: View {
    let workspace: Workspace
    @ObservedObject var size: ToolbarTitleSize
    var body: some View {
        DocumentTitle(workspace: workspace).frame(width: size.width, height: 30)
    }
}

/// The three buttons at the left edge, then the breadcrumb.
private struct TitleNavigation: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 8) {
            QuietButton(
                icon: "sidebar-simple",
                help: L10n.text("Sidebar"),
                shortcut: "⌘0",
                active: workspace.sidebarVisible,
            ) { workspace.sidebarVisible.toggle() }
                .accessibilityIdentifier("toolbar.sidebar")
            QuietButton(icon: "files", help: L10n.text("Your writing"), shortcut: "⌘O") { workspace.openLibrary() }
                .accessibilityIdentifier("toolbar.library")
            QuietButton(
                icon: "grid-four",
                help: L10n.text("Templates"),
                shortcut: WritingCommand.all.first { $0.id == "new" }?.shortcuts.first?.label,
            ) { workspace.newFromTemplate() }
                .accessibilityIdentifier("toolbar.templates")
            TitleLocation(workspace: workspace)
        }.frame(height: 30).foregroundStyle(Theme.text).fixedSize()
    }
}

/// The document's name, centred in the window.
private struct DocumentTitle: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 8) {
            if let project = workspace.project, case .folder = project.kind, !workspace.isPackageSource {
                VStack(alignment: .center, spacing: 0) {
                    Text(workspace.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(project.name).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .center)
                    .help(workspace.fileURL?.path ?? workspace.title)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toolbar.title")
            } else if workspace.isPackageSource {
                Text(workspace.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .help(workspace.fileURL?.path ?? workspace.title)
                ReadOnlyPackageBadge()
            } else {
                EditableDocumentName(
                    title: workspace.title,
                    documentID: workspace.managedDocumentID,
                    centered: true,
                    onOpen: { workspace.openLibrary() },
                    onRename: { [id = workspace.managedDocumentID] title in
                        guard let id else {
                            return
                        }
                        workspace.library.perform { try await workspace.library.rename(id, title: title) }
                    },
                    onFinish: { workspace.editor?.window?.makeFirstResponder(workspace.editor) },
                )
                .frame(height: 16).frame(height: 30)
                .learningHelp(L10n.text("Click to rename. Double-click to open your writing."))
            }
            if workspace.hasUnsavedChanges {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).accessibilityLabel(L10n.text("Unsaved"))
            }
        }.frame(height: 30).foregroundStyle(Theme.text)
    }
}

struct ReadOnlyPackageBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            PhosphorIcon(name: "lock-simple", size: 12)
            Text(L10n.text("Read-only"))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.secondary.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border.opacity(0.7), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Read-only Package"))
        .accessibilityIdentifier("toolbar.read-only")
        .learningHelp(
            L10n.text("Read-only Package"),
            detail: L10n.text("You can view and copy package source. Save a copy to edit it."),
        )
    }
}

private struct WritingActions: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(workspace: workspace)
            ModeControl(workspace: workspace)
            Rectangle().fill(Theme.border.opacity(0.65)).frame(width: 1, height: 12).padding(.horizontal, 5)
            QuietButton(
                icon: "arrow-square-out",
                help: L10n.text("Export PDF"),
                shortcut: WritingCommand.all.first { $0.id == "export" }?.shortcuts.first?.label,
                detail: L10n.text("Export the current document in its original colors."),
            ) { workspace.exportPDF() }.disabled(workspace.exporting)
            QuietButton(
                icon: "square-split-horizontal",
                help: L10n.text("Show or Hide Preview"),
                shortcut: WritingCommand.all.first { $0.id == "togglePreview" }?.shortcuts.first?.label,
                detail: L10n.text("Show the finished pages beside your text, or hide them."),
                active: workspace.previewShown,
            ) { workspace.togglePreview() }.accessibilityIdentifier("toolbar.preview")
        }.fixedSize().disabled(workspace.isLibraryHome)
    }
}

/// Code, Writing and Focus.
struct ModeControl: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorMode.allCases, id: \.self) { mode in
                let selected = workspace.editorMode == mode
                Button { workspace.setMode(mode) } label: {
                    Text(L10n.text(mode.title)).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 10).frame(minWidth: 26).frame(height: 26)
                        .background(selected ? Theme.editor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(mode.title))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("mode." + mode.rawValue)
                    .learningHelp(
                        L10n.text(mode.title),
                        shortcut: "⌘\((EditorMode.allCases.firstIndex(of: mode) ?? 0) + 1)",
                    )
            }
        }.padding(2).background(Theme.border.opacity(0.45), in: RoundedRectangle(cornerRadius: 8)).frame(height: 30)
    }
}

extension EditorMode {
    var title: String {
        switch self {
        case .code: "Code"
        case .writing: "Writing"
        case .focus: "Focus"
        }
    }
}

/// The breadcrumb of headings around the caret.
private struct TitleLocation: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 6) {
            let trail = workspace.breadcrumb
            // The innermost three headings; a long path is cut from the left.
            if trail.count > 3 {
                Text("…").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(trail.suffix(3).enumerated()), id: \.element.offset) { position, item in
                if position > 0 || trail.count > 3 {
                    Text("›").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Button { workspace.jump(to: item.offset) } label: {
                    Text(item.title).font(.system(size: 11, weight: item == trail.last ? .medium : .regular))
                        .foregroundStyle(item == trail.last ? Theme.text : Theme.secondary)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 180)
                }.buttonStyle(.plain).accessibilityIdentifier("breadcrumb.\(item.offset)")
            }
        }.fixedSize().disabled(workspace.isLibraryHome).opacity(workspace.isLibraryHome ? 0 : 1)
    }
}

struct StatusDot: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        let status = workspace.compileStatus
        Button { workspace.checksOpen.toggle() } label: {
            ZStack {
                switch status {
                case .succeeded: Circle().fill(Theme.green)
                case .compiling: Circle().fill(Theme.amber)
                case .failed: Circle().fill(Theme.red)
                case .offline: Circle().strokeBorder(Theme.muted, lineWidth: 1.5)
                }
            }.frame(width: 8, height: 8).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Document Checks") + ": " + status.label)
            .accessibilityIdentifier("toolbar.status." + status.rawValue)
            .learningHelp(status.label, shortcut: "⌘5")
    }
}
