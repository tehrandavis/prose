import AppKit
import ProseCore

/// The comment settings stored on this Mac and not synced (Phase 8
/// decisions 5 and 7).
enum CommentPreferences {
    static let showsCommentsKey = "showComments"
    static let showsResolvedKey = "showResolvedComments"
    static let authorKey = "commentAuthorName"

    static func showsComments(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsCommentsKey) as? Bool ?? true
    }

    static func showsResolvedComments(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsResolvedKey) as? Bool ?? false
    }

    static func set(_ value: Bool, for key: String, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }

    /// The setting as the writer typed it; the default is the macOS full name.
    static func authorName(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: authorKey) ?? NSFullUserName()
    }

    static func setAuthorName(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.set(name, forKey: authorKey)
    }

    /// The author written on a new entry: the setting, cleaned; when that
    /// is empty, the macOS full name; then "Author". Never holds a bar or a
    /// newline.
    static func author(setting: String, fullName: String = NSFullUserName()) -> String {
        CommentSyntax.author(setting) ?? CommentSyntax.author(fullName) ?? "Author"
    }
}

/// The comment actions (Phase 8 decision 7). Each command reaches the same
/// code from the `⌘J` panel, its menu item and its shortcut, through
/// `execute`. Every change to the source is one undo step made through
/// `ManuscriptTextView.applyCommentEdits`.
extension Workspace {
    /// The author of a new entry.
    var commentAuthor: String {
        CommentPreferences.author(setting: commentAuthorName)
    }

    private var commentOverlay: CommentOverlay? {
        editor?.commentOverlay
    }

    func executeComment(_ id: String) {
        recordOperation("comment.command", ["command": id])
        if id == "allComments" {
            openCommentList()
            return
        }
        if id == "showCommentsSidebar" {
            if paletteOpen {
                closePalette()
            }
            toggleCommentsSidebar()
            return
        }
        if paletteOpen {
            closePalette()
        }
        switch id {
        case "addComment": addComment()
        case "replyComment": focusReply()
        case "resolveComment": toggleResolve()
        case "deleteComment":
            if let active = activeCommentID {
                deleteComment(active)
            } else {
                showMessage(L10n.text("Put the caret in a comment's text first."))
            }
        case "nextComment": goToComment(forward: true)
        case "previousComment": goToComment(forward: false)
        case "showComments": showsComments.toggle()
        case "showResolvedComments": showsResolvedComments.toggle()
        case "showCommentSource": showCommentSource()
        default: break
        }
    }

    /// The active comment, not a draft.
    var activeCommentID: String? {
        editor?.comments.activeID.flatMap { $0 == CommentDraft.id ? nil : $0 }
    }

    // MARK: - Adding

    /// Add Comment: anchors the selection (a caret anchors the word at it)
    /// and opens a draft card with the keyboard in its field. Nothing is
    /// written until the writer posts it.
    func addComment() {
        guard canEditSource, let editor, !editor.hasMarkedText() else {
            return
        }
        if layout == .preview {
            layout = .split
        }
        let text = editor.string as NSString
        if editor.comments.index(of: text)?.isReadOnly == true {
            showMessage(Self.commentFailureText(.newerFormat))
            return
        }
        guard let tree = SyntaxTree(editor.string) else {
            showMessage(L10n.text("Prose cannot attach a comment to this selection"))
            return
        }
        switch CommentAnchoring.anchor(for: editor.selectedRange(), in: text, tree: tree) {
        case .failure(.noWord):
            // A caret with no word at it: nothing to anchor (decision 2).
            recordOperation("comment.refused", ["reason": "noWord"])
        case let .failure(reason):
            recordOperation("comment.refused", ["reason": String(describing: reason)])
            showMessage(L10n.text("Prose cannot attach a comment to this selection"))
        case let .success(anchor):
            if !showsComments {
                showsComments = true
            }
            editor.comments.openDraft(NSRange(location: anchor.start, length: anchor.end - anchor.start))
            guard let overlay = commentOverlay else {
                return
            }
            let model = overlay.model(for: CommentDraft.id)
            model.reset()
            model.requestFocus(.draft)
            overlay.refresh()
            if overlay.gutter == .icons, let icon = overlay.icons[CommentDraft.id] {
                overlay.showPopover(for: CommentDraft.id, relativeTo: icon)
            }
            recordOperation("comment.draft", ["start": String(anchor.start), "end": String(anchor.end)])
        }
    }

