import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 8 step C: comments drawn and edited, acceptance tests 9 to 13 of
/// the comments note, on the real window, editor and engine. Numbers are
/// printed with the prefix `COMMENTS`. Every test also checks that the
/// storage holds only the source, that TextKit 2 is still on, and that the
/// undo stack is unchanged unless the test edits.
extension WritingFlowTests {
    /// Acceptance test 9: an anchor inside a rendered paragraph has the
    /// highlight colour under its glyph boxes and nowhere else, across a
    /// line break and across a block boundary, in light and dark. A
    /// resolved comment draws nothing. The storage has no background
    /// attribute. The contrast of the text on the fill is 4.5:1 or better.
    @Test(arguments: [false, true])
    func commentsAcceptance9TheHighlightFillsTheAnchorsGlyphsOnly(dark: Bool) async throws {
        let app = try WritingFixture(text: commentSource, startService: false)
        defer { app.close() }
        let (editor, manager, _) = try await openComments(app, dark: dark)
        let undo = CommentUndo(editor)
        let text = editor.string as NSString
        let first = try commentAnchor(editor, "k3f9x2"), second = try commentAnchor(editor, "m4pq7r")
        let resolved = try commentAnchor(editor, "r7tw2a")
        let blocks = ["The ", "A second", "A third", "A resolved"].map { text.range(of: $0).location }
        let background = dark ? (38, 38, 38) : (255, 255, 255)
        let opacity = dark ? Theme.commentHighlightOpacity.dark : Theme.commentHighlightOpacity.light
        let composite = commentComposite((0xE8, 0xA8, 0x38), over: background, alpha: opacity)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "comments-highlight-\(dark ? "dark" : "light").png")
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: background)
        // The fill as drawn: the commonest colour over the first anchor's
        // glyphs. Colour matching moves it a few units from the sRGB mix.
        let firstBlock = try #require(renderedBlock(manager, at: blocks[0]))
        let fill = try #require(commonestColour(canvas, glyphBoxes(firstBlock).filter {
            $0.offset.map { NSLocationInRange($0, first) } ?? false
        }.map(\.box)))
        print("COMMENTS fill \(dark ? "dark" : "light"): drawn \(fill), sRGB mix \(composite)")
        #expect(isAmber(fill, over: background), "The fill \(fill) is not amber over the page")
        func isFill(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
            commentDistance((red, green, blue), fill) <= 4
        }
        // The contrast of the text: its strongest ink over the anchors.
        var expected: [CGRect] = [], lines = Set<Int>(), contrast = 0.0
        for block in blocks {
            let shown = try #require(renderedBlock(manager, at: block), "Block \(block) is not rendered")
            let fragment = try #require(shown.info.fragment)
            let map = fragment.glyphMap(shown.rendering, block: shown.block)
            for anchor in [first, second] where NSIntersectionRange(anchor, shown.block).length > 0 {
                expected += map.lineRects(for: [anchor]).map {
                    $0.offsetBy(dx: shown.info.frame.minX, dy: shown.info.frame.minY)
                }
            }
            for glyph in glyphBoxes(shown) {
                guard let offset = glyph.offset else {
                    continue
                }
                let inside = NSLocationInRange(offset, first) || NSLocationInRange(offset, second)
                let filled = canvas.matching(in: glyph.box.insetBy(dx: 1, dy: 1), isFill)
                if inside {
                    #expect(filled > 0, "The glyph of \(offset) has no highlight")
                    lines.insert(Int(glyph.box.minY.rounded()))
                    var strongest = fill, farthest = 0
                    _ = canvas.matching(in: glyph.box) { red, green, blue in
                        let away = max(abs(red - fill.0), abs(green - fill.1), abs(blue - fill.2))
                        if away > farthest {
                            farthest = away
                            strongest = (red, green, blue)
                        }
                        return false
                    }
                    contrast = max(contrast, commentContrast(strongest, fill))
                } else {
                    #expect(filled == 0, "The glyph of \(offset), outside every anchor, has \(filled) filled pixels")
                }
                if NSLocationInRange(offset, resolved) {
                    #expect(filled == 0, "The resolved comment's glyph \(offset) is filled")
                }
            }
        }
        // Across a line break (the first anchor wraps) and a block boundary.
        #expect(lines.count >= 4, "The anchors cover \(lines.count) drawn lines")
        #expect(expected.count >= 4)
        // Nowhere else: no fill outside the anchors' lines.
        let outside = canvas.matching(in: editor.containerVisibleRect()) { red, green, blue in
            isFill(red, green, blue)
        } - expected.reduce(0) { total, rect in total + canvas.matching(in: rect.insetBy(dx: -1, dy: -1), isFill) }
        #expect(outside <= 0, "\(outside) filled pixels lie outside the anchors")
        print("COMMENTS contrast rendered \(dark ? "dark" : "light"): \(String(format: "%.2f", contrast)):1")
        #expect(contrast >= 4.5)
        expectNoBackgroundAttribute(editor)
        #expect(CommentUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 10: in the open block the start marker and the end
    /// marker have the faint colour and the anchor has the highlight, and
    /// the storage's attributes equal Code mode's. Code mode draws the
    /// highlight too, and the contrast of source text on it is 4.5:1 or
    /// better.
    @Test(arguments: [false, true])
    func commentsAcceptance10TheOpenBlockDrawsFaintMarkersOverTheHighlight(dark: Bool) async throws {
        let app = try WritingFixture(text: commentSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let storage = try #require(editor.textStorage)
        try await app.wait { editor.comments.isCurrent && !editor.comments.viewsWait }
        await app.layout()
        let background = dark ? (38, 38, 38) : (255, 255, 255)
        let codeMode = NSAttributedString(attributedString: storage)
        let undo = CommentUndo(editor)

        // Code mode: the anchor has the fill, the markers do not.
        let anchor = try commentAnchor(editor, "k3f9x2")
        let markers = try #require(editor.comments.placed.first { $0.id == "k3f9x2" })
        expectHighlight(editor, anchor, markers)
        let code = try commentInk(editor, anchor, background, "comments-code-\(dark ? "dark" : "light").png")
        print("COMMENTS contrast code mode \(dark ? "dark" : "light"): \(String(format: "%.2f", code.contrast)):1")
        #expect(code.filled > 0 && code.contrast >= 4.5)

        // Writing mode, the caret in the commented paragraph.
        editor.setSelectedRange(NSRange(location: anchor.location + 3, length: 0))
        _ = try await enterWritingMode(app)
        try await app.wait {
            editor.styler?.openBlock?.fonts != nil && editor.styler?.openBlock?.span == editor.writing.model?.openBlock?
                .span
        }
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        await app.layout()
        let open = try #require(editor.writing.model?.openBlock)
        #expect(NSLocationInRange(anchor.location, open.span))
        // The caret is in the anchor: the comment is active (step D).
        expectHighlight(editor, anchor, markers, fill: Theme.activeCommentHighlight)
        let faint = try #require(editor.styler?.colors.overlay?.faint)
        for marker in [markers.start, markers.end] {
            for offset in marker.location ..< NSMaxRange(marker) {
                #expect(editor.drawnColor(at: offset) == faint, "Marker character \(offset) is not faint")
            }
        }
        let writing = try commentInk(editor, anchor, background, "comments-open-\(dark ? "dark" : "light").png")
        print("COMMENTS contrast open block \(dark ? "dark" : "light"): \(String(format: "%.2f", writing.contrast)):1")
        #expect(writing.filled > 0 && writing.contrast >= 4.5)

        // Leaving: the storage's attributes are Code mode's.
        app.workspace.setMode(.code)
        await app.layout()
        #expect(storage.isEqual(to: codeMode), "The storage's attributes differ from Code mode's")
        expectNoBackgroundAttribute(editor)
        #expect(CommentUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 11: the store draws nothing and takes no height in
    /// Writing and Focus modes. A reply made through the comment actions'
    /// edit path does not open it. The caret inside it opens it. In Code
    /// mode it is plain source.
    @Test func commentsAcceptance11TheStoreIsHiddenAndAReplyLeavesItClosed() async throws {
        let app = try WritingFixture(text: commentSource, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openComments(app)
        let undo = CommentUndo(editor)
        func expectHidden(_ label: String) throws {
            let store = try #require(editor.comments.store, "\(label): no store")
            let fold = try #require(model.fold(holding: store.location), "\(label): the store is not a fold")
            #expect(!fold.isOpen && fold.isHidden, "\(label): the store's fold is open or shown")
            let inside = writingFragments(manager).filter { NSLocationInRange($0.offset, store) }
            #expect(!inside.isEmpty)
            for info in inside {
                #expect(
                    info.role == .collapsed && info.frame.height == 0,
                    "\(label): \(info.offset) draws \(info.role)",
                )
                #expect(info.fragment?.marginIcon == nil, "\(label): \(info.offset) draws a margin mark")
            }
        }
        try expectHidden("Writing")
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused }
        await model.idle()
        await app.layout()
        try expectHidden("Focus")
        app.workspace.setMode(.writing)
        try await app.wait { !editor.writing.focused }
        await app.layout()
        #expect(CommentUndo(editor) == undo)

        // A reply, through the native edit path as a comment action.
        let before = editor.string
        let caret = editor.selectedRange()
        let index = try #require(editor.comments.snapshot?.index)
        let replacements = try CommentEdits.reply(
            to: "k3f9x2",
            author: "Ada Park",
            date: Date(timeIntervalSince1970: 1_800_000_000),
            text: "A reply that stays in the store.",
            index: index,
            source: editor.string as NSString,
        )
        #expect(editor.applyCommentEdits(replacements, actionName: "Reply to Comment"))
        #expect(editor.string.contains("A reply that stays in the store."))
        #expect(editor.selectedRange() == caret, "The reply moved the caret")
        #expect(editor.undoManager?.undoActionName == "Reply to Comment")
        try await app.wait { editor.comments.isCurrent && !editor.comments.viewsWait }
        await model.idle()
        await app.layout()
        try expectHidden("After a reply")
        #expect(editor.comments.comments.first { $0.id == "k3f9x2" }?.replies.count == 1)
        editor.undoManager?.undo()
        #expect(editor.string == before, "One undo did not take the reply back")
        try await app.wait { editor.comments.isCurrent }
        await model.idle()
        await app.layout()
        try expectHidden("After the undo")

        // The caret inside the store opens it; outside, it closes again.
        let store = try #require(editor.comments.store)
        editor.setSelectedRange(NSRange(location: store.location + 4, length: 0))
        await app.layout()
        let opened = try #require(model.fold(holding: store.location))
        #expect(opened.isOpen && !opened.isHidden)
        let shown = writingFragments(manager).filter { NSLocationInRange($0.offset, store) }
        #expect(shown.allSatisfy { $0.role == .source && $0.frame.height > 0 })
        editor.setSelectedRange(caret)
        await app.layout()
        try expectHidden("After the caret left")

        // Code mode: plain source.
        app.workspace.setMode(.code)
        await app.layout()
        let code = writingFragments(manager).filter { NSLocationInRange($0.offset, store) }
        #expect(code.allSatisfy { $0.role == .source && $0.frame.height > 0 })
        expectPlainStorage(editor)
    }

    /// Acceptance test 12: Left and Right pass a start marker and an end
    /// marker in one step in Writing and Focus modes, and by character in
    /// Code mode. Backspace and Forward Delete beside one remove the next
    /// character of text. A selection that holds both, deleted, removes the
    /// records in one undo step, and one undo brings everything back.
    @Test func commentsAcceptance12ArrowsAndDeleteKeysPassTheMarkers() async throws {
        let app = try WritingFixture(text: commentSource, startService: false)
        defer { app.close() }
        let (editor, _, _) = try await openComments(app)
        let undo = CommentUndo(editor)
        let placed = try #require(editor.comments.placed.first { $0.id == "k3f9x2" })
        let (start, end) = (placed.start, placed.end)
        func steps(_ label: String, whole: Bool) {
            let marker = whole ? 11 : 1
            for (from, forward, to) in [
                (start.location, true, start.location + marker),
                (NSMaxRange(start), false, NSMaxRange(start) - marker),
                (end.location, true, end.location + marker),
                (NSMaxRange(end), false, NSMaxRange(end) - marker),
            ] {
                editor.setSelectedRange(NSRange(location: from, length: 0))
                if forward {
                    editor.moveRight(nil)
                } else {
                    editor.moveLeft(nil)
                }
                #expect(editor.selectedRange() == NSRange(location: to, length: 0), "\(label): from \(from)")
            }
            editor.setSelectedRange(NSRange(location: start.location, length: 0))
            editor.moveRightAndModifySelection(nil)
            #expect(editor.selectedRange() == NSRange(location: start.location, length: marker), "\(label): shift")
            editor.moveRightAndModifySelection(nil)
            editor.moveLeftAndModifySelection(nil)
            #expect(editor.selectedRange() == NSRange(location: start.location, length: marker), "\(label): back")
            editor.setSelectedRange(NSRange(location: NSMaxRange(end), length: 0))
            editor.moveLeftAndModifySelection(nil)
            #expect(editor.selectedRange() == NSRange(location: NSMaxRange(end) - marker, length: marker), "\(label)")
        }
        steps("Writing", whole: true)
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused }
        await app.layout()
        steps("Focus", whole: true)
        app.workspace.setMode(.code)
        await app.layout()
        steps("Code", whole: false)
        app.workspace.setMode(.writing)
        try await app.wait { editor.writing.isRunning }
        await app.layout()
        #expect(CommentUndo(editor) == undo)

        // Backspace after the start marker removes the space before it.
        let original = editor.string
        editor.setSelectedRange(NSRange(location: NSMaxRange(start), length: 0))
        editor.deleteBackward(nil)
        let afterBackspace = (original as NSString).replacingCharacters(
            in: NSRange(location: start.location - 1, length: 1),
            with: "",
        )
        #expect(editor.string == afterBackspace)
        #expect(editor.selectedRange() == NSRange(location: NSMaxRange(start) - 1, length: 0))
        editor.undoManager?.undo()
        #expect(editor.string == original)
        // Forward Delete before the end marker removes the space after it.
        editor.setSelectedRange(NSRange(location: end.location, length: 0))
        editor.deleteForward(nil)
        #expect(editor.string == (original as NSString).replacingCharacters(
            in: NSRange(location: NSMaxRange(end), length: 1),
            with: "",
        ))
        #expect(editor.selectedRange() == NSRange(location: end.location, length: 0))
        editor.undoManager?.undo()
        #expect(editor.string == original)
        try await app.wait { editor.comments.isCurrent }

        // A selection that holds both markers: the records go too.
        let paragraph = (original as NSString).paragraphRange(for: start)
        editor.setSelectedRange(paragraph)
        editor.deleteBackward(nil)
        let deleted = editor.string
        #expect(!deleted.contains("k3f9x2"), "The comment's markers or records are left")
        #expect(deleted.contains("// prose:comment m4pq7r"))
        #expect(app.workspace.text == deleted, "textDidChange did not reach the workspace")
        try await app.wait { editor.comments.isCurrent }
        try expectIndexInStep(editor)
        editor.undoManager?.undo()
        #expect(editor.string == original, "One undo did not bring everything back")
        editor.undoManager?.redo()
        #expect(editor.string == deleted)
        editor.undoManager?.undo()
        #expect(editor.string == original)
        try await app.wait { editor.comments.isCurrent }
        try expectIndexInStep(editor)
        expectPlainStorage(editor)
    }

    /// Acceptance test 13: a deletion that holds one of the two markers
    /// leaves it at the place of the deletion, and the comment's anchor is
    /// the text that remains; typing over such a selection puts the new
    /// text outside the anchor. Removing all the text between the two
    /// leaves the comment with an empty anchor. The count in the status bar
    /// is the same with and without comments.
    @Test func commentsAcceptance13ADeletionKeepsALoneMarkerAndTheCountLeavesCommentsOut() async throws {
        let sourceTree = try #require(SyntaxTree(commentSource))
        let sourceIndex = try #require(CommentIndex(source: commentSource as NSString, tree: sourceTree))
        let plain = CommentEdits.withoutComments(commentSource as NSString, index: sourceIndex)
        let bare = try WritingFixture(text: plain, startService: false)
        let bareCount = bare.workspace.wordCount
        bare.close()
        let app = try WritingFixture(text: commentSource, startService: false)
        defer { app.close() }
        let (editor, _, _) = try await openComments(app)
        print("COMMENTS count with comments \(app.workspace.wordCount), without \(bareCount)")
        #expect(app.workspace.wordCount == bareCount)
        #expect(app.workspace.commentHiddenCharacters > 0)
        let original = editor.string as NSString

        // The end marker's side: from inside the anchor to past the marker.
        let tail = original.range(of: "until the morning comes/*k3f9x2>*/ and the ")
        editor.setSelectedRange(tail)
        editor.deleteBackward(nil)
        #expect((editor.string as NSString).range(of: "find it again /*k3f9x2>*/day is done.").location != NSNotFound)
        try await app.wait { editor.comments.isCurrent }
        try #expect(commentText(editor, "k3f9x2").hasSuffix("find it again"))
        #expect(editor.string.contains("// prose:comment k3f9x2"))
        try expectIndexInStep(editor)
        editor.undoManager?.undo()
        #expect(editor.string == original as String)
        try await app.wait { editor.comments.isCurrent }

        // The start marker's side, typed over: the letter is outside.
        let head = original.range(of: "The /*<k3f9x2*/quick ")
        editor.setSelectedRange(head)
        editor.insertText("A", replacementRange: head)
        #expect(editor.string.hasPrefix("= Comments in the margin\n\nA/*<k3f9x2*/brown fox"))
        #expect(editor.selectedRange() == NSRange(location: head.location + 1, length: 0))
        try await app.wait { editor.comments.isCurrent }
        try #expect(commentText(editor, "k3f9x2").hasPrefix("brown fox"))
        editor.undoManager?.undo()
        #expect(editor.string == original as String)
        try await app.wait { editor.comments.isCurrent }

        // All the text between, but neither marker: an empty anchor.
        let anchor = try commentAnchor(editor, "m4pq7r")
        let between = NSRange(
            location: original.range(of: "/*<m4pq7r*/").location + 11,
            length: original.range(of: "/*m4pq7r>*/").location - original.range(of: "/*<m4pq7r*/").location - 11,
        )
        #expect(NSIntersectionRange(anchor, between) == anchor)
        editor.setSelectedRange(between)
        editor.deleteBackward(nil)
        #expect(editor.string.contains("/*<m4pq7r*//*m4pq7r>*/"))
        try await app.wait { editor.comments.isCurrent }
        let empty = try #require(editor.comments.comments.first { $0.id == "m4pq7r" })
        #expect(empty.state == .attached && empty.anchor?.length == 0)
        let emptied = try #require(editor.comments.snapshot?.index)
        #expect(app.workspace.wordCount == CommentEdits.withoutComments(editor.string as NSString, index: emptied)
            .filter { !$0.isWhitespace }.count)
        editor.undoManager?.undo()
        #expect(editor.string == original as String)
        expectPlainStorage(editor)
    }

    /// A dimmed block's highlight dims with it in Focus mode, and a
    /// rendered block whose anchor has no glyph box gets an outline round
    /// its image.
    @Test func commentsHighlightDimsInFocusAndOutlinesABlockWithNoGlyphs() async throws {
        let source = commentSource.replacingOccurrences(
            of: "A plain paragraph",
            with: "An image /*<a2b3c4*/#box(rect(width: 3cm, height: 1cm, fill: blue))/*a2b3c4>*/\n\nA plain paragraph",
        ) + "// prose:comment a2b3c4 | Ada Park | 2026-11-15T15:20:00Z | The box.\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let (editor, manager, model) = try await openComments(app)
        let undo = CommentUndo(editor)
        let text = editor.string as NSString
        let image = text.range(of: "An image").location
        try await app.wait { renderedBlock(manager, at: image) != nil }
        await app.layout()
        func picture(_ name: String) throws -> WritingCanvas {
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            try writingSave(bitmap, name)
            return WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        }
        func anchorBoxes() throws -> [CGRect] {
            let first = try commentAnchor(editor, "k3f9x2")
            let shown = try #require(renderedBlock(manager, at: text.range(of: "The ").location))
            return glyphBoxes(shown).filter { $0.offset.map { NSLocationInRange($0, first) } ?? false }.map(\.box)
        }
        var canvas = try picture("comments-outline.png")
        let full = try #require(commonestColour(canvas, anchorBoxes()))
        // The outline: amber along the edge of the box's block.
        let shown = try #require(renderedBlock(manager, at: image))
        let fragment = try #require(shown.info.fragment)
        let edge = fragment.imageRect(shown.rendering, column: fragment.columnWidth)
            .offsetBy(dx: shown.info.frame.minX, dy: shown.info.frame.minY)
        let band = CGRect(x: edge.minX - 2, y: edge.minY - 2, width: edge.width + 4, height: 4)
        let outlined = canvas
            .matching(in: band) { red, green, blue in isAmber((red, green, blue), over: (255, 255, 255)) }
        #expect(outlined > 0, "No outline round the block with no glyph in its anchor")

        // Focus: the first paragraph is dimmed, and so is its highlight.
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused }
        await model.idle()
        try await app.wait {
            writingScrollToTop(editor)
            return renderedBlock(manager, at: text.range(of: "The ").location) != nil
        }
        await app.layout()
        #expect(editor.writing.dims(paragraphAt: text.range(of: "The ").location))
        canvas = try picture("comments-focus.png")
        let dimmed = try #require(commonestColour(canvas, anchorBoxes()))
        print("COMMENTS focus fill: full \(full), dimmed \(dimmed)")
        #expect(isAmber(dimmed, over: (255, 255, 255)) || commentDistance(dimmed, (255, 255, 255)) > 4)
        #expect(commentDistance(dimmed, (255, 255, 255)) * 10 < commentDistance(full, (255, 255, 255)) * 7)
        app.workspace.setMode(.code)
        await app.layout()
        #expect(CommentUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// The check that chose how decision 4's rules change an edit, on the
    /// real text view. The rewrite (the gate refuses the writer's edit and
    /// makes the planned one through the native edit path, in one undo
    /// group) is what the editor uses: undo and redo restore exact source
    /// states, `textDidChange` reaches the workspace, the index stays in
    /// step with the text, and nothing runs while text is marked. The other
    /// way, a second edit after the writer's in the same undo group, is
    /// measured here and printed: it leaves a broken marker between its two
    /// edits whenever an edit cuts into one.
    @Test func commentsEditRulesRewriteHoldsAndAFollowUpEditIsMeasured() async throws {
        let app = try WritingFixture(text: commentSource, startService: false)
        defer { app.close() }
        let (editor, _, _) = try await openComments(app)
        let original = editor.string
        let start = try #require(editor.comments.placed.first { $0.id == "k3f9x2" }).start
        nonisolated(unsafe) var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: editor,
            queue: nil,
        ) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The rewrite: a selection that cuts into the start marker.
        let cut = NSRange(location: start.location - 4, length: 7)
        editor.setSelectedRange(cut)
        editor.deleteBackward(nil)
        let rewritten = editor.string
        #expect(rewritten == (original as NSString).replacingCharacters(
            in: NSRange(location: start.location - 4, length: 4),
            with: "",
        ), "The start marker was not kept whole at the place of the removal")
        #expect(changes >= 1 && app.workspace.text == rewritten)
        try await app.wait { editor.comments.isCurrent }
        try expectIndexInStep(editor)
        editor.undoManager?.undo()
        #expect(editor.string == original)
        editor.undoManager?.redo()
        #expect(editor.string == rewritten)
        editor.undoManager?.undo()
        #expect(editor.string == original)
        try await app.wait { editor.comments.isCurrent }

        // While text is marked no rule runs: the composition replaces the
        // selection, markers and all, as typed.
        let both = (original as NSString).paragraphRange(for: start)
        editor.setSelectedRange(both)
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: both)
        #expect(editor.hasMarkedText())
        editor.unmarkText()
        #expect(!editor.string.contains("/*<k3f9x2*/") && editor.string.contains("// prose:comment k3f9x2"))
        editor.undoManager?.undo()
        #expect(editor.string == original)
        try await app.wait { editor.comments.isCurrent }

        // The other way, measured: the writer's edit as typed, then a second
        // edit that puts the marker back.
        editor.setSelectedRange(cut)
        editor.commentEditDepth += 1
        editor.deleteBackward(nil)
        editor.commentEditDepth -= 1
        let broken = editor.string.contains("/*<k3f9x2*/") ? "no" : "yes"
        editor.insertText(
            CommentSyntax.startMarker("k3f9x2"),
            replacementRange: NSRange(location: start.location - 4, length: 0),
        )
        let followed = (editor.string as NSString).replacingOccurrences(of: "/*<k3f9x2*/", with: "") ==
            (rewritten as NSString).replacingOccurrences(of: "/*<k3f9x2*/", with: "")
        editor.undoManager?.undo()
        let oneUndo = editor.string == original
        while editor.string != original, editor.undoManager?.canUndo == true {
            editor.undoManager?.undo()
        }
        print("COMMENTS follow-up edit: marker broken between the edits \(broken), " +
            "same text \(followed), one undo restores \(oneUndo)")
        #expect(editor.string == original)
        expectPlainStorage(editor)
    }
}

