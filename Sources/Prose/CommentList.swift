import AppKit
import ProseCore
import SwiftUI

/// All Comments in the command panel (Phase 8 decision 7), in the citation
/// picker's pattern: it shares the panel's query and selected row.
struct CommentList: Equatable {
    /// The command search to return to.
    var returnQuery = ""
}

/// One row of the list: a comment or a problem.
struct CommentListRow: Identifiable, Equatable {
    enum Section: Int, CaseIterable {
        case open
        case resolved
        case notAttached
        case problems

        var title: String {
            switch self {
            case .open: L10n.text("Open")
            case .resolved: L10n.text("Resolved")
            case .notAttached: L10n.text("Not attached")
            case .problems: L10n.text("Problems")
            }
        }
    }

    enum Target: Equatable {
        case comment(String)
        case problem(CommentIndex.Problem)
    }

    let id: String
    let section: Section
    let target: Target
    let author: String
    /// The first line of the first entry's text, or the problem's name.
    let text: String
    let replies: Int
    let state: String
    let location: Int

    /// The rows for `index` that match `query` by author or text: the open
    /// comments in document order, then Resolved, Not attached and Problems.
    static func rows(for index: CommentIndex, matching query: String) -> [Self] {
        var rows: [Self] = []
        for comment in index.comments where comment.state != .usedMoreThanOnce {
            let first = comment.entries.first
            let section: Section = comment.state == .notAttached ? .notAttached :
                (comment.isResolved ? .resolved : .open)
            let state = switch comment.state {
            case .damaged: L10n.text("Damaged")
            case .notAttached: L10n.text("Not attached")
            case .usedMoreThanOnce: L10n.text("Used more than once")
            case .attached: comment.isResolved ? L10n.text("Resolved") :
                (comment.anchor?.length == 0 ? L10n.text("Text deleted") : L10n.text("Open"))
            }
            rows.append(Self(
                id: comment.id,
                section: section,
                target: .comment(comment.id),
                author: first?.author ?? "",
                text: firstLine(first?.text ?? ""),
                replies: comment.replies.count,
                state: state,
                location: comment.location,
            ))
        }
        for (offset, problem) in index.problems.enumerated() {
            rows.append(Self(
                id: "problem.\(offset)",
                section: .problems,
                target: .problem(problem),
                author: problem.id ?? "",
                text: problemName(problem.kind),
                replies: 0,
                state: problemName(problem.kind),
                location: problem.ranges.first?.location ?? 0,
            ))
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return rows.filter { row in
            words.allSatisfy { row.author.lowercased().contains($0) || row.text.lowercased().contains($0) }
        }.sorted { ($0.section.rawValue, $0.location) < ($1.section.rawValue, $1.location) }
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }

    static func problemName(_ kind: CommentIndex.ProblemKind) -> String {
        switch kind {
        case .markersWithNoComment: L10n.text("Markers with no comment")
        case .usedMoreThanOnce: L10n.text("Used more than once")
        case .unreadableLine: L10n.text("Unreadable comment line")
        case .replyWithNoComment: L10n.text("Reply with no comment")
        case .newerFormat: L10n.text("Written by a newer Prose")
        case .notClosed: L10n.text("Not closed")
        }
    }

    /// The actions decision 3 gives the row.
    enum Action: Equatable {
        case attach
        case delete
        case removeMarkers
        case giveNewID
        case remove
    }

    func actions(in index: CommentIndex) -> [Action] {
        switch target {
        case let .comment(id):
            let comment = index.comment(id)
            let lost = comment?.state == .damaged || comment?.state == .notAttached || comment?.anchor?.length == 0
            return lost ? [.attach, .delete] : [.delete]
        case let .problem(problem):
            switch problem.kind {
            case .markersWithNoComment: return [.removeMarkers]
            case .usedMoreThanOnce: return [.giveNewID, .remove]
            case .replyWithNoComment: return [.remove]
            case .unreadableLine, .newerFormat, .notClosed: return []
            }
        }
    }
}

extension Workspace {
    /// All Comments: the list opens in the panel, which opens if it is closed.
    func openCommentList() {
        if !paletteOpen {
            togglePalette()
            guard paletteOpen else {
                return
            }
        }
        recordOperation("comments.list")
        commandError = nil
        activeCommand = nil
        citationPicker = nil
        commentList = CommentList(returnQuery: query)
        query = ""
        selectedCommandIndex = 0
    }

    /// The index of today's text for the list: the current one, or one
    /// built from a fresh parse.
    var commentListIndex: CommentIndex? {
        editor.flatMap { $0.comments.index(of: $0.string as NSString) }
    }

    var commentListRows: [CommentListRow] {
        commentListIndex.map { CommentListRow.rows(for: $0, matching: query) } ?? []
    }

    var highlightedCommentRow: CommentListRow? {
        let rows = commentListRows
        return rows.indices.contains(selectedCommandIndex) ? rows[selectedCommandIndex] : nil
    }

