import ProseCore
import SwiftUI

/// One visible row of the sidebar: a file, a folder, a heading of the open
/// file, or a note that a large folder was cut short.
enum SidebarRow: Identifiable, Equatable {
    case item(ProjectNode, depth: Int)
    case heading(Int, depth: Int)
    case more(String, count: Int, depth: Int)

    var id: String {
        switch self {
        case let .item(node, _): "item:" + node.id
        case let .heading(index, _): "heading:\(index)"
        case let .more(folder, _, _): "more:" + folder
        }
    }
}

extension Workspace {
    /// The rows the sidebar shows, in order. The open Typst file is followed by
    /// its visible headings.
    var sidebarRows: [SidebarRow] {
        guard let project else {
            return outlineNavigation.visibleIndices.map { .heading($0, depth: 0) }
        }
        var rows: [SidebarRow] = []
        func walk(_ directory: URL, depth: Int) {
            guard var nodes = try? ProjectTree.children(of: directory) else {
                return
            }
            if case .library = project.kind {
                nodes.removeAll { OpenProject.hiddenLibraryFiles.contains($0.name) }
            }
            for (position, node) in nodes.enumerated() {
                if position == ProjectTree.largeFolderLimit {
                    rows.append(.more(directory.path, count: nodes.count - position, depth: depth))
                    break
                }
                rows.append(.item(node, depth: depth))
                if node.isDirectory, project.expanded.contains(relative(node.url, in: project.root)) {
                    walk(node.url, depth: depth + 1)
                } else if sameFile(node.url, fileURL) {
                    rows += outlineNavigation.visibleIndices.map { .heading($0, depth: depth + 1) }
                }
            }
        }
        walk(project.root, depth: 0)
        return rows
    }