// MARK: - Fixture and helpers

private let commentSource = """
= Comments in the margin

The /*<k3f9x2*/quick brown fox jumps over the lazy dog, then runs across the wide field, past the old \
mill and the river, into the long grass where nobody can find it again until the morning comes\
/*k3f9x2>*/ and the day is done.

A second paragraph that /*<m4pq7r*/starts a comment in its middle.

A third paragraph where the comment ends/*m4pq7r>*/ before these words.

A resolved one: /*<r7tw2a*/this text has no fill/*r7tw2a>*/ because it is resolved.

A plain paragraph with no comment at all, where the caret rests.

// prose:comments 1
// prose:comment k3f9x2 | Tehran Davis | 2026-11-15T14:02:11Z | Is "quick" the right word here?
// prose:comment m4pq7r | Ada Park | 2026-11-15T15:10:40Z | This one crosses two paragraphs.
// prose:reply m4pq7r | Tehran Davis | 2026-11-15T16:00:00Z | Yes, on purpose.
// prose:comment r7tw2a | Ada Park | 2026-11-15T15:20:00Z | Done.
// prose:resolve r7tw2a | Ada Park | 2026-11-16T09:00:00Z

"""

/// Opens `commentSource` in Writing mode with the caret in the plain
/// paragraph, so every commented paragraph renders, and waits for the
/// comment index and the renders.
@MainActor
private func openComments(
    _ app: WritingFixture,
    dark: Bool = false,
) async throws -> (ManuscriptTextView, NSTextLayoutManager, WritingLayout) {
    app.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    app.window.orderFront(nil)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let manager = try #require(editor.textLayoutManager)
    let text = editor.string as NSString
    let rest = text.range(of: "where the caret rests").location
    editor.setSelectedRange(NSRange(location: rest, length: 0))
    let model = try await enterWritingMode(app)
    writingScrollToTop(editor)
    await app.layout()
    let blocks = ["The ", "A second", "A third", "A resolved"].map { text.range(of: $0).location }
    try await app.wait {
        writingScrollToTop(editor)
        return editor.comments.isCurrent && !editor.comments.viewsWait &&
            blocks.allSatisfy { renderedBlock(manager, at: $0) != nil }
    }
    await model.idle()
    await app.layout()
    return (editor, manager, model)
}