    /// Posts the draft as a new comment: the start marker, the end marker
    /// and the record, as one undo step. A draft with no text is not posted.
    func postDraft() {
        guard let editor, let draft = editor.comments.draft, let overlay = commentOverlay else {
            return
        }
        let model = overlay.model(for: CommentDraft.id)
        let body = model.draftText
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let text = editor.string as NSString
        guard let index = editor.comments.index(of: text), let tree = SyntaxTree(editor.string),
              case let .success(anchor) = CommentAnchoring.anchor(for: draft.range, in: text, tree: tree)
        else {
            showMessage(L10n.text("Prose cannot attach a comment to this selection"))
            return
        }
        var generator = SystemRandomNumberGenerator()
        let id = CommentSyntax.newID(avoiding: index.ids, using: &generator)
        let replacements: [TextReplacement]
        do {
            replacements = try CommentEdits.add(
                id: id,
                anchor: anchor,
                author: commentAuthor,
                date: commentClock(),
                text: body,
                index: index,
                source: text,
            )
        } catch {
            showCommentFailure(error)
            return
        }
        editor.comments.closeDraft(active: id)
        model.reset()
        overlay.closePopover()
        returnKeyboardToEditor()
        if editor.applyCommentEdits(replacements, actionName: L10n.text("Add Comment")) {
            recordOperation("comment.posted", ["id": id])
        }
    }

    /// `Esc` in the draft: nothing was written; the keyboard goes back to
    /// the editor.
    func cancelDraft() {
        guard let editor, editor.comments.draft != nil else {
            return
        }
        commentOverlay?.model(for: CommentDraft.id).reset()
        commentOverlay?.closePopover()
        editor.comments.closeDraft()
        returnKeyboardToEditor()
    }

    func returnKeyboardToEditor() {
        guard let editor, layout != .preview else {
            return
        }
        editor.window?.makeFirstResponder(editor)
    }

    // MARK: - Replies, edits, resolve, delete

    func postReply(to id: String) {
        guard let editor, let overlay = commentOverlay else {
            return
        }
        let model = overlay.model(for: id)
        let body = model.replyText
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let applied = applyComment(L10n.text("Reply to Comment")) { index, text in
            try CommentEdits.reply(
                to: id,
                author: commentAuthor,
                date: commentClock(),
                text: body,
                index: index,
                source: text,
            )
        }
        if applied {
            model.replyText = ""
            overlay.cardContentChanged(id)
            editor.comments.setActive(id)
        }
    }

    /// Edit in a card's menu: the entry's text becomes editable in the card.
    func beginEdit(_ id: String, entry: CommentIndex.Entry) {
        guard let overlay = commentOverlay else {
            return
        }
        let model = overlay.model(for: id)
        model.editing = entry
        model.editText = entry.text
        model.requestFocus(.edit)
        overlay.cardContentChanged(id)
    }

    func saveEdit(_ id: String) {
        guard let overlay = commentOverlay else {
            return
        }
        let model = overlay.model(for: id)
        guard let entry = model.editing else {
            return
        }
        let body = model.editText
        let applied = applyComment(L10n.text("Edit Comment")) { index, text in
            guard let current = Self.entry(matching: entry, of: id, in: index) else {
                throw CommentEdits.Failure.notFound
            }
            return try CommentEdits.edit(current, text: body, index: index, source: text)
        }
        if applied {
            model.editing = nil
            model.editText = ""
            overlay.cardContentChanged(id)
        }
    }

    /// The entry of comment `id` in `index` that `entry`, read from an
    /// earlier index, describes.
    static func entry(matching entry: CommentIndex.Entry, of id: String, in index: CommentIndex)
        -> CommentIndex.Entry?
    {
        let entries = index.comment(id)?.entries ?? []
        return entries.first { $0.range == entry.range && $0.text == entry.text } ?? entries.first {
            $0.kind == entry.kind && $0.author == entry.author && $0.date == entry.date && $0.text == entry.text
        }
    }

