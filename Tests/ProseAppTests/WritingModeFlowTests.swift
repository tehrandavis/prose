import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import ProseTestSupport
import Testing

/// Phase 3 step D: Writing mode drawn in the editor's layout layer, on the
/// real window, editor and engine. Each test turns on the hidden default
/// `WritingModeEnabled` and restores it. Pictures of the editor go to
/// `PROSE_WRITING_OUTPUT`, or a folder in the test temporary directory.
extension WritingFlowTests {
    @Test func writingModeEntryAndExitLeaveTheStorageSelectionAndUndoUntouched() async throws {
        let restore = writingModeDefault(true)
        defer { restore() }
        let app = try WritingFixture(text: writingSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let undo = try #require(editor.undoManager)
        let end = (editor.string as NSString).length
        editor.insertSnippet(Snippet(text: "One. "), replacing: NSRange(location: end, length: 0), focus: false)
        await app.layout()
        editor.insertSnippet(Snippet(text: "Two. "), replacing: NSRange(location: end + 5, length: 0), focus: false)
        undo.undo()
        let paragraph = (editor.string as NSString).range(of: "on its first source line")
        editor.setSelectedRange(NSRange(location: paragraph.location, length: 12))
        await app.layout()
        let code = writingFragments(manager)
        let before = WritingSnapshot(editor)
        let revision = app.workspace.revision
        #expect(before.canUndo && before.canRedo && before.undoName == "Insert Content")

        let model = try await enterWritingMode(app)
        let shown = writingFragments(manager)
        let anyRendered = shown.contains(where: \.isRendered), anyPill = shown.contains(where: \.isPill)
        #expect(anyRendered, "No block was drawn rendered")
        #expect(anyPill, "The #set line was not drawn as a pill")
        #expect(WritingSnapshot(editor) == before)
        #expect(app.workspace.revision == revision)
        #expect(app.workspace.text == editor.string)
        expectPlainStorage(editor)
        // The block holding the selection's moving end stays source.
        let active = try #require(model.activeBlock)
        #expect(model.state(ofBlockAt: active) == .source(.active))

        // Entering again does nothing; leaving puts every paragraph back.
        app.workspace.setMode(.writing)
        app.workspace.setMode(.code)
        #expect(!editor.writing.isRunning)
        await app.layout()
        let back = writingFragments(manager)
        #expect(back.allSatisfy { $0.role == .source })
        #expect(back.map(\.offset) == code.map(\.offset))
        for (left, right) in zip(back, code) {
            #expect(
                abs(left.frame.height - right.frame.height) < 0.5,
                "Paragraph \(left.offset) changed height \(left.frame) \(right.frame) of \((editor.string as NSString).length)",
            )
            #expect(abs(left.frame.minY - right.frame.minY) < 0.5, "Paragraph \(left.offset) moved")
        }
        #expect(WritingSnapshot(editor) == before)
        #expect(app.workspace.revision == revision)
        expectPlainStorage(editor)

        // Round trips keep it all; undo still undoes the snippet.
        for _ in 0 ..< 2 {
            _ = try await enterWritingMode(app)
            app.workspace.setMode(.code)
        }
        #expect(WritingSnapshot(editor) == before)
        undo.undo()
        #expect(!editor.string.contains("One. "))
        #expect(app.workspace.text == editor.string)
    }