/// The anchor of comment `id` in today's text.
@MainActor
private func commentAnchor(_ editor: ManuscriptTextView, _ id: String) throws -> NSRange {
    try #require(editor.comments.placed.first { $0.id == id }, "No attached comment \(id)").anchor
}

/// The text of comment `id`'s anchor, from a current index.
@MainActor
private func commentText(_ editor: ManuscriptTextView, _ id: String) throws -> String {
    let anchor = try #require(editor.comments.comments.first { $0.id == id }?.anchor, "No anchor for \(id)")
    return (editor.string as NSString).substring(with: anchor)
}

/// The index the editor holds equals one built from a fresh parse.
@MainActor
private func expectIndexInStep(_ editor: ManuscriptTextView) throws {
    let text = editor.string as NSString
    let tree = try #require(SyntaxTree(editor.string))
    let fresh = try #require(CommentIndex(source: text, tree: tree))
    #expect(editor.comments.snapshot?.index == fresh, "The index is out of step with the text")
}

/// The anchor's characters draw the highlight, the markers' none.
@MainActor
private func expectHighlight(
    _ editor: ManuscriptTextView,
    _ anchor: NSRange,
    _ placed: PlacedComment,
    fill: NSColor = Theme.commentHighlight,
) {
    for offset in [anchor.location, anchor.location + anchor.length / 2, NSMaxRange(anchor) - 1] {
        let drawn = editor.drawnAttribute(.backgroundColor, at: offset) as? NSColor
        #expect(drawn == fill, "Anchor character \(offset) has no highlight")
    }
    for offset in [placed.start.location, NSMaxRange(placed.start) - 1, placed.end.location] {
        #expect(editor.drawnAttribute(.backgroundColor, at: offset) == nil, "Marker character \(offset) is filled")
    }
}

