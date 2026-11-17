import AppKit
import ProseCore
import SwiftUI

/// The open file's comments as the sidebar's Comments view lists them. It
/// is rebuilt from the comment index after each change the overlay sees, in
/// a later turn of the run loop, and publishes only when something changed.
/// The rows come from `CommentListRow`, the model of All Comments.
@MainActor
final class CommentSidebarModel: ObservableObject {
    @Published private(set) var rows: [CommentListRow] = []
    /// The active comment, not a draft.
    @Published private(set) var activeID: String?
    private var scheduled = false

    /// The open comments, for the count on the Comments segment.
    var openCount: Int {
        rows.count { $0.section == .open }
    }

    func set(rows: [CommentListRow]?, activeID: String?) {
        if let rows, rows != self.rows {
            self.rows = rows
        }
        if activeID != self.activeID {
            self.activeID = activeID
        }
    }

    /// Runs `update` once in a later turn, however often it is asked for:
    /// the request can come during a view update.
    func schedule(_ update: @escaping @MainActor () -> Void) {
        guard !scheduled else {
            return
        }
        scheduled = true
        Task { @MainActor [weak self] in
            self?.scheduled = false
            update()
        }
    }
}

extension Workspace {
    /// The comments or the active comment changed: the sidebar's list
    /// follows.
    func commentsDidChange() {
        commentSidebar.schedule { [weak self] in
            self?.refreshCommentSidebar()
        }
    }

    func refreshCommentSidebar() {
        guard let editor, !isLibraryHome else {
            commentSidebar.set(rows: [], activeID: nil)
            return
        }
        let comments = editor.comments
        guard let snapshot = comments.snapshot else {
            // A file was opened and its index is on its way.
            commentSidebar.set(rows: [], activeID: nil)
            return
        }
        // While an index is on its way the rows keep the last one's.
        let rows = comments.isCurrent
            ? CommentListRow.rows(for: snapshot.index, source: editor.string as NSString) : nil
        commentSidebar.set(rows: rows, activeID: activeCommentID)
    }

    /// Show Comments in Sidebar: the sidebar switches between its files and
    /// the comments. A hidden sidebar opens at the comments, except in
    /// Focus mode, which keeps it hidden.
    func toggleCommentsSidebar() {
        if !sidebarVisible, editorMode != .focus {
            sidebarVisible = true
            sidebarShowsComments = true
        } else {
            sidebarShowsComments.toggle()
        }
        recordOperation("comments.sidebar", ["shown": String(sidebarShowsComments)])
    }

    /// A click on a row of the sidebar's list: what a click on a card and
    /// the list's Return do. The comment becomes active and its anchor
    /// scrolls into view; the editor keeps the keyboard.
    func openSidebarComment(_ row: CommentListRow) {
        // A click opens the comment, so its card must be able to show: turn
        // comments on, and resolved comments too when the row is resolved.
        if case let .comment(id) = row.target, let comment = commentListIndex?.comment(id) {
            var changed = false
            if !showsComments {
                showsComments = true
                changed = true
            }
            if !comment.resolutions.isEmpty, !showsResolvedComments {
                showsResolvedComments = true
                changed = true
            }
            if changed {
                returnKeyboardToEditor()
                // The margin takes the new setting in this turn of the run
                // loop; go to the comment in the next one.
                DispatchQueue.main.async { [weak self] in
                    self?.showCommentRow(row)
                }
                return
            }
        }
        if case let .comment(id) = row.target, let editor,
           !CommentOverlay.items(editor.comments).contains(where: { $0.id == id && $0.kind != .draft }),
           let anchor = commentListIndex?.comment(id)?.anchor, anchor.length > 0
        {
            // A comment the margin does not show, such as a resolved one
            // while resolved comments are hidden: select its words.
            if layout == .preview {
                layout = .split
            }
            returnKeyboardToEditor()
            editor.setSelectedRange(anchor)
            selection = editor.selectedRange()
            editor.reveal(NSRange(location: anchor.location, length: 0))
            return
        }
        returnKeyboardToEditor()
        showCommentRow(row)
    }
}