    @Test func writingModeRenderedHeightsFollowTheEngine() async throws {
        let restore = writingModeDefault(true)
        defer { restore() }
        let app = try WritingFixture(text: writingSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let model = try await enterWritingMode(app)
        let fragments = writingFragments(manager)
        var rendered = 0
        for fragment in fragments {
            guard case let .rendered(_, block) = fragment.role else {
                continue
            }
            rendered += 1
            let index = try #require(model.blocks.firstIndex { $0.range == block })
            guard case let .rendered(engine) = model.state(ofBlockAt: index) else {
                Issue.record("Block \(block) is drawn rendered but the model has \(model.state(ofBlockAt: index))")
                continue
            }
            #expect(abs(fragment.frame.height - engine.height) < 0.5, "Block \(block) height")
            #expect(abs(engine.height - engine.drawnRect.height * WritingMetrics.scale) < 0.01)
            #expect(try engine.appearance.columnWidth == Double(#require(editor.textContainer).size.width))
        }
        #expect(rendered >= 4)
        for fragment in fragments where fragment.role == .collapsed {
            #expect(fragment.frame.height == 0)
        }
        for fragment in fragments where fragment.isPill {
            #expect(fragment.frame.height == WritingMetrics.pillFragmentHeight)
        }
        for (previous, next) in zip(fragments, fragments.dropFirst()) {
            #expect(
                abs(next.frame.minY - previous.frame.maxY) < 0.5,
                "\(next.offset) does not follow \(previous.offset)",
            )
        }
        let usage = manager.usageBoundsForTextContainer
        let last = try #require(fragments.last)
        #expect(abs(usage.maxY - last.frame.maxY) < 1)
        print(
            "WRITING heights: \(rendered) rendered, usage \(usage.height), entry with renders \(String(describing: editor.writing.enteredWithRenders))",
        )
    }