/// No character of the storage has a background colour.
@MainActor
private func expectNoBackgroundAttribute(_ editor: ManuscriptTextView) {
    var found = 0
    if let storage = editor.textStorage {
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            found += value == nil ? 0 : 1
        }
    }
    #expect(found == 0, "The storage holds a background attribute")
}

/// The pixels with the fill over the source glyphs of `anchor` in view, and
/// the lowest contrast of their strongest ink against the fill.
@MainActor
private func commentInk(
    _ editor: ManuscriptTextView,
    _ anchor: NSRange,
    _ background: (Int, Int, Int),
    _ name: String,
) throws -> (filled: Int, contrast: Double) {
    editor.prepareForPointerInteraction()
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
    editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
    try writingSave(bitmap, name)
    let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (0, 0, 0))
    let text = editor.string as NSString
    var rects: [CGRect] = []
    for offset in anchor.location ..< min(NSMaxRange(anchor), anchor.location + 40) {
        guard let scalar = Unicode.Scalar(text.character(at: offset)), CharacterSet.letters.contains(scalar),
              let rect = editor.characterRect(at: offset)?.offsetBy(
                  dx: -editor.textContainerOrigin.x,
                  dy: -editor.textContainerOrigin.y,
              )
        else {
            continue
        }
        rects.append(rect)
    }
    let drawn = try #require(commonestColour(canvas, rects))
    print("COMMENTS fill \(name): drawn \(drawn)")
    #expect(isAmber(drawn, over: background), "\(name): the fill \(drawn) is not amber over the page")
    var filled = 0, contrast = 0.0
    for rect in rects {
        filled += canvas.matching(in: rect) { red, green, blue in commentDistance((red, green, blue), drawn) <= 4 }
        var strongest = drawn, farthest = 0
        _ = canvas.matching(in: rect) { red, green, blue in
            let away = commentDistance((red, green, blue), drawn)
            if away > farthest {
                farthest = away
                strongest = (red, green, blue)
            }
            return false
        }
        contrast = max(contrast, commentContrast(strongest, drawn))
    }
    return (filled, contrast)
}