    /// Paths can differ only by a symbolic link, such as /tmp and /private/tmp.
    func sameFile(_ url: URL, _ other: URL?) -> Bool {
        guard let other else {
            return false
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
            == other.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func relative(_ url: URL, in root: URL) -> String {
        (try? ProjectTree.relativePath(of: url, in: root)) ?? ""
    }
}

struct ProjectSidebar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var localization = AppLocalization.shared
    @State private var query = ""
    @State private var renaming: URL?
    @State private var draftName = ""
    @State private var targetFolder: URL?
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if workspace.project != nil {
                TextField(L10n.text("Search Files"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(Theme.editor.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                    .accessibilityIdentifier("sidebar.search")
            } else {
                HStack {
                    Text(L10n.text("Outline")).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                }.padding(.horizontal, 14).frame(height: 36)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // Rebuilt when files change on disk or the open file changes.
                    let _ = workspace.projectRevision
                    if let project = workspace.project, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(ProjectTree.search(query, in: project.root), id: \.id) { node in
                            fileRow(node, depth: 0, detail: workspace.relative(
                                node.url.deletingLastPathComponent(),
                                in: project.root,
                            ))
                        }
                    } else {
                        ForEach(workspace.sidebarRows) { row in
                            switch row {
                            case let .item(node, depth): fileRow(node, depth: depth)
                            case let .heading(index, depth): headingRow(index, depth: depth)
                            case let .more(_, count, depth): moreRow(count, depth: depth)
                            }
                        }
                        if workspace.project == nil, workspace.outline.isEmpty {
                            Text(L10n.text("Write your first heading with =")).font(.system(size: 11))
                                .foregroundStyle(Theme.muted).padding(14)
                        }
                    }
                }.padding(.horizontal, 6).padding(.vertical, 4)
            }
            if workspace.project != nil {
                Rectangle().fill(Theme.border).frame(height: 1)
                footer
            }
        }
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Menu {
                Button(L10n.text("New Typst File")) { create(folder: false) }
                Button(L10n.text("New Folder")) { create(folder: true) }
            } label: {
                PhosphorIcon(name: "plus", size: 14).foregroundStyle(Theme.secondary).frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("sidebar.add").accessibilityLabel(L10n.text("Add File or Folder"))
            Spacer()
            if let project = workspace.project {
                Text(project.name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    .truncationMode(.middle)
            }
        }.padding(.horizontal, 8).frame(height: 34)
    }

    private func create(folder: Bool) {
        guard let root = workspace.project?.root else {
            return
        }
        let directory = targetFolder.flatMap { workspace.project?.contains($0) == true ? $0 : nil } ?? root
        let name = folder ? ProjectTree.availableName(L10n.text("New Folder"), extension: nil, in: directory)
            : ProjectTree.availableName(L10n.text("Untitled"), extension: "typ", in: directory)
        if folder {
            workspace.createProjectFolder(in: directory, named: name)
        } else {
            workspace.createProjectFile(in: directory, named: name)
        }
        beginRename(directory.appendingPathComponent(name).standardizedFileURL)
    }

    private func beginRename(_ url: URL) {
        renaming = url
        draftName = url.lastPathComponent
        renameFocused = true
    }

    private func commitRename(_ url: URL) {
        let name = draftName
        renaming = nil
        if name != url.lastPathComponent {
            workspace.renameProjectItem(url, to: name)
        }
    }

    private func isOpen(_ node: ProjectNode) -> Bool {
        workspace.sameFile(node.url, workspace.fileURL)
    }

    private func fileRow(_ node: ProjectNode, depth: Int, detail: String? = nil) -> some View {
        let project = workspace.project
        let expanded = project.map { node.isDirectory && $0.expanded.contains(workspace.relative(
            node.url,
            in: $0.root,
        )) } ?? false
        let isMain = workspace.sameFile(node.url, project?.main)
        return HStack(spacing: 5) {
            if node.isDirectory {
                PhosphorIcon(name: "caret-right", size: 9)
                    .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            PhosphorIcon(name: icon(for: node, expanded: expanded), size: 14)
                .foregroundStyle(isOpen(node) ? Theme.accent : Theme.secondary)
            if renaming == node.url {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($renameFocused)
                    .onSubmit { commitRename(node.url) }
                    .onExitCommand { renaming = nil }
                    .accessibilityIdentifier("sidebar.rename")
            } else {
                Text(node.name).font(.system(size: 13, weight: isOpen(node) ? .medium : .regular))
                    .lineLimit(1).truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if isMain {
                PhosphorIcon(name: "push-pin", size: 11).foregroundStyle(Theme.muted)
                    .accessibilityLabel(L10n.text("Main Document"))
                    .learningHelp(L10n.text("Main Document"), detail: L10n.text(
                        "Preview and export always compile this file.",
                    ))
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, CGFloat(4 + depth * 14)).padding(.trailing, 6).frame(height: 26)
        .background(isOpen(node) ? Theme.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            targetFolder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            if node.isDirectory {
                workspace.toggleProjectFolder(node.url)
            } else {
                workspace.openProjectFile(node.url)
            }
        }
        .contextMenu {
            Button(L10n.text("Rename")) { beginRename(node.url) }
            Button(L10n.text("Reveal in Finder")) { workspace.revealProjectItem(node.url) }
            if node.isTypst, project?.canChangeMain == true, !isMain {
                Button(L10n.text("Set as Main Document")) { workspace.setMainEntry(node.url) }
            }
            Divider()
            Button(L10n.text("Move to Trash")) { workspace.trashProjectItem(node.url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isOpen(node) ? .isSelected : [])
        .accessibilityIdentifier("sidebar.row." + (project.map { workspace.relative(node.url, in: $0.root) } ?? node
                .name))
    }

    private func icon(for node: ProjectNode, expanded: Bool) -> String {
        if node.isDirectory {
            return expanded ? "folder-open" : "folder-simple"
        }
        switch node.url.pathExtension.lowercased() {
        case "typ": return "file-text"
        case "pdf": return "file-pdf"
        default: return "file"
        }
    }

    private func headingRow(_ index: Int, depth: Int) -> some View {
        let navigation = workspace.outlineNavigation
        let item = navigation.items[index]
        let current = workspace.activeOutlineIndex.map { navigation.visibleAncestor(of: $0) } == index
        let indent = depth * 14 + min(item.level - 1, 4) * 10
        return HStack(spacing: 3) {
            if navigation.branches.contains(index) {
                Button { workspace.toggleOutlineSection(index) } label: {
                    PhosphorIcon(name: "caret-right", size: 9)
                        .rotationEffect(.degrees(navigation.isExpanded(index) ? 90 : 0))
                        .frame(width: 14, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n
                        .text(navigation.isExpanded(index) ? "Collapse section" : "Expand section") + ": " + item.title)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Button { workspace.jump(to: item.offset) } label: {
                HStack(spacing: 0) {
                    Text(item.title).font(.system(size: 12, weight: current ? .medium : .regular)).lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }.frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(item.title)
                .accessibilityAddTraits(current ? .isSelected : [])
        }
        .foregroundStyle(current ? Theme.accent : Theme.secondary)
        .padding(.leading, CGFloat(4 + indent)).padding(.trailing, 6)
        .accessibilityIdentifier("sidebar.heading.\(index)")
    }

    private func moreRow(_ count: Int, depth: Int) -> some View {
        Text(L10n.format("%@ more items", String(count))).font(.system(size: 11)).foregroundStyle(Theme.muted)
            .padding(.leading, CGFloat(22 + depth * 14)).frame(height: 24)
    }
}
