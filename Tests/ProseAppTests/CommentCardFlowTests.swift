import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 8 step D: cards and actions, acceptance tests 14 to 20 of the
/// comments note, on the real window, editor and engine. Numbers are
/// printed with the prefix `CARDS`. Every UI test also checks that the
/// storage holds only the source, that TextKit 2 is still on, and that the
/// undo stack is unchanged unless the test edits.
extension WritingFlowTests {
    /// Acceptance test 14: Add Comment on a selection inside a rendered
    /// paragraph, with text posted, puts the start marker, the end marker
    /// and a record in the source as one undo step. One undo removes all
    /// three and leaves the caret at the anchor, not in the store; one redo
    /// returns them. The `⌘J` path, the shortcut's command and the toolbar
    /// run the same code.
    @Test func commentsAcceptance14AddCommentPostsOneUndoStep() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, manager) = try await openCards(app)
        let workspace = app.workspace
        workspace.commentClock = { Date(timeIntervalSince1970: 1_800_000_000) }
        workspace.commentAuthorName = "Ada Park"
        let original = editor.string
        let text = original as NSString
        let block = text.range(of: "A last paragraph").location
        let words = NSRange(location: text.range(of: "comment on later").location, length: 10)
        #expect(renderedBlock(manager, at: block) != nil)
        pointerSelect(editor, words)

        // The command and its shortcut.
        let add = try #require(WritingCommand.all.first { $0.id == "addComment" })
        #expect(add.keyPath == "k a")
        #expect(add.shortcuts == [DirectShortcut("m", modifiers: [.command, .option])])

        // The `⌘J` path: k, then a.
        workspace.togglePalette()
        #expect(workspace.handlePaletteKey(app.key("k", code: 40)))
        #expect(workspace.paletteGroup == "comments")
        #expect(workspace.handlePaletteKey(app.key("a", code: 0)))
        #expect(!workspace.paletteOpen)
        let draft = try #require(editor.comments.draft)
        #expect(draft.range == words)
        #expect(editor.string == original, "A draft writes nothing")
        #expect(editor.comments.highlights.contains { $0.id == CommentDraft.id && $0.range == words })
        #expect(renderedBlock(manager, at: block) != nil, "The block stays typeset")
        try await app.wait { overlay.cards[CommentDraft.id]?.containsFirstResponder == true }
        let field = try #require(commentField(overlay, CommentDraft.id))

        // The draft's range follows an edit before it.
        editor.insertText("New ", replacementRange: NSRange(location: block, length: 0))
        #expect(
            editor.comments.draft?.range == NSRange(location: words.location + 4, length: words.length),
            "The draft is at \(String(describing: editor.comments.draft)); the text grew by \((editor.string as NSString).length - text.length)",
        )
        editor.undoManager?.undo()
        #expect(editor.string == original)
        #expect(editor.comments.draft?.range == words)
        pointerSelect(editor, words)
        let undoBefore = CardUndo(editor)
        app.window.makeFirstResponder(field)

        // An empty draft is not posted.
        #expect(field.performKeyEquivalent(with: app.key("\r", code: 36, modifiers: .command)))
        #expect(editor.string == original && editor.comments.draft != nil)

        // Typing in the field, then `⌘Return`.
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        fieldEditor.insertText("Is this the right phrase?", replacementRange: NSRange(location: 0, length: 0))
        #expect(overlay.model(for: CommentDraft.id).draftText == "Is this the right phrase?")
        #expect(field.performKeyEquivalent(with: app.key("\r", code: 36, modifiers: .command)))
        #expect(editor.comments.draft == nil)
        #expect(app.window.firstResponder === editor, "The keyboard goes back to the editor")
        let posted = editor.string
        try await app.wait { editor.comments.isCurrent }
        let comment = try #require(editor.comments.comments
            .first { $0.entries.first?.text == "Is this the right phrase?" })
        let markers = try (#require(comment.startMarker), #require(comment.endMarker))
        #expect(comment.anchor == NSRange(location: words.location + CommentSyntax.markerLength, length: words.length))
        #expect(comment.entries.first?.author == "Ada Park")
        #expect(comment.entries.first?.date == CommentSyntax.timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        #expect((posted as NSString).substring(with: markers.0) == CommentSyntax.startMarker(comment.id))
        #expect((posted as NSString).substring(with: markers.1) == CommentSyntax.endMarker(comment.id))
        #expect(editor.comments.activeID == comment.id)
        #expect(editor.undoManager?.undoActionName == "Add Comment")
        #expect(CardUndo(editor) != undoBefore)

        // One undo removes all three, the caret back at the anchor; the
        // store's fold stays closed. One redo returns them.
        editor.undoManager?.undo()
        #expect(editor.string == original)
        #expect(editor.selectedRange() == words, "The undo leaves the selection at the anchor")
        await app.layout()
        if let store = editor.comments.store, let fold = editor.writing.model?.fold(holding: store.location) {
            #expect(!fold.isOpen, "The undo opened the store")
        }
        editor.undoManager?.redo()
        #expect(editor.string == posted)
        let store = (posted as NSString).range(of: "// prose:comments").location
        #expect(editor.selectedRange().location < store, "The redo leaves the caret out of the store")
        editor.undoManager?.undo()
        #expect(editor.string == original)

        // A refusal: a selection of blank text.
        let blank = text.range(of: "\n\nA paragraph with")
        editor.setSelectedRange(NSRange(location: blank.location, length: 2))
        workspace.executeComment("addComment")
        #expect(editor.comments.draft == nil)
        #expect(workspace.message == "Prose cannot attach a comment to this selection")
        #expect(editor.string == original)
        await app.layout()
        expectPlainStorage(editor)
    }

    /// Acceptance test 15: three comments whose anchors are on one line
    /// draw three cards that do not overlap, in document order. The active
    /// card is level with its anchor, and the others move away.
    @Test func commentsAcceptance15CardsOnOneLineStackWithoutOverlap() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, manager) = try await openCards(app)
        let undo = CardUndo(editor)
        let ids = ["aa2bcd", "bb3cde", "cc4def"]
        try await app.wait { ids.allSatisfy { overlay.cards[$0] != nil } }
        #expect(overlay.gutter.showsCards)
        func frames() throws -> [NSRect] {
            try ids.map { try #require(overlay.cards[$0]?.frame, "No card for \($0)") }
        }
        func expectStacked(_ label: String) throws {
            let frames = try frames()
            for (upper, lower) in zip(frames, frames.dropFirst()) {
                #expect(upper.maxY + CommentOverlay.spacing <= lower.minY + 0.5, "\(label): \(upper) overlaps \(lower)")
            }
            #expect(frames.allSatisfy { $0.width == CommentOverlay.cardWidth })
        }
        try expectStacked("no active card")
        // All three anchors are on the first drawn line of one rendered block.
        let block = (editor.string as NSString).range(of: "The ").location
        let shown = try #require(renderedBlock(manager, at: block))
        let tops = try ids.map { id in
            let anchor = try #require(editor.comments.placed.first { $0.id == id }).anchor
            return try #require(editor.writing.firstDrawnRect(of: anchor)).rect.minY
        }
        #expect(Set(tops.map { Int($0.rounded()) }).count == 1, "The anchors are on one line: \(tops)")
        let firstGlyph = try #require(glyphBoxes(shown)
            .first { $0.offset == editor.comments.placed[0].anchor.location })
        #expect(
            abs(firstGlyph.box.minY - tops[0]) < 12,
            "The line's top \(tops[0]) is near its glyph \(firstGlyph.box)",
        )
        func overlayY(_ containerY: CGFloat) -> CGFloat {
            overlay.convert(NSPoint(x: 0, y: containerY + editor.textContainerOrigin.y), from: editor).y
        }
        // With none active, the first card is level with the line.
        #expect(try abs(frames()[0].minY - overlayY(tops[0])) <= 1)

        // The middle one active: level with its anchor; the first moves up.
        app.workspace.activateComment("bb3cde", reveal: false)
        overlay.refresh()
        try expectStacked("middle active")
        let active = try frames()
        #expect(abs(active[1].minY - overlayY(tops[1])) <= 1, "The active card \(active[1]) is not level")
        #expect(active[0].minY < overlayY(tops[0]) - 1, "The card above did not move away")
        #expect(overlay.model(for: "bb3cde").isActive)
        #expect(editor.comments.highlights.first { $0.id == "bb3cde" }?.strength == .active)
        #expect(editor.comments.highlights.first { $0.id == "aa2bcd" }?.strength == .normal)
        print("CARDS stacked: \(active.map { Int($0.minY) }) for anchors at \(Int(overlayY(tops[0])))")

        // A click in an anchor makes that comment active.
        let third = try #require(editor.comments.placed.first { $0.id == "cc4def" }).anchor
        try writingPress(editor, at: glyphCentre(manager, block: block, offset: third.location + 1))
        #expect(editor.comments.activeID == "cc4def")
        await app.layout()
        overlay.refresh()
        try expectStacked("third active")

        // The cards move with a scroll in the same turn.
        let before = try frames()
        let clip = try #require(editor.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 20))
        let after = try frames()
        #expect(zip(before, after).allSatisfy { abs($0.minY - 20 - $1.minY) <= 1 }, "\(before) then \(after)")
        clip.scroll(to: .zero)
        #expect(CardUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 16: reply, edit, resolve, reopen and delete each
    /// change only records (delete also the start marker and the end
    /// marker), each as one undo step, and the card follows.
    @Test func commentsAcceptance16EachActionChangesOnlyRecordsAsOneStep() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, _) = try await openCards(app)
        let workspace = app.workspace
        workspace.commentClock = { Date(timeIntervalSince1970: 1_800_000_000) }
        let id = "dd5efg"
        let model = overlay.model(for: id)
        func storeStart() -> Int {
            (editor.string as NSString).range(of: "// prose:comments").location
        }
        // Runs `action` and checks what changed: the text before the store
        // is the same unless markers go too, one undo restores it, one redo
        // returns it.
        func step(_ name: String, markers: Bool = false, _ action: () -> Void) async throws -> String {
            let before = editor.string
            let body = (before as NSString).substring(to: storeStart())
            action()
            let after = editor.string
            #expect(after != before, "\(name) changed nothing")
            #expect(editor.undoManager?.undoActionName == name)
            let bodyAfter = (after as NSString).substring(to: storeStart())
            if markers {
                #expect(bodyAfter == body.replacingOccurrences(of: CommentSyntax.startMarker(id), with: "")
                    .replacingOccurrences(of: CommentSyntax.endMarker(id), with: ""))
            } else {
                #expect(bodyAfter == body, "\(name) changed text outside the store")
            }
            editor.undoManager?.undo()
            #expect(editor.string == before, "One undo of \(name)")
            editor.undoManager?.redo()
            #expect(editor.string == after, "One redo of \(name)")
            try await app.wait { editor.comments.isCurrent }
            overlay.refresh()
            return after
        }
        try await app.wait { overlay.cards[id] != nil }
        workspace.activateComment(id, reveal: false)
        overlay.refresh()
        #expect(model.isActive && model.comment?.replies.count == 1)

        // Reply.
        model.replyText = "A second reply."
        _ = try await step("Reply to Comment") { workspace.postReply(to: id) }
        #expect(model.replyText.isEmpty)
        #expect(model.comment?.replies.map(\.text) == ["A reply.", "A second reply."])

        // Edit the first reply.
        let reply = try #require(model.comment?.replies.first)
        workspace.beginEdit(id, entry: reply)
        #expect(model.editing == reply && model.editText == "A reply.")
        model.editText = "An edited reply."
        _ = try await step("Edit Comment") { workspace.saveEdit(id) }
        #expect(model.editing == nil)
        #expect(model.comment?.replies.first?.text == "An edited reply.")

        // Delete the second reply.
        let second = try #require(model.comment?.replies.last)
        _ = try await step("Delete Reply") { workspace.deleteReply(id, entry: second) }
        #expect(model.comment?.replies.count == 1)

        // Resolve: the card goes while resolved comments are hidden, and
        // comes back with Reopen when they are shown.
        _ = try await step("Resolve Comment") { workspace.executeComment("resolveComment") }
        #expect(editor.comments.lastComments[id]?.isResolved == true)
        #expect(overlay.cards[id] == nil)
        #expect(!editor.comments.highlights.contains { $0.id == id })
        workspace.showsResolvedComments = true
        overlay.refresh()
        #expect(overlay.cards[id] != nil)
        #expect(editor.comments.resolvedUnderlines.count == 1)
        let underline = try #require(editor.comments.resolvedUnderlines.first)
        #expect(!editor.resolvedUnderlineRects(of: underline).isEmpty)
        workspace.activateComment(id, reveal: false)
        _ = try await step("Reopen Comment") { workspace.executeComment("resolveComment") }
        #expect(editor.comments.lastComments[id]?.isResolved == false)
        workspace.showsResolvedComments = false

        // Delete: the markers and every record go.
        workspace.activateComment(id, reveal: false)
        let deleted = try await step("Delete Comment", markers: true) { workspace.executeComment("deleteComment") }
        #expect(!deleted.contains(id))
        #expect(overlay.cards[id] == nil)
        expectPlainStorage(editor)
    }

    /// Acceptance test 17: with the pane wide, the column is centred and the
    /// gutter shows. Narrower, the column moves left and its width is
    /// unchanged. Narrower still, with the preview open, icons replace the
    /// cards and a click opens a popover. No block renders again because
    /// of the gutter in any of the three.
    @Test func commentsAcceptance17TheGutterHasThreeLayouts() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, _) = try await openCards(app, width: 1900)
        let undo = CardUndo(editor)
        let model = try #require(editor.writing.model)
        // Turns the comments off and on at this width: the gutter comes
        // and goes, and nothing renders or lays out the document again.
        func expectNoRender(_ label: String) async throws -> (shift: CGFloat, width: CGFloat) {
            await model.idle()
            await app.layout()
            let renders = model.renderReplies
            let built = SourceStyler.paragraphsBuilt
            let width = try #require(editor.textContainer?.size.width)
            let shown = overlay.gutter
            app.workspace.showsComments = false
            overlay.refresh()
            await app.layout()
            #expect(overlay.gutter == .hidden && editor.commentColumnShift == 0, "\(label): hidden")
            let centredX = editor.textContainerOrigin.x
            app.workspace.showsComments = true
            overlay.refresh()
            await app.layout()
            await model.idle()
            #expect(overlay.gutter == shown, "\(label): the layout is the same again")
            #expect(editor.textContainer?.size.width == width, "\(label): the column's width changed")
            #expect(model.renderReplies == renders, "\(label): \(model.renderReplies - renders) blocks rendered")
            let paragraphs = SourceStyler.paragraphsBuilt - built
            print("CARDS \(label): gutter \(shown), paragraphs built \(paragraphs), renders 0")
            #expect(paragraphs < 20, "\(label): \(paragraphs) paragraphs built")
            return (centredX - editor.textContainerOrigin.x, width)
        }

        // Wide: centred, with cards.
        #expect(overlay.gutter == .centred)
        let wide = try await expectNoRender("wide")
        #expect(wide.shift == 0)
        #expect(!overlay.cards.isEmpty && overlay.icons.isEmpty)

        // Narrower: the column moves left, its width the same.
        app.window.setContentSize(NSSize(width: 1220, height: 820))
        await app.layout()
        try await app.wait {
            if case .shifted = overlay.gutter {
                true
            } else {
                false
            }
        }
        let narrow = try await expectNoRender("narrower")
        #expect(narrow.shift == overlay.gutter.shift && narrow.shift > 0)
        let column = editor.textContainerOrigin.x
        #expect(column >= ManuscriptLayout.minimumInset - 0.5, "The column \(column)")
        #expect(!overlay.cards.isEmpty)
        let card = try #require(overlay.cards.values.first)
        let right = overlay.convert(NSPoint(x: column + narrow.width, y: 0), from: editor).x
        #expect(card.frame.minX >= right + CommentGutter.gap - 0.5, "The card \(card.frame) overlaps the column")
        #expect(card.frame.maxX <= overlay.bounds.maxX + 0.5)

        // Narrower still, the preview open: icons and a popover.
        app.workspace.layout = .split
        await app.layout()
        try await app.wait { overlay.gutter == .icons }
        _ = try await expectNoRender("preview open")
        #expect(overlay.cards.isEmpty && !overlay.icons.isEmpty)
        #expect(editor.commentColumnShift == 0)
        let icon = try #require(overlay.icons["aa2bcd"])
        #expect(icon.accessibilityRole() == .button && icon.accessibilityLabel() == "Comment by Ada Park")
        #expect(!icon.acceptsFirstResponder)
        #expect(icon.accessibilityPerformPress())
        #expect(overlay.popoverID == "aa2bcd" && overlay.popover?.isShown == true)
        #expect(editor.comments.activeID == "aa2bcd")
        overlay.closePopover()
        // The highlight stays.
        #expect(editor.comments.highlights.contains { $0.id == "aa2bcd" })
        #expect(CardUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 18: in Focus, only the focus block's comments show
    /// cards, and the other comments' icons and highlights draw at 45
    /// percent. Cards do not fade while the writer types.
    @Test func commentsAcceptance18FocusShowsCardsForTheFocusBlockOnly() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, manager) = try await openCards(app)
        let undo = CardUndo(editor)
        let text = editor.string as NSString
        // The caret in the second paragraph, which holds dd5efg.
        let second = text.range(of: "A second paragraph").location
        editor.setSelectedRange(NSRange(location: second + 3, length: 0))
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.focusSpans != nil }
        await editor.writing.model?.idle()
        await app.layout()
        overlay.refresh()
        try await app.wait {
            overlay.refresh()
            return overlay.cards["dd5efg"] != nil && overlay.icons["aa2bcd"] != nil
        }
        #expect(overlay.gutter.showsCards, "Focus has room for the gutter: \(overlay.gutter)")
        for id in ["aa2bcd", "bb3cde", "cc4def"] {
            #expect(overlay.cards[id] == nil, "\(id) is outside the focus block and has a card")
            let icon = try #require(overlay.icons[id])
            #expect(abs(icon.alphaValue - WritingFocus.dimmedAlpha) < 0.001 && icon.dimmed)
        }
        let card = try #require(overlay.cards["dd5efg"])
        #expect(card.alphaValue == 1)
        // The other comments' highlight dims with their block.
        let first = text.range(of: "The ").location
        let block = try #require(writingFragments(manager).first { $0.offset == first })
        #expect(block.fragment?.dimmed == true)
        // Typing does not fade the cards.
        editor.insertText("x", replacementRange: NSRange(location: second + 3, length: 0))
        await app.layout()
        overlay.refresh()
        #expect(overlay.cards["dd5efg"]?.alphaValue == 1)
        editor.undoManager?.undo()
        // A click on a dimmed icon goes to its comment.
        let icon = try #require(overlay.icons["aa2bcd"])
        #expect(icon.accessibilityPerformPress())
        #expect(editor.comments.activeID == "aa2bcd")
        let anchor = try #require(editor.comments.placed.first { $0.id == "aa2bcd" }).anchor
        #expect(editor.selectedRange() == anchor)
        try await app.wait {
            overlay.refresh()
            return overlay.cards["aa2bcd"] != nil
        }
        app.workspace.setMode(.writing)
        try await app.wait { !editor.writing.focused }
        // The test typed one character and took it back.
        #expect(CardUndo(editor).canUndo == undo.canUndo && editor.string == text as String)
        expectPlainStorage(editor)
    }

    /// Acceptance test 19: Next Comment and Previous Comment visit every
    /// comment in document order and wrap. The block stays rendered.
    @Test func commentsAcceptance19NextAndPreviousVisitEveryCommentAndWrap() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, manager) = try await openCards(app)
        let undo = CardUndo(editor)
        let next = try #require(WritingCommand.all.first { $0.id == "nextComment" })
        let previous = try #require(WritingCommand.all.first { $0.id == "previousComment" })
        #expect(next.shortcuts == [DirectShortcut("n", modifiers: [.control, .option])])
        #expect(previous.shortcuts == [DirectShortcut("p", modifiers: [.control, .option])])
        let order = ["aa2bcd", "bb3cde", "cc4def", "dd5efg"]
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        var visited: [String] = []
        for _ in 0 ..< 5 {
            app.workspace.execute(next)
            let active = try #require(editor.comments.activeID)
            visited.append(active)
            let anchor = try #require(editor.comments.placed.first { $0.id == active }).anchor
            #expect(editor.selectedRange() == anchor)
            #expect(editor.writing.pointerSelection == anchor, "Next makes a pointer selection")
            await app.layout()
            let paragraph = (editor.string as NSString).paragraphRange(for: anchor)
            let shown = renderedBlock(manager, at: paragraph.location)
            #expect(shown != nil, "The block of \(active) is not rendered")
        }
        #expect(visited == order + ["aa2bcd"], "Next: \(visited)")
        visited = []
        for _ in 0 ..< 5 {
            app.workspace.execute(previous)
            try visited.append(#require(editor.comments.activeID))
        }
        #expect(visited == ["dd5efg", "cc4def", "bb3cde", "aa2bcd", "dd5efg"], "Previous: \(visited)")
        #expect(overlay.model(for: "dd5efg").isActive)

        // Show Comments off: nothing to visit, no highlight, no card.
        app.workspace.executeComment("showComments")
        #expect(!app.workspace.showsComments && !CommentPreferences.showsComments())
        #expect(editor.comments.highlights.isEmpty)
        overlay.refresh()
        #expect(overlay.cards.isEmpty && overlay.gutter == .hidden)
        app.workspace.executeComment("showComments")
        #expect(app.workspace.showsComments)
        #expect(CardUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 20: the author on a new comment is the setting's
    /// value, the macOS full name when the setting is empty, and never
    /// holds a bar or a newline.
    @Test func commentsAcceptance20TheAuthorComesFromTheSetting() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        #expect(CommentPreferences.authorName() == NSFullUserName())
        #expect(CommentPreferences.author(setting: "") == CommentSyntax.author(NSFullUserName()) ?? "Author")
        #expect(CommentPreferences.author(setting: "  ", fullName: "") == "Author")
        let app = try WritingFixture(text: cardSource, startService: false)
        defer { app.close() }
        let (editor, overlay, _) = try await openCards(app)
        let workspace = app.workspace
        let text = editor.string as NSString
        for (setting, expected) in [
            ("Ada | Park\nReviewer", "Ada  Park Reviewer"),
            ("", CommentSyntax.author(NSFullUserName()) ?? "Author"),
        ] {
            workspace.commentAuthorName = setting
            #expect(CommentPreferences.authorName() == setting, "Stored on this Mac")
            editor.setSelectedRange(text.range(of: "rests"))
            workspace.executeComment("addComment")
            #expect(overlay.model(for: CommentDraft.id).draftAuthor == expected || overlay.cards.isEmpty)
            overlay.model(for: CommentDraft.id).draftText = "By whom?"
            workspace.postDraft()
            try await app.wait { editor.comments.isCurrent }
            let comment = try #require(editor.comments.comments.first { $0.entries.first?.text == "By whom?" })
            let author = try #require(comment.entries.first?.author)
            #expect(author == expected)
            #expect(!author.contains("|") && !author.contains("\n"))
            editor.undoManager?.undo()
            #expect(editor.string == text as String)
        }
        expectPlainStorage(editor)
    }

    /// The commands, the menu and the list: the Comments group and its
    /// keys, the Edit menu's Comments submenu, Show Comment Source, and All
    /// Comments with a query, Return and a problem's action.
    @Test func commentsCommandsMenuAndListRunTheSameCode() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let group = try #require(CommandGroup.all.first { $0.id == "comments" })
        #expect(group.key == "k" && group.parentID == nil)
        let keys = WritingCommand.all.filter { $0.group == "comments" }.map(\.keyPath)
        #expect(keys == ["k a", "k r", "k e", "k d", "k n", "k p", "k s", "k h", "k l", "k u", "k b"])
        #expect(WritingCommand.all.first { $0.id == "comment" }?.title == "Toggle Source Comment")
        // No shortcut of the comments clashes with another command's.
        let labels = WritingCommand.all.flatMap { command in command.shortcuts.map { ($0.label, command.id) } }
        #expect(Set(labels.map(\.0)).count == labels.count, "A shortcut is used twice")

        let app = try WritingFixture(
            text: cardSource + "// prose:reply zz9zzz | Ada Park | 2026-11-15T10:00:00Z | Lost.\n",
            startService: false,
        )
        defer { app.close() }
        let (editor, overlay, _) = try await openCards(app)
        let workspace = app.workspace

        // The Edit menu's Comments submenu, with the shortcuts and states.
        let delegate = AppDelegate(workspace: workspace)
        let mainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = mainMenu }
        delegate.installMenu()
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let submenu = try #require(edit.items.first { $0.title == "Comments" }?.submenu)
        let titles = submenu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Add Comment", "Reply", "Resolve or Reopen", "Delete Comment", "Next Comment",
                           "Previous Comment", "Show Comments", "Show Resolved Comments", "All Comments",
                           "Show Comment Source"])
        let addItem = try #require(submenu.items.first { $0.title == "Add Comment" })
        #expect(addItem.keyEquivalent == "m" && addItem.keyEquivalentModifierMask == [.command, .option])
        let nextItem = try #require(submenu.items.first { $0.title == "Next Comment" })
        #expect(nextItem.keyEquivalent == "n" && nextItem.keyEquivalentModifierMask == [.control, .option])
        // No other menu item has the comments' shortcuts.
        func all(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) }
        }
        let items = try all(#require(NSApp.mainMenu))
        for (key, mask) in [("m", NSEvent.ModifierFlags([.command, .option])), ("n", [.control, .option]),
                            ("p", [.control, .option])]
        {
            let users = items.filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mask }
            #expect(users.count == 1, "⌥ \(key) is used by \(users.map(\.title))")
        }
        let showItem = try #require(submenu.items.first { $0.title == "Show Comments" })
        #expect(delegate.validateMenuItem(showItem) && showItem.state == .on)
        // The menu item runs the same code: Next Comment.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try NSApp.sendAction(#require(nextItem.action), to: nextItem.target, from: nextItem)
        #expect(editor.comments.activeID == "aa2bcd")

        // Reply puts the keyboard in the active card's field.
        workspace.executeComment("replyComment")
        try await app.wait { overlay.cards["aa2bcd"]?.containsFirstResponder == true }
        let reply = try #require(commentField(overlay, "aa2bcd"))
        reply.cancel?()
        #expect(app.window.firstResponder === editor)

        // Show Comment Source: the caret goes into the store and opens it.
        workspace.executeComment("showCommentSource")
        let store = try #require(editor.comments.store)
        #expect(NSLocationInRange(
            editor.selectedRange().location,
            NSRange(location: store.location, length: store.length + 1),
        ))
        await app.layout()
        if let fold = editor.writing.model?.fold(holding: store.location) {
            #expect(fold.isOpen, "Show Comment Source leaves the store closed")
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        // All Comments: rows, a query, the problem, Return.
        workspace.executeComment("allComments")
        #expect(workspace.paletteOpen && workspace.commentList != nil)
        let rows = workspace.commentListRows
        #expect(rows.map(\.section) == [.open, .open, .open, .open, .problems])
        #expect(rows.first?.author == "Ada Park" && rows.first?.text == "First.")
        #expect(rows.first { $0.id == "dd5efg" }?.replies == 1)
        let problem = try #require(rows.last)
        #expect(problem.text == "Reply with no comment")
        let index = try #require(workspace.commentListIndex)
        #expect(problem.actions(in: index) == [.remove])
        workspace.query = "tehran"
        #expect(workspace.commentListRows.map(\.id) == ["bb3cde"])
        workspace.query = ""
        #expect(workspace.handlePaletteKey(app.key("\u{f701}", code: 125)))
        #expect(workspace.highlightedCommentRow?.id == "bb3cde")
        #expect(workspace.handlePaletteKey(app.key("\r", code: 36)))
        #expect(!workspace.paletteOpen && editor.comments.activeID == "bb3cde")

        // The problem's action, from the list: one undo step.
        let before = editor.string
        workspace.executeComment("allComments")
        workspace.performCommentRowAction(.remove, on: problem)
        #expect(!editor.string.contains("zz9zzz"))
        #expect(editor.undoManager?.undoActionName == "Remove")
        editor.undoManager?.undo()
        #expect(editor.string == before)
        #expect(workspace.handlePaletteKey(app.key("\u{1b}", code: 53)))
        #expect(workspace.commentList == nil)
        workspace.closePalette()
        expectPlainStorage(editor)
    }

    /// Damaged and deleted anchors: their cards say so and offer Attach to
    /// Selection and Delete.
    @Test func commentsDamagedAndDeletedAnchorsOfferAttachAndDelete() async throws {
        resetCommentPreferences()
        defer { resetCommentPreferences() }
        let source = cardSource
            .replacingOccurrences(of: "/*cc4def>*/", with: "")
            .replacingOccurrences(of: "/*<aa2bcd*/quick/*aa2bcd>*/", with: "/*<aa2bcd*//*aa2bcd>*/quick")
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let (editor, overlay, _) = try await openCards(app)
        try await app.wait { overlay.cards["cc4def"] != nil && overlay.cards["aa2bcd"] != nil }
        #expect(overlay.model(for: "cc4def").comment?.state == .damaged)
        #expect(overlay.model(for: "aa2bcd").kind == .emptyAnchor)
        let damaged = try #require(overlay.cards["cc4def"])
        #expect(damaged.fittingSize.height > 60)
        // Attach to Selection: the damaged comment gets new markers.
        let text = editor.string as NSString
        editor.setSelectedRange(text.range(of: "lazy dog"))
        app.workspace.attachComment("cc4def")
        #expect(editor.undoManager?.undoActionName == "Attach Comment")
        try await app.wait { editor.comments.isCurrent }
        let attached = try #require(editor.comments.comments.first { $0.id == "cc4def" })
        #expect(attached.state == .attached)
        #expect(try (editor.string as NSString).substring(with: #require(attached.anchor)) == "lazy dog")
        // Delete the one whose text was deleted.
        app.workspace.deleteComment("aa2bcd")
        try await app.wait { editor.comments.isCurrent }
        #expect(!editor.string.contains("aa2bcd"))
        expectPlainStorage(editor)
    }

    /// The pure parts: the gutter's layouts, stacking, the card's date, the
    /// author, and the list's sections.
    @Test func commentsGutterStackingAndDatesFollowTheNote() throws {
        #expect(CommentGutter.layout(paneWidth: 1900, focus: false, hasComments: false) == .hidden)
        #expect(CommentGutter.layout(paneWidth: 1900, focus: false, hasComments: true) == .centred)
        if case let .shifted(shift) = CommentGutter.layout(paneWidth: 1220, focus: false, hasComments: true) {
            let inset = ManuscriptLayout.horizontalInset(for: 1220)
            #expect(inset - shift >= ManuscriptLayout.minimumInset)
            #expect(1220 - (inset - shift) - (1220 - 2 * inset) >= CommentGutter.gap + CommentGutter.width - 1)
        } else {
            Issue.record("1220 pt should move the column")
        }
        #expect(CommentGutter.layout(paneWidth: 700, focus: false, hasComments: true) == .icons)
        #expect(CommentGutter.layout(paneWidth: 1000, focus: true, hasComments: true) == .centred)
        if case .shifted = CommentGutter.layout(paneWidth: 800, focus: true, hasComments: true) {} else {
            Issue.record("Focus at 800 pt should move the column")
        }
        #expect(CommentOverlay.stack(tops: [10, 10, 10], heights: [50, 50, 50], active: nil) == [10, 68, 126])
        #expect(CommentOverlay.stack(tops: [10, 10, 10], heights: [50, 50, 50], active: 1) == [-48, 10, 68])
        #expect(CommentOverlay.stack(tops: [0, 300], heights: [50, 50], active: nil) == [0, 300])
        #expect(CommentOverlay.stack(tops: [], heights: [], active: nil).isEmpty)
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(CommentDate.text("2026-11-15T14:02:11Z", timeZone: utc) == "15 Nov, 14:02")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(CommentDate.text("2026-11-15T14:02:11Z", timeZone: tokyo) == "15 Nov, 23:02")
        #expect(CommentDate.text("not a date") == "not a date")
        #expect(CommentOverlay.touches(NSRange(location: 5, length: 3), [NSRange(location: 0, length: 6)]))
        #expect(!CommentOverlay.touches(NSRange(location: 10, length: 3), [NSRange(location: 0, length: 6)]))
        let source = cardSource as NSString
        let tree = try #require(SyntaxTree(cardSource))
        let index = try #require(CommentIndex(source: source, tree: tree))
        let rows = CommentListRow.rows(for: index, matching: "")
        #expect(rows.map(\.id) == ["aa2bcd", "bb3cde", "cc4def", "dd5efg"])
        #expect(CommentListRow.rows(for: index, matching: "longer").map(\.id) == ["dd5efg"])
        #expect(rows[0].actions(in: index) == [.delete])
        #expect(CommentListRow.firstLine("One\nTwo") == "One")
        for kind: CommentIndex.ProblemKind in [
            .markersWithNoComment, .usedMoreThanOnce, .unreadableLine, .replyWithNoComment,
            .newerFormat(version: 2), .notClosed,
        ] {
            #expect(!CommentListRow.problemName(kind).isEmpty)
        }
        for failure: CommentEdits.Failure in [.newerFormat, .notFound, .emptyText, .textTooLong, .tooManyReplies] {
            #expect(!Workspace.commentFailureText(failure).isEmpty)
        }
        #expect(CommentGroupHeights.root10 == 50 && CommentGroupHeights.root9 == 66)
    }
}