    func handleCommentListKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty || modifiers == .shift else {
            return false
        }
        switch event.keyCode {
        case 125:
            selectedCommandIndex = min(selectedCommandIndex + 1, max(0, commentListRows.count - 1))
            return true
        case 126:
            selectedCommandIndex = max(0, selectedCommandIndex - 1)
            return true
        case 36, 76:
            if let row = highlightedCommentRow {
                openCommentRow(row)
            }
            return true
        default:
            return false
        }
    }

    /// `Return` on a row: goes to the comment, or selects the problem's
    /// source.
    func openCommentRow(_ row: CommentListRow) {
        closePalette()
        switch row.target {
        case let .comment(id):
            if let editor, CommentOverlay.items(editor.comments).contains(where: { $0.id == id }) {
                goToComment(id)
            } else if let editor, let range = commentListIndex?.comment(id)?.entries.first?.range {
                editor.setSelectedRange(NSRange(location: range.location, length: 0))
                editor.reveal(NSRange(location: range.location, length: 0))
            }
        case let .problem(problem):
            if let editor, let range = problem.ranges.first {
                editor.setSelectedRange(range)
                editor.reveal(NSRange(location: range.location, length: 0))
            }
        }
    }

    /// An action button of the highlighted row.
    func performCommentRowAction(_ action: CommentListRow.Action, on row: CommentListRow) {
        let editable = editor?.isEditable
        // The panel makes the editor read-only; actions edit through it.
        editor?.isEditable = editorIsEditable || canEditSource
        defer { editor?.isEditable = editable ?? editorIsEditable }
        switch (action, row.target) {
        case let (.attach, .comment(id)): attachComment(id)
        case let (.delete, .comment(id)): deleteComment(id)
        case let (.removeMarkers, .problem(problem)):
            if let id = problem.id {
                removeCommentMarkers(id)
            }
        case let (.giveNewID, .problem(problem)):
            if let range = problem.ranges.first {
                giveCommentNewID(at: range)
            }
        case let (.remove, .problem(problem)):
            if let range = problem.ranges.first {
                removeCommentPart(at: range)
            }
        default: break
        }
        selectedCommandIndex = min(selectedCommandIndex, max(0, commentListRows.count - 1))
    }
}

/// The list inside the command panel.
struct CommentListPane: View {
    @ObservedObject var workspace: Workspace

    static let hint = L10n.text("↑ ↓ to select · ↵ to go to the comment · Esc to go back")

    var body: some View {
        let rows = workspace.commentListRows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text(workspace.query.isEmpty ? L10n.text("This document has no comments.") :
                            L10n.text("No matching comments"))
                            .font(.system(size: 12)).padding(16)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        if offset == 0 || rows[offset - 1].section != row.section {
                            Text(row.section.title).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.muted).padding(.top, offset == 0 ? 0 : 8).padding(.leading, 12)
                        }
                        CommentListRowView(row: row, selected: offset == workspace.selectedCommandIndex) {
                            workspace.selectedCommandIndex = offset
                            workspace.openCommentRow(row)
                        }.id(row.id)
                    }
                }.padding(.trailing, 16)
            }
            .onChange(of: workspace.selectedCommandIndex) { _, _ in
                if let row = workspace.highlightedCommentRow {
                    proxy.scrollTo(row.id)
                }
            }
        }
    }
}

private struct CommentListRowView: View {
    let row: CommentListRow
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Text(row.author.isEmpty ? "-" : row.author)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.tail).frame(width: 130, alignment: .leading)
                Text(row.text).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if row.replies > 0 {
                    Text(row.replies == 1 ? L10n.text("1 reply") : L10n.format("%d replies", row.replies))
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
                Text(row.state).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }.padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
                .background(
                    selected ? Theme.border.opacity(0.75) : (hovered ? Theme.border.opacity(0.35) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 5),
                )
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(Theme.accent).frame(width: 2, height: 16)
                    }
                }
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel(Text([row.author, row.text, row.state].filter { !$0.isEmpty }.joined(separator: ", ")))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The right column: the highlighted row's actions.
struct CommentListGuide: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let row = workspace.highlightedCommentRow
        let actions = row.flatMap { row in workspace.commentListIndex.map { row.actions(in: $0) } } ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                PhosphorIcon(name: "list-magnifying-glass", size: 19).foregroundStyle(Theme.accent)
                Text(L10n.text("All Comments")).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            if let row {
                Text(row.text).font(.system(size: 11)).lineLimit(4)
                Text(row.state).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                ForEach(actions, id: \.self) { action in
                    Button(Self.title(action)) { workspace.performCommentRowAction(action, on: row) }
                        .controlSize(.small)
                }
            } else {
                Text(L10n.text("Comments are stored in the file as Typst comments."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }
            Spacer(minLength: 0)
        }.padding(.top, 9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }

    static func title(_ action: CommentListRow.Action) -> String {
        switch action {
        case .attach: L10n.text("Attach to Selection")
        case .delete: L10n.text("Delete")
        case .removeMarkers: L10n.text("Remove Markers")
        case .giveNewID: L10n.text("Give a New Id")
        case .remove: L10n.text("Remove")
        }
    }
}