/// The commonest colour in `rects`, other than near-black or near-white ink.
@MainActor
private func commonestColour(_ canvas: WritingCanvas, _ rects: [CGRect]) -> (Int, Int, Int)? {
    var counts: [Int: Int] = [:]
    for rect in rects {
        _ = canvas.matching(in: rect) { red, green, blue in
            counts[red << 16 | green << 8 | blue, default: 0] += 1
            return false
        }
    }
    return counts.max { $0.value < $1.value }.map { ($0.key >> 16, $0.key >> 8 & 255, $0.key & 255) }
}

/// Amber over `page`: redder than it is blue, and not the page.
private func isAmber(_ colour: (Int, Int, Int), over page: (Int, Int, Int)) -> Bool {
    colour.0 - colour.2 >= 25 && colour.0 >= colour.1 && commentDistance(colour, page) >= 20
}

private func commentDistance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}

private func commentComposite(_ ink: (Int, Int, Int), over page: (Int, Int, Int), alpha: CGFloat) -> (Int, Int, Int) {
    func mix(_ a: Int, _ b: Int) -> Int {
        Int((CGFloat(a) * alpha + CGFloat(b) * (1 - alpha)).rounded())
    }
    return (mix(ink.0, page.0), mix(ink.1, page.1), mix(ink.2, page.2))
}

/// The WCAG contrast ratio of two sRGB colours.
private func commentContrast(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
    func linear(_ value: Int) -> Double {
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    func luminance(_ c: (Int, Int, Int)) -> Double {
        0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// What a test that does not edit must leave as it was.
@MainActor
private struct CommentUndo: Equatable {
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String

    init(_ editor: ManuscriptTextView) {
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
    }
}