/// The two segments at the top of the sidebar: the files (or the outline
/// of a file with no folder) and the comments, with the number of open
/// comments.
struct SidebarModeControl: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var comments: CommentSidebarModel

    var body: some View {
        let filesTitle = workspace.project == nil ? L10n.text("Outline") : L10n.text("Files")
        HStack(spacing: 2) {
            segment(
                filesTitle,
                icon: workspace.project == nil ? "list-bullets" : "files",
                count: 0,
                selected: !workspace.sidebarShowsComments,
                identifier: "sidebar.mode.files",
            ) { workspace.sidebarShowsComments = false }
            segment(
                L10n.text("Comments"),
                icon: "chat-circle",
                count: comments.openCount,
                selected: workspace.sidebarShowsComments,
                identifier: "sidebar.mode.comments",
            ) { workspace.sidebarShowsComments = true }
        }
        .padding(2)
        .background(Theme.editor.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }

    private func segment(
        _ title: String,
        icon: String,
        count: Int,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                PhosphorIcon(name: icon, size: 12)
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                if count > 0 {
                    Text(String(count)).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(selected ? Theme.accent : Theme.muted)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondary)
            .frame(maxWidth: .infinity).frame(height: 22)
            .background(selected ? Theme.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? L10n.format("%@, %@ open", title, String(count)) : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The sidebar's Comments view: the open file's comments in document order,
/// then Resolved (collapsed until opened), Not attached and Problems.
struct CommentSidebarList: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: CommentSidebarModel
    @ObservedObject var hover: RowHover
    let query: String
    @State private var showsResolved = false

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = CommentListRow.filter(model.rows, matching: query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if rows.isEmpty {
                    empty(searching: searching)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    if offset == 0 || rows[offset - 1].section != row.section {
                        header(row.section, count: rows.count { $0.section == row.section }, searching: searching)
                            .padding(.top, offset == 0 ? 0 : 8)
                    }
                    if row.section != .resolved || showsResolved || searching {
                        CommentSidebarRow(
                            row: row,
                            active: row.target == .comment(model.activeID ?? ""),
                            hover: hover,
                            open: { workspace.openSidebarComment(row) },
                            resolve: { workspace.resolveComment(row.id) },
                        )
                    }
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
        }
        .accessibilityIdentifier("sidebar.comments")
    }

    private func empty(searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(searching ? L10n.text("No matching comments") : L10n.text("No comments"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            if !searching {
                Text(L10n.text("Select some text, then press ⌘⌥M to add a comment."))
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 8).padding(.vertical, 10)
    }

    @ViewBuilder private func header(_ section: CommentListRow.Section, count: Int, searching: Bool) -> some View {
        if section == .resolved, !searching {
            Button { showsResolved.toggle() } label: {
                HStack(spacing: 4) {
                    PhosphorIcon(name: "caret-right", size: 9)
                        .rotationEffect(.degrees(showsResolved ? 90 : 0)).frame(width: 12)
                    headerText(section, count: count)
                    Spacer(minLength: 0)
                }.frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 4)
                .accessibilityLabel(L10n.format(
                    showsResolved ? "Hide %@ resolved comments" : "Show %@ resolved comments",
                    String(count),
                ))
                .accessibilityIdentifier("sidebar.comments.resolved")
        } else if section != .open || searching {
            HStack { headerText(section, count: count) }.padding(.horizontal, 8).frame(height: 24)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func headerText(_ section: CommentListRow.Section, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(section.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(String(count)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.muted)
        }
    }
}

/// One comment in the sidebar: the author and a short date, the text, a
/// quote of the commented words and the number of replies. On hover, an
/// open comment shows a Resolve button.
private struct CommentSidebarRow: View {
    let row: CommentListRow
    let active: Bool
    @ObservedObject var hover: RowHover
    let open: () -> Void
    let resolve: () -> Void

    private var rowID: String {
        "comment:" + row.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.author.isEmpty ? "-" : row.author)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    if !row.date.isEmpty {
                        Text(CommentDate.text(row.date)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            .lineLimit(1).layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                }
                Text(row.text).font(.system(size: 12)).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.quote.isEmpty {
                    Text("“" + row.quote + "”").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                detail
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityAction { open() }
            if row.section == .open, hover.id == rowID {
                Button(action: resolve) {
                    PhosphorIcon(name: "check-circle", size: 14).foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                }.buttonStyle(QuietControlStyle())
                    .accessibilityLabel(L10n.text("Resolve"))
                    .learningHelp(L10n.text("Resolve"))
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .openRow(rowID, hover: hover, selected: active)
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sidebar.comment." + row.id)
    }

    @ViewBuilder private var detail: some View {
        let replies = row.replies == 0 ? nil : (row.replies == 1 ? L10n.text("1 reply") :
            L10n.format("%d replies", row.replies))
        // The state only when the section's title or the text does not say it.
        let state = row.state == row.section.title || row.state == row.text ? nil : row.state
        let parts = [replies, state].compactMap(\.self)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
}