    /// Resolve or Reopen on the active comment.
    func toggleResolve() {
        guard let id = activeCommentID, let comment = editor?.comments.lastComments[id] else {
            showMessage(L10n.text("Put the caret in a comment's text first."))
            return
        }
        if comment.isResolved {
            reopenComment(id)
        } else {
            resolveComment(id)
        }
    }

    func resolveComment(_ id: String) {
        _ = applyComment(L10n.text("Resolve Comment")) { index, text in
            try CommentEdits.resolve(id, author: commentAuthor, date: commentClock(), index: index, source: text)
        }
    }

    func reopenComment(_ id: String) {
        _ = applyComment(L10n.text("Reopen Comment")) { index, text in
            try CommentEdits.reopen(id, index: index, source: text)
        }
    }

    func deleteComment(_ id: String) {
        if applyComment(L10n.text("Delete Comment"), { index, text in
            try CommentEdits.delete(id, index: index, source: text)
        }) {
            editor?.comments.setActive(nil)
            commentOverlay?.closePopover()
        }
    }

    func deleteReply(_ id: String, entry: CommentIndex.Entry) {
        _ = applyComment(L10n.text("Delete Reply")) { index, text in
            guard let current = Self.entry(matching: entry, of: id, in: index) else {
                throw CommentEdits.Failure.notFound
            }
            return try CommentEdits.deleteReply(current, index: index, source: text)
        }
    }

    /// Attach to Selection, for a damaged comment, one whose text was
    /// deleted or one not attached: new markers at the editor's selection.
    func attachComment(_ id: String) {
        guard let editor else {
            return
        }
        let selection = editor.selectedRange()
        let text = editor.string as NSString
        guard let tree = SyntaxTree(editor.string),
              case let .success(anchor) = CommentAnchoring.anchor(for: selection, in: text, tree: tree)
        else {
            showMessage(L10n.text("Prose cannot attach a comment to this selection"))
            return
        }
        _ = applyComment(L10n.text("Attach Comment")) { index, text in
            try CommentEdits.attach(id, anchor: anchor, index: index, source: text)
        }
    }

    /// Remove Markers, for markers with no comment.
    func removeCommentMarkers(_ id: String) {
        _ = applyComment(L10n.text("Remove Markers")) { index, text in
            try CommentEdits.removeMarkers(id, index: index, source: text)
        }
    }

    /// Remove, for one copy of an id used more than once or a reply with
    /// no comment.
    func removeCommentPart(at range: NSRange) {
        _ = applyComment(L10n.text("Remove")) { index, text in
            try CommentEdits.remove(at: range, index: index, source: text)
        }
    }

    /// Give a New Id, for one copy of an id used more than once.
    func giveCommentNewID(at range: NSRange) {
        _ = applyComment(L10n.text("Give a New Id")) { index, text in
            var generator = SystemRandomNumberGenerator()
            let id = CommentSyntax.newID(avoiding: index.ids, using: &generator)
            return try CommentEdits.giveNewID(id, at: range, index: index, source: text)
        }
    }

    /// Makes the replacements `make` returns for today's text and its index
    /// as one undo step named `name`. Returns whether it changed the source.
    @discardableResult
    func applyComment(
        _ name: String,
        _ make: (CommentIndex, NSString) throws -> [TextReplacement],
    ) -> Bool {
        guard canEditSource, let editor, !editor.hasMarkedText() else {
            return false
        }
        let text = editor.string as NSString
        guard let index = editor.comments.index(of: text) else {
            return false
        }
        let replacements: [TextReplacement]
        do {
            replacements = try make(index, text)
        } catch {
            showCommentFailure(error)
            return false
        }
        if editor.window?.firstResponder !== editor, commentOverlay?.containsFirstResponder == true {
            returnKeyboardToEditor()
        }
        let applied = editor.applyCommentEdits(replacements, actionName: name)
        if applied {
            recordOperation("comment.edited", ["action": name])
        }
        return applied
    }

    private func showCommentFailure(_ error: Error) {
        guard let failure = error as? CommentEdits.Failure else {
            showMessage(error.localizedDescription)
            return
        }
        if failure == .emptyText {
            return
        }
        showMessage(Self.commentFailureText(failure))
    }