    @Test func writingModeDrawsRendersPillsAndSource() async throws {
        let restore = writingModeDefault(true)
        defer { restore() }
        let source = writingSource.replacingOccurrences(
            of: "Plain paragraph after the code.",
            with: "Plain paragraph after the code.\n\n#this-function-does-not-exist()",
        )
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let text = editor.string as NSString
        editor.setSelectedRange(NSRange(location: text.length, length: 0))
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        await app.layout()
        writingScrollToTop(editor)
        let fragments = writingFragments(manager)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        let drawsBefore = fragments.map { $0.fragment?.draws ?? [:] }
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-mode-light.png")
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        let drew = zip(fragments, drawsBefore).map { fragment, before in
            (fragment, (fragment.fragment?.draws ?? [:]).merging(before) { $0 - $1 })
        }

        // Rendered fragments draw their image, the right way up.
        let paragraph = text.range(of: "A paragraph with inline math")
        let block = try #require(fragments.first { $0.offset == paragraph.location })
        guard case let .rendered(rendering, range) = block.role else {
            Issue.record("The three-line paragraph is not rendered: \(block.role)")
            return
        }
        #expect(canvas.ink(in: block.frame) > 50)
        var checked = 0, inked = 0
        for glyph in rendering.glyphs where glyph.rect.width > 0.5 && glyph.rect.height > 0.5 {
            guard let offset = rendering.offset(of: glyph, blockAt: range.location), offset < text.length,
                  let scalar = Unicode.Scalar(text.character(at: offset)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar)
            else {
                continue
            }
            let scale = rendering.scale
            let box = CGRect(
                x: block.frame.minX + glyph.rect.minX * scale,
                y: block.frame.minY + (glyph.rect.minY - rendering.drawnRect.minY) * scale,
                width: glyph.rect.width * scale,
                height: glyph.rect.height * scale,
            )
            checked += 1
            inked += canvas.ink(in: box) > 0 ? 1 : 0
        }
        print("WRITING glyph boxes with ink: \(inked) of \(checked)")
        #expect(checked > 40 && Double(inked) >= Double(checked) * 0.95)

        // Collapsed lines draw nothing: no source below the block, in the blank
        // line that follows it.
        let later = fragments.filter { $0.offset > range.location && $0.offset < NSMaxRange(range) }
        #expect(later.count == 2 && later.allSatisfy { $0.role == .collapsed && $0.frame.height == 0 })
        for (fragment, draws) in drew where fragment.role == .collapsed {
            #expect(draws["source", default: 0] == 0)
        }
        let blank = try #require(fragments.first { $0.offset > NSMaxRange(range) })
        #expect(blank.role == .source && blank.frame.height > 4)
        #expect(canvas.ink(in: blank.frame.insetBy(dx: 0, dy: 1)) == 0, "Source drawn under the rendered block")
        #expect(drew.contains { $0.0.isRendered && $0.1["rendered", default: 0] > 0 })

        // A pill for the #set line, muted for the comment.
        let set = try #require(fragments.first { $0.offset == 0 })
        #expect(set.isPill)
        #expect(canvas.ink(in: set.frame) > 50)
        let comment = try #require(fragments.first { $0.offset == text.range(of: "// A comment").location })
        guard case let .pill(pill) = comment.role else {
            Issue.record("The comment is not a pill: \(comment.role)")
            return
        }
        #expect(pill.muted && pill.text.hasPrefix("// A comment"))
        if case let .pill(setPill) = set.role {
            #expect(!setPill.muted && setPill.text == "#set par(justify: false)")
        }

        // The raw fence and the failing block draw as source.
        let raw = try #require(fragments.first { $0.offset == text.range(of: "```py").location })
        #expect(raw.role == .source)
        #expect(canvas.ink(in: raw.frame) > 0)
        let failing = text.range(of: "#this-function-does-not-exist()")
        let failed = try #require(fragments.first { $0.offset == failing.location })
        #expect(failed.role == .source)
        let index = try #require(model.blocks.firstIndex { $0.range.location == failing.location })
        guard case .source(.failed) = model.state(ofBlockAt: index) else {
            Issue.record("The failing block is \(model.state(ofBlockAt: index))")
            return
        }
        #expect(canvas.ink(in: failed.frame) > 0)

        // The failed full compile marks rendered fragments with an amber bar.
        #expect(model.stale && editor.writing.stale)
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-mode-stale.png")
        let bar = CGRect(x: WritingMetrics.staleBar.minX, y: block.frame.minY, width: 3, height: block.frame.height)
        #expect(
            canvas.amber(in: bar.insetBy(dx: 0.5, dy: 2)),
            "No amber bar beside a stale render: \(canvas.color(at: bar))",
        )
        #expect(!canvas.amber(in: CGRect(x: -9, y: raw.frame.minY, width: 3, height: raw.frame.height)
                .insetBy(dx: 0.5, dy: 2)))
        expectPlainStorage(editor)
    }

    @Test func writingModeOpensTheCaretsBlockAtOnceAndClosesItAfterARender() async throws {
        let restore = writingModeDefault(true)
        defer { restore() }
        let app = try WritingFixture(text: writingSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let text = editor.string as NSString
        let last = text.range(of: "The last paragraph.").location
        editor.setSelectedRange(NSRange(location: last, length: 0))
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        await app.layout()
        let paragraph = text.range(of: "A paragraph with inline math").location
        func role(_ offset: Int) -> WritingRole? {
            writingFragments(manager).first { $0.offset == offset }?.role
        }
        #expect(role(paragraph)?.isRendered == true)
        let lines = writingFragments(manager).filter { $0.offset >= paragraph }.prefix(3)

        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (255, 255, 255))
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        let closedFrame = try #require(lines.first).frame

        // Entry: source in the same run loop turn, with the caret's line in place.
        let caret = text.range(of: "on its first source line").location
        guard case let .rendered(closed, _) = try #require(lines.first).role else {
            Issue.record("The paragraph is not rendered")
            return
        }
        let glyph = try #require(closed.glyphs.first { closed.offset(of: $0, blockAt: paragraph) == caret })
        let before = closedFrame.minY + (glyph.rect.minY - closed.drawnRect.minY) * closed.scale -
            editor.containerVisibleRect().minY
        let drawsBefore = lines.map { $0.fragment?.draws["source", default: 0] ?? 0 }
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        #expect(role(paragraph) == .source)
        let opened = writingFragments(manager).filter { $0.offset >= paragraph }.prefix(3)
        #expect(opened.allSatisfy { $0.role == .source && $0.frame.height > 4 })
        #expect(lines.map(\.offset) == opened.map(\.offset))
        // The same fragment objects: the swap is invalidateLayout(for:).
        #expect(zip(lines, opened).allSatisfy { $0.fragment === $1.fragment })
        let caretRect = try #require(TextKit2Geometry.caretRect(at: caret, in: manager))
        let after = caretRect.minY - editor.containerVisibleRect().minY
        print("WRITING caret entry: caret line \(before) -> \(after) from the top of the view")
        #expect(abs(after - before) < 12, "The caret's line moved from \(before) to \(after)")
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-mode-caret-open.png")
        for (index, line) in opened.enumerated() {
            #expect(
                (line.fragment?.draws["source", default: 0] ?? 0) > drawsBefore[index],
                "Line \(line.offset) did not draw source",
            )
            #expect(canvas.ink(in: line.frame) > 20, "No source text in line \(line.offset)")
        }

        // Typing drops the render; leaving waits for a new one.
        editor.insertText("new ", replacementRange: NSRange(location: caret, length: 0))
        #expect(role(paragraph) == .source)
        editor.setSelectedRange(NSRange(location: last, length: 0))
        #expect(role(paragraph) == .source, "The edited block closed before its render arrived")
        await model.idle()
        await app.layout()
        guard case let .rendered(rendering, block) = role(paragraph) else {
            Issue.record("The edited block did not close after its render")
            return
        }
        #expect(block.location == paragraph)
        #expect(rendering.origin == paragraph)
        // Typing rebuilt the paragraph's fragment; the new one draws the render.
        let reclosed = try #require(writingFragments(manager).first { $0.offset == paragraph })
        let renderedDraws = reclosed.fragment?.draws["rendered", default: 0] ?? 0
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-mode-caret-closed.png")
        #expect((reclosed.fragment?.draws["rendered", default: 0] ?? 0) > renderedDraws)
        #expect(abs(reclosed.frame.height - rendering.height) < 0.5)
        #expect(canvas.ink(in: reclosed.frame) > 50)
        #expect(model.blocks.contains { $0.range.location == paragraph })

        // A selection from the paragraph into the heading opens only the block
        // of its moving end.
        let heading = text.range(of: "= Writing heading").location
        editor.setSelectedRange(NSRange(location: paragraph + 3, length: 0))
        editor.setSelectedRange(NSRange(location: heading + 2, length: paragraph + 3 - heading - 2))
        #expect(editor.writing.caret == heading + 2)
        #expect(role(heading) == .source)
        await model.idle()
        #expect(role(paragraph)?.isRendered == true)
        expectPlainStorage(editor)
    }

    @Test func writingModeRendersAgainInDarkAppearance() async throws {
        let restore = writingModeDefault(true)
        defer { restore() }
        let app = try WritingFixture(text: writingSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let text = editor.string as NSString
        editor.setSelectedRange(NSRange(location: text.length, length: 0))
        app.window.appearance = NSAppearance(named: .aqua)
        let model = try await enterWritingMode(app)
        let paragraph = text.range(of: "A paragraph with inline math").location
        func rendering() -> WritingRendering? {
            if case let .rendered(rendering, _) = writingFragments(manager).first(where: { $0.offset == paragraph })?
                .role
            {
                return rendering
            }
            return nil
        }
        let light = try #require(rendering())
        #expect(light.appearance.textColor == nil)

        app.window.appearance = NSAppearance(named: .darkAqua)
        await app.layout()
        await model.idle()
        await app.layout()
        let dark = try #require(rendering())
        #expect(dark.appearance.textColor == WritingController.darkTextColor)
        #expect(dark != light)
        #expect(dark.appearance.bitmapScale == light.appearance.bitmapScale)

        writingScrollToTop(editor)
        await app.layout()
        let block = try #require(writingFragments(manager).first { $0.offset == paragraph })
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        try writingSave(bitmap, "writing-mode-dark.png")
        let canvas = WritingCanvas(editor: editor, bitmap: bitmap, background: (0x26, 0x26, 0x26))
        #expect(canvas.ink(in: block.frame) > 50)
        #expect(canvas.brightInk(in: block.frame) > 50, "Rendered text is not light on the dark page")
        expectPlainStorage(editor)
    }

    @Test func writingModeStaysOffWithoutTheHiddenDefault() throws {
        let restore = writingModeDefault(false)
        defer { restore() }
        let app = try WritingFixture(text: writingSource, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        #expect(!EditorMode.writing.isAvailable && EditorMode.code.isAvailable && !EditorMode.focus.isAvailable)
        app.workspace.message = nil
        app.workspace.setMode(.writing)
        #expect(app.workspace.editorMode == .code)
        #expect(app.workspace.message == L10n.text("Writing and Focus modes arrive in a later version of Prose."))
        #expect(!editor.writing.isRunning)
        #expect(app.workspace.writingEngine == nil && app.workspace.writingEngineRequest == nil)
        #expect(editor.textLayoutManager?.delegate == nil)

        // With the default, Writing works and Focus stays refused.
        UserDefaults.standard.set(true, forKey: WritingController.defaultsKey)
        #expect(EditorMode.writing.isAvailable)
        app.workspace.message = nil
        app.workspace.setMode(.focus)
        #expect(app.workspace.editorMode == .code && app.workspace.message != nil)
    }

    @Test func writingModeKeepsTheEngineWithinAProjectAndReplacesItForAnother() async throws {
        let restore = writingModeDefault(true)
        defer { restore() }
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let manager = FileManager.default
        let thesis = app.root.appendingPathComponent("Thesis")
        try manager.createDirectory(at: thesis.appendingPathComponent("sections"), withIntermediateDirectories: true)
        let main = thesis.appendingPathComponent("main.typ").standardizedFileURL
        let method = thesis.appendingPathComponent("sections/method.typ").standardizedFileURL
        try Data("= Thesis\n\nIntroduction text.\n\n#include \"sections/method.typ\"\n".utf8).write(to: main)
        try Data("= Method\n\nThe method, in a paragraph.\n".utf8).write(to: method)
        let other = app.root.appendingPathComponent("Other")
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("= Other\n\nAnother project.\n".utf8).write(to: other.appendingPathComponent("main.typ"))

        #expect(app.workspace.openFolder(thesis))
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let model = try await enterWritingMode(app)
        let first = try #require(app.workspace.writingEngine)
        #expect(first.key == WritingEngineKey(root: thesis.standardizedFileURL, main: main))
        #expect(model.file == main)
        #expect(app.workspace.writingEnginesCreated == 1)

        // Another file of the project: the same engine, the chapter's text.
        app.workspace.openProjectFile(method)
        try await app.wait { editor.writing.model?.file == method }
        #expect(app.workspace.writingEngine?.renderer === first.renderer)
        #expect(editor.writing.renderer === first.renderer)
        await model.idle()
        #expect(model.blocks.count == 2)
        #expect(model.blocks.last
            .map { NSMaxRange($0.range) } == ("= Method\n\nThe method, in a paragraph." as NSString).length)
        #expect(app.workspace.writingEnginesCreated == 1)

        // A change on disk to another file of the project reaches the engine.
        let updates = app.workspace.writingDiskUpdates
        try Data("= Thesis, revised\n\n#include \"sections/method.typ\"\n".utf8).write(to: main)
        try await app.wait { app.workspace.writingDiskUpdates > updates }

        // Code mode keeps the engine; another project replaces it.
        app.workspace.setMode(.code)
        #expect(app.workspace.writingEngine?.renderer === first.renderer)
        app.workspace.setMode(.writing)
        try await app.wait { editor.writing.isRunning }
        #expect(app.workspace.writingEnginesCreated == 1)
        #expect(app.workspace.openFolder(other))
        try await app.wait {
            app.workspace.writingEngine.map { $0.renderer !== first.renderer } == true && editor.writing.isRunning
        }
        #expect(app.workspace.writingEnginesCreated == 2)
        #expect(app.workspace.writingEngine?.key.root == other.standardizedFileURL)
        #expect(editor.writing.renderer !== first.renderer)
        #expect(editor.writing.model !== model)

        // The window closing frees it.
        app.workspace.shutdown()
        #expect(app.workspace.writingEngine == nil && editor.writing.renderer == nil && !editor.writing.isRunning)
        expectPlainStorage(editor)
    }
}