/// The palette's root grid height, read through the view's static helper.
@MainActor
private enum CommentGroupHeights {
    static let root10 = CommandPalette.groupHeight(10, root: true)
    static let root9 = CommandPalette.groupHeight(9, root: true)
}

// MARK: - Fixture and helpers

private let cardSource = """
= Cards in the margin

The /*<aa2bcd*/quick/*aa2bcd>*/ /*<bb3cde*/brown/*bb3cde>*/ /*<cc4def*/fox/*cc4def>*/ jumps over the lazy dog.

A second paragraph with a /*<dd5efg*/longer comment on these words/*dd5efg>*/ and more text after it.

A paragraph with `raw text` in it.

A plain paragraph with no comment, where the caret rests.

A last paragraph to comment on later.

// prose:comments 1
// prose:comment aa2bcd | Ada Park | 2026-11-15T14:02:11Z | First.
// prose:comment bb3cde | Tehran Davis | 2026-11-15T14:03:00Z | Second.
// prose:comment cc4def | Ada Park | 2026-11-15T14:04:00Z | Third.
// prose:comment dd5efg | Ada Park | 2026-11-15T15:00:00Z | A longer comment.
// prose:reply dd5efg | Tehran Davis | 2026-11-15T16:00:00Z | A reply.

"""