    static func commentFailureText(_ failure: CommentEdits.Failure) -> String {
        switch failure {
        case .newerFormat:
            L10n.text("A newer version of Prose wrote the comments in this file. They cannot be changed here.")
        case .notFound, .invalidID: L10n.text("Prose cannot find this comment.")
        case .emptyText: L10n.text("Write the comment first.")
        case .textTooLong: L10n.text("A comment can hold at most 4,000 characters.")
        case .tooManyReplies: L10n.text("A comment can hold at most 200 replies.")
        }
    }

    // MARK: - Going to a comment

    /// A click on a card: the comment becomes active, and with `reveal`
    /// its anchor scrolls into view. The selection does not change.
    func activateComment(_ id: String, reveal: Bool) {
        guard let editor else {
            return
        }
        editor.comments.setActive(id)
        guard reveal, let item = CommentOverlay.items(editor.comments).first(where: { $0.id == id }) else {
            return
        }
        editor.reveal(NSRange(location: item.offset, length: 0))
    }

    /// Next Comment and Previous Comment: in document order from the
    /// caret, wrapping once at either end.
    func goToComment(forward: Bool) {
        guard let editor else {
            return
        }
        let items = CommentOverlay.items(editor.comments).filter { $0.kind != .draft }
        guard !items.isEmpty else {
            showMessage(L10n.text("This document has no comments to show."))
            return
        }
        let selection = editor.selectedRange()
        let target: CommentCardItem = if let active = activeCommentID,
                                         let current = items.firstIndex(where: { $0.id == active }),
                                         Self.selection(of: items[current]) == selection
        {
            items[(current + (forward ? 1 : items.count - 1)) % items.count]
        } else if forward {
            items.first { $0.offset > selection.location } ?? items[0]
        } else {
            items.last { $0.offset < selection.location } ?? items[items.count - 1]
        }
        goToComment(target.id)
    }

    /// The selection Next and Previous make for `item`: its anchor, or a
    /// caret at its marker when no text is left.
    static func selection(of item: CommentCardItem) -> NSRange {
        item.anchor.length > 0 ? item.anchor : NSRange(location: item.offset, length: 0)
    }

    /// Selects comment `id`'s anchor as a pointer selection, so a rendered
    /// block stays typeset, makes it active and scrolls its first line into
    /// view: to the typewriter line in Focus mode.
    func goToComment(_ id: String) {
        guard let editor, let item = CommentOverlay.items(editor.comments).first(where: { $0.id == id }) else {
            return
        }
        if layout == .preview {
            layout = .split
        }
        let range = Self.selection(of: item)
        editor.window?.makeFirstResponder(editor)
        editor.selectingWithMouse = true
        editor.setSelectedRange(range)
        editor.selectingWithMouse = false
        editor.selectionChanged(byPointer: true, anchor: range.location)
        selection = editor.selectedRange()
        editor.comments.setActive(id)
        if editor.writing.focused {
            let line = WritingController.typewriterFraction * editor.containerVisibleRect().height
            editor.writing.placeCaretLine(range.location, at: line)
        } else {
            editor.reveal(NSRange(location: range.location, length: 0))
        }
        commentOverlay?.refresh()
        recordOperation("comment.visited", ["id": id])
    }

    /// Reply: the keyboard goes to the active card's Reply field.
    func focusReply() {
        guard let id = activeCommentID, let overlay = commentOverlay else {
            showMessage(L10n.text("Put the caret in a comment's text first."))
            return
        }
        activateComment(id, reveal: true)
        overlay.model(for: id).requestFocus(.reply)
        overlay.refresh()
        if overlay.gutter == .icons, let icon = overlay.icons[id] {
            overlay.showPopover(for: id, relativeTo: icon)
        }
    }

    /// Show Comment Source: the store's fold opens with the caret in it.
    func showCommentSource() {
        guard let editor, let store = editor.comments.store else {
            showMessage(L10n.text("This document has no comments."))
            return
        }
        if layout == .preview {
            layout = .split
        }
        editor.window?.makeFirstResponder(editor)
        let caret = NSRange(location: NSMaxRange(store), length: 0)
        editor.setSelectedRange(caret)
        selection = caret
        editor.reveal(caret)
    }
}