// MARK: - Fixture text and helpers

private let writingFiller = (1 ... 30)
    .map { "Filler paragraph \($0), plain text that fills the column so the document scrolls.\n\n" }
    .joined()

private let writingSource = """
#set par(justify: false)

= Writing heading

A paragraph with inline math $a^2 + b^2 = c^2$ on its first source line, long enough
that Typst wraps it, then continues on a second source line with more words for the
engine to set, and ends on a third source line.

$ integral_0^1 x^2 dif x = 1/3 $

```py
def raw(): return 1
```

// A comment on its own.

Plain paragraph after the code.

\(writingFiller)The last paragraph.

"""

/// Sets the hidden default and returns a closure that restores it.
func writingModeDefault(_ enabled: Bool) -> () -> Void {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: WritingController.defaultsKey)
    defaults.set(enabled, forKey: WritingController.defaultsKey)
    return {
        if let previous {
            defaults.set(previous, forKey: WritingController.defaultsKey)
        } else {
            defaults.removeObject(forKey: WritingController.defaultsKey)
        }
    }
}

/// Enters Writing mode and waits for the engine, the first renders and the
/// end of the entry window. The helpers from here on are shared with
/// `WritingSelectionFlowTests.swift`.
@MainActor
func enterWritingMode(_ app: WritingFixture) async throws -> WritingLayout {
    let editor = try #require(app.workspace.editor)
    app.workspace.setMode(.writing)
    #expect(app.workspace.editorMode == .writing)
    try await app.wait { editor.writing.isRunning }
    let model = try #require(editor.writing.model)
    await model.idle()
    try await app.wait { editor.writing.enteredWithRenders != nil }
    await model.idle()
    await app.layout()
    return model
}