/// Removes the comment settings, so each test starts from the defaults.
@MainActor
private func resetCommentPreferences() {
    for key in [CommentPreferences.showsCommentsKey, CommentPreferences.showsResolvedKey,
                CommentPreferences.authorKey]
    {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Opens `cardSource` in Writing mode with the editor pane alone (no
/// preview), the caret in the plain paragraph so every commented block
/// renders, and waits for the index, the renders and the cards.
@MainActor
private func openCards(
    _ app: WritingFixture,
    width: CGFloat? = nil,
) async throws -> (ManuscriptTextView, CommentOverlay, NSTextLayoutManager) {
    app.window.appearance = NSAppearance(named: .aqua)
    if let width {
        app.window.setContentSize(NSSize(width: width, height: 820))
        placeOnTestScreen(app.window)
    }
    app.workspace.layout = .writing
    app.window.orderFront(nil)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let overlay = try #require(editor.commentOverlay)
    let manager = try #require(editor.textLayoutManager)
    let text = editor.string as NSString
    editor.setSelectedRange(NSRange(location: text.range(of: "where the caret rests").location, length: 0))
    let model = try await enterWritingMode(app)
    writingScrollToTop(editor)
    await app.layout()
    let blocks = ["The ", "A second", "A last"].map { text.range(of: $0).location }
    try await app.wait {
        writingScrollToTop(editor)
        return editor.comments.isCurrent && !editor.comments.viewsWait &&
            blocks.allSatisfy { renderedBlock(manager, at: $0) != nil }
    }
    await model.idle()
    await app.layout()
    try await app.wait {
        overlay.refresh()
        return !overlay.cards.isEmpty || !overlay.icons.isEmpty
    }
    return (editor, overlay, manager)
}

/// Selects `range` as the pointer does, so a rendered block stays typeset.
@MainActor
private func pointerSelect(_ editor: ManuscriptTextView, _ range: NSRange) {
    editor.selectingWithMouse = true
    editor.setSelectedRange(range)
    editor.selectingWithMouse = false
    editor.selectionChanged(byPointer: true, anchor: range.location)
}

/// The text field of a card.
@MainActor
private func commentField(_ overlay: CommentOverlay, _ id: String) -> CommentFieldView? {
    func find(_ view: NSView) -> CommentFieldView? {
        if let field = view as? CommentFieldView {
            return field
        }
        for child in view.subviews {
            if let field = find(child) {
                return field
            }
        }
        return nil
    }
    return overlay.cards[id].flatMap(find)
}

/// What a test that does not edit must leave as it was.
@MainActor
private struct CardUndo: Equatable {
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String

    init(_ editor: ManuscriptTextView) {
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
    }
}