/// What entering and leaving Writing mode must not change.
@MainActor
private struct WritingSnapshot: Equatable {
    let text: String
    let selection: NSRange
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String
    let redoName: String

    init(_ editor: ManuscriptTextView) {
        text = editor.string
        selection = editor.selectedRange()
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
        redoName = editor.undoManager?.redoActionName ?? ""
    }
}

/// The storage holds only source: no attachments, and TextKit 2 is still on.
@MainActor
func expectPlainStorage(_ editor: ManuscriptTextView) {
    var attachments = 0
    if let storage = editor.textStorage {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            attachments += value == nil ? 0 : 1
        }
    }
    #expect(attachments == 0)
    #expect(editor.string == editor.workspace?.text)
    #expect(!editor.switchedToTextKit1 && editor.textLayoutManager != nil)
}

struct WritingFragmentInfo {
    let offset: Int
    let role: WritingRole
    let frame: CGRect
    let fragment: WritingFragment?

    var isRendered: Bool {
        role.isRendered
    }

    var isPill: Bool {
        if case .pill = role {
            return true
        }
        return false
    }
}

extension WritingRole {
    var isRendered: Bool {
        if case .rendered = self {
            return true
        }
        return false
    }
}

/// Every paragraph's fragment, laid out, in order.
@MainActor
func writingFragments(_ manager: NSTextLayoutManager) -> [WritingFragmentInfo] {
    var result: [WritingFragmentInfo] = []
    manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
        let writing = fragment as? WritingFragment
        result.append(WritingFragmentInfo(
            offset: TextKit2Geometry.offset(of: fragment.rangeInElement.location, in: manager),
            role: writing?.role ?? .source,
            frame: fragment.layoutFragmentFrame,
            fragment: writing,
        ))
        return true
    }
    return result
}

@MainActor
func writingScrollToTop(_ editor: ManuscriptTextView) {
    guard let clip = editor.enclosingScrollView?.contentView else {
        return
    }
    clip.scroll(to: .zero)
    editor.enclosingScrollView?.reflectScrolledClipView(clip)
    editor.prepareForPointerInteraction()
}

/// A picture of the editor's visible rect, read in container coordinates.
@MainActor
struct WritingCanvas {
    let bitmap: NSBitmapImageRep
    let visible: CGRect
    let origin: CGPoint
    let background: (Int, Int, Int)

    init(editor: ManuscriptTextView, bitmap: NSBitmapImageRep, background: (Int, Int, Int)) {
        self.bitmap = bitmap
        visible = editor.visibleRect
        origin = editor.textContainerOrigin
        self.background = background
    }

    private func pixels(in rect: CGRect, _ body: (Int, Int, Int) -> Bool) -> Int {
        let sx = CGFloat(bitmap.pixelsWide) / visible.width, sy = CGFloat(bitmap.pixelsHigh) / visible.height
        let view = rect.offsetBy(dx: origin.x - visible.minX, dy: origin.y - visible.minY)
        let minX = max(0, Int(view.minX * sx)), maxX = min(bitmap.pixelsWide - 1, Int(ceil(view.maxX * sx)) - 1)
        let minY = max(0, Int(view.minY * sy)), maxY = min(bitmap.pixelsHigh - 1, Int(ceil(view.maxY * sy)) - 1)
        guard minX <= maxX, minY <= maxY else {
            return 0
        }
        var count = 0
        for y in minY ... maxY {
            for x in minX ... maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let red = Int(color.redComponent * 255), green = Int(color.greenComponent * 255)
                let blue = Int(color.blueComponent * 255)
                count += body(red, green, blue) ? 1 : 0
            }
        }
        return count
    }

    /// Pixels in `rect` that differ from the page.
    func ink(in rect: CGRect) -> Int {
        pixels(in: rect) { red, green, blue in
            abs(red - background.0) > 24 || abs(green - background.1) > 24 || abs(blue - background.2) > 24
        }
    }

    /// Pixels in `rect` tinted with the light selection colour (#F2E9F4), or
    /// ink drawn over it: red and blue above green. Black ink, its grey edges,
    /// pills and the inactive grey selection have none.
    func selected(in rect: CGRect) -> Int {
        pixels(in: rect) { red, green, blue in red - green >= 4 && blue - green >= 4 }
    }

    /// Every pixel in `rect`.
    func count(in rect: CGRect) -> Int {
        pixels(in: rect) { _, _, _ in true }
    }

    /// Light pixels: text drawn in the dark appearance's colour.
    func brightInk(in rect: CGRect) -> Int {
        pixels(in: rect) { red, green, blue in red > 160 && green > 160 && blue > 150 }
    }

    /// Whether `rect` is mostly the stale bar's amber, #E8A838 in sRGB.
    func amber(in rect: CGRect) -> Bool {
        let total = pixels(in: rect) { _, _, _ in true }
        let amber = pixels(in: rect) { red, green, blue in
            // The display profile moves it; it stays a saturated orange-yellow.
            red > 200 && green > 140 && green < 210 && blue < 140 && red - blue > 90
        }
        return total > 0 && amber * 2 > total
    }

    /// The colour in the middle of `rect`, for messages.
    func color(at rect: CGRect) -> String {
        var found = ""
        _ = pixels(in: CGRect(x: rect.midX, y: rect.midY, width: 0.5, height: 0.5)) { red, green, blue in
            found = "\(red),\(green),\(blue)"
            return true
        }
        return found
    }
}

func writingSave(_ bitmap: NSBitmapImageRep, _ name: String) throws {
    let path = ProcessInfo.processInfo.environment["PROSE_WRITING_OUTPUT"]
    let folder = path.map { URL(fileURLWithPath: $0) } ?? TestPaths.temporaryDirectory
        .appendingPathComponent("writing-mode")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: folder.appendingPathComponent(name))
}
