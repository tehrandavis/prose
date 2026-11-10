import AppKit
import CoreText
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 6 step D: the open block, acceptance tests 8 to 13 of the Quiet
/// Writing note, on the real window, editor and engine. The block that holds
/// the caret draws in the document's font at Writing mode's scale, with
/// faint markers, through the content storage delegate and rendering
/// attributes; the text storage never changes. Numbers are printed with the
/// prefix `OPENBLOCK`. Every test also checks that the storage holds only
/// the source, that TextKit 2 is still on, and that the undo stack is
/// unchanged unless the test edits.
extension WritingFlowTests {
    /// Acceptance test 8: an open paragraph's lines use the font the engine
    /// reported, at its size times the scale, in Writing and in Focus; an
    /// open heading uses the heading's font and size. Ten opens and closes
    /// leave the storage's attributes as Code mode had them.
    @Test func openBlockAcceptance8OpenBlocksUseTheEnginesFontAtTheScale() async throws {
        let app = try WritingFixture(text: WelcomeDocument.source(), startService: false)
        defer { app.close() }
        try WelcomeDocument.prepareAssets(in: app.root)
        let text = WelcomeDocument.source() as NSString
        let first = text.range(of: "A sentence, a sketch").location
        let second = text.range(of: "This document is yours").location
        let third = text.range(of: "Headings give an idea").location
        let heading = text.range(of: "= Write in Typst").location
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let storage = try #require(editor.textStorage)
        let codeMode = NSAttributedString(attributedString: storage)
        let (manager, model) = try await openQuietBlock(app, caret: first + 4)
        let undo = QuietUndo(editor)
        let renderer = try #require(editor.writing.renderer)

        let open = try #require(model.openBlock)
        #expect(open.kind == .paragraph && open.span.location == first)
        let font = try #require(model.textFont(at: first))
        let info = try #require(await renderer.fontInfo(font.id))
        print("OPENBLOCK font family=\(info.family) size=\(font.size) pitch=\(font.linePitch ?? 0)")
        #expect(info.family == "Libertinus Serif")
        let made = try #require(app.workspace.documentFonts.font(font.id, size: font.size * 1.3, in: renderer))
        try expectLineFonts(manager, text, in: open.span, base: made, size: font.size * 1.3, "Writing paragraph")

        // Heights: the open block against its render.
        var heights: [String] = []
        for (name, offset) in [("first", first), ("second", second), ("third", third), ("heading", heading)] {
            let rendered = try await renderedHeight(app, editor, model, at: offset)
            editor.setSelectedRange(NSRange(location: offset + 3, length: 0))
            try await waitForOpenFonts(app, editor, scale: WritingMetrics.scale)
            await app.layout()
            let span = try #require(model.openBlock?.span)
            let opened = openHeight(manager, span)
            heights.append(String(format: "%@ rendered=%.1f open=%.1f", name, rendered, opened))
            #expect(abs(opened - rendered) < max(12, rendered * 0.35), "\(name): open \(opened), rendered \(rendered)")
        }
        print("OPENBLOCK heights " + heights.joined(separator: "; "))

        // The heading opens in the heading's font and size.
        editor.setSelectedRange(NSRange(location: heading + 4, length: 0))
        try await waitForOpenFonts(app, editor, scale: WritingMetrics.scale)
        let headingBlock = try #require(model.openBlock)
        #expect(headingBlock.kind == .heading)
        let headingFont = try #require(model.textFont(at: heading))
        print("OPENBLOCK heading size=\(headingFont.size)")
        #expect(headingFont.size > font.size * 2)
        let headingMade = try #require(app.workspace.documentFonts.font(
            headingFont.id, size: headingFont.size * 1.3, in: renderer,
        ))
        try expectLineFonts(
            manager, editor.string as NSString, in: NSRange(location: heading + 2, length: 14),
            base: headingMade, size: headingFont.size * 1.3, "Writing heading",
        )

        // Ten opens and closes.
        for trip in 0 ..< 10 {
            editor.setSelectedRange(NSRange(location: (trip.isMultiple(of: 2) ? first : second) + 5, length: 0))
            #expect(editor.styler?.openBlock?.span == model.openBlock?.span)
        }
        await app.layout()
        #expect(storage.isEqual(to: codeMode), "Opening blocks changed the storage's attributes")

        // Focus: the same font at Focus's scale.
        editor.setSelectedRange(NSRange(location: first + 4, length: 0))
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.isRunning }
        try await waitForOpenFonts(app, editor, scale: WritingMetrics.focusScale)
        await app.layout()
        let focusMade = try #require(app.workspace.documentFonts.font(
            font.id, size: font.size * WritingMetrics.focusScale, in: renderer,
        ))
        try expectLineFonts(
            manager, editor.string as NSString, in: #require(model.openBlock?.span),
            base: focusMade, size: font.size * WritingMetrics.focusScale, "Focus paragraph",
        )

        // Leaving: every font and colour as in Code mode.
        app.workspace.setMode(.code)
        await app.layout()
        #expect(editor.styler?.openBlock == nil)
        #expect(editor.styler?.colors.overlay == nil)
        #expect(storage.isEqual(to: codeMode), "The storage's attributes differ from Code mode's")
        let codeFont = try #require(lineFont(manager, first + 4))
        #expect(codeFont.isFixedPitch, "Code mode draws \(codeFont.fontName)")
        #expect(QuietUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 9: in an open block the ink of `*`, `_`, `=`, `-`,
    /// `#emph[`, `]` and `@key` has the faint colour and the ink of the
    /// words the text colour, in light and dark.
    @Test(arguments: [false, true])
    func openBlockAcceptance9MarkersDrawFaintAndWordsInTheTextColour(dark: Bool) async throws {
        let app = try WritingFixture(text: markerSource, startService: false)
        defer { app.close() }
        let text = markerSource as NSString
        let heading = text.range(of: "= Marker heading").location
        let paragraph = text.range(of: "Words with").location
        let list = text.range(of: "- list item").location
        try await openQuietBlock(app, caret: paragraph + 2, dark: dark)
        let editor = try #require(app.workspace.editor)
        let undo = QuietUndo(editor)
        let background = dark ? (38, 38, 38) : (255, 255, 255)
        let ink = dark ? (0xD5, 0xD9, 0xDE) : (0x37, 0x47, 0x4F)
        let faint = composite(ink, over: background, alpha: Theme.faintOpacity)
        let cases: [(caret: Int, markers: [String], words: [String])] = [
            (heading + 4, ["="], ["Marker"]),
            (paragraph + 2, ["*", "_", "#emph[", "]", "@key"], ["Words", "strong", "called"]),
            (list + 4, ["-"], ["list"]),
        ]
        var markerContrasts: [Double] = [], wordContrasts: [Double] = []
        print("OPENBLOCK colour backing scale \(app.window.backingScaleFactor)")
        for (index, test) in cases.enumerated() {
            editor.setSelectedRange(NSRange(location: test.caret, length: 0))
            try await waitForOpenFonts(app, editor, scale: WritingMetrics.scale)
            editor.reveal(editor.selectedRange())
            await app.layout()
            let block = try #require(editor.styler?.openBlock?.span)
            let canvas = try quietCanvas(
                editor,
                background,
                "open-block-colours-\(dark ? "dark" : "light")-\(index).png",
            )
            let source = editor.string as NSString
            // A stroke of the book face at this size does not cover a whole
            // device pixel, so the strongest ink of a word is lighter than
            // the text colour; a marker's is the faint opacity of that.
            let wordInk = try #require(strongest(
                canvas,
                editor,
                locate(test.words[0], in: source, within: block),
                background,
            ))
            let expectedMarker = composite(wordInk, over: background, alpha: Theme.faintOpacity)
            for marker in test.markers {
                let range = try locate(
                    marker,
                    in: source,
                    within: block,
                    // The `]` that closes `#emph[called]`.
                    after: marker == "]" ? "called" : nil,
                )
                let colour = try #require(strongest(canvas, editor, range, background), "No ink for \(marker)")
                let contrast = contrastRatio(colour, background)
                markerContrasts.append(contrast)
                print(
                    "OPENBLOCK colour \(dark ? "dark" : "light") marker \(marker) ink=\(colour) faint=\(faint) contrast=\(String(format: "%.2f", contrast))",
                )
                #expect(
                    distance(colour, expectedMarker) <= 24,
                    "\(marker) draws \(colour), not the faint colour (\(expectedMarker) at this coverage)",
                )
            }
            for word in test.words {
                let range = try locate(word, in: source, within: block)
                let colour = try #require(strongest(canvas, editor, range, background), "No ink for \(word)")
                let contrast = contrastRatio(colour, background)
                wordContrasts.append(contrast)
                print(
                    "OPENBLOCK colour \(dark ? "dark" : "light") word \(word) ink=\(colour) text=\(ink) contrast=\(String(format: "%.2f", contrast))",
                )
                #expect(distance(colour, ink) <= 40, "\(word) draws \(colour), not the text colour \(ink)")
            }
        }
        let expected = contrastRatio(faint, background)
        print(String(
            format: "OPENBLOCK contrast %@ faint=%.2f (composited) markers %.2f to %.2f, words %.2f to %.2f",
            dark ? "dark" : "light", expected, markerContrasts.min() ?? 0, markerContrasts.max() ?? 0,
            wordContrasts.min() ?? 0, wordContrasts.max() ?? 0,
        ))
        #expect(expected >= 2)
        #expect(QuietUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 10: the caret moves through 200 paragraphs of SICP.
    /// No move writes the storage's attributes, and none writes a rendering
    /// attribute outside the block that closes and the block that opens.
    /// Prints the added main-thread cost per move.
    @Test(.enabled(
        if: FileManager.default.fileExists(atPath: sicpPath),
        "SICP fixture (Examples/Books/SICP) is absent",
    ))
    func openBlockAcceptance10CaretMovesThroughABookTouchOnlyTwoBlocks() async throws {
        let source = try String(contentsOfFile: sicpPath, encoding: .utf8)
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        for name in ["fig", "styles"] {
            let dependency = URL(fileURLWithPath: sicpPath).deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dependency.path) {
                try FileManager.default.copyItem(at: dependency, to: app.root.appendingPathComponent(name))
            }
        }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let storage = try #require(editor.textStorage)
        let styler = try #require(editor.styler)
        let text = source as NSString
        let start = text.range(of: "This book is dedicated").location
        editor.setSelectedRange(NSRange(location: start + 2, length: 0))
        let model = try await enterWritingMode(app)
        let undo = QuietUndo(editor)
        let paragraphs = model.blocks.filter { $0.kind == .paragraph && $0.range.location >= start }.prefix(201)
        #expect(paragraphs.count == 201)
        let edits = OpenBlockCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil,
        ) { _ in
            edits.events += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            styler.colors.logsWrites = false
        }
        styler.colors.logsWrites = true
        var added: [Double] = [], total: [Double] = []
        var outside = 0, opened = 0, withFonts = 0
        var builtPerMove: [Int] = [], rebuiltPerMove: [Int] = []
        for block in paragraphs {
            let before = styler.openBlock?.span
            styler.colors.resetWriteLog()
            let cost = editor.writing.openBlockCost, built = SourceStyler.openParagraphTime
            let moved = ContinuousClock.now
            SourceStyler.paragraphRequestLog = []
            editor.setSelectedRange(NSRange(location: block.range.location + 1, length: 0))
            let requests = SourceStyler.paragraphRequestLog ?? []
            SourceStyler.paragraphRequestLog = nil
            editor.reveal(editor.selectedRange())
            total.append(milliseconds(ContinuousClock.now - moved))
            added.append(milliseconds(editor.writing.openBlockCost - cost + SourceStyler.openParagraphTime - built))
            let after = styler.openBlock?.span
            // The move builds again the paragraphs of the block that closes
            // and of the one that opens, and TextKit a neighbour or two.
            // Paragraphs coming into view for the first time below them may
            // be built too; nothing above them, and never a run of the book.
            let text = editor.string as NSString
            let spans = [before, after].compactMap(\.self)
            let blockParagraphs = spans.reduce(0) { $0 + text.paragraphCount(of: $1) }
            let low = spans.map(\.location).min() ?? block.range.location
            let high = spans.map { NSMaxRange($0) }.max() ?? NSMaxRange(block.range)
            let near = requests.filter { $0.location >= low && $0.location <= high + 2 }.count
            let above = requests.filter { NSMaxRange($0) <= low && !spans.isEmpty }.count
            builtPerMove.append(requests.count)
            rebuiltPerMove.append(near)
            if near > blockParagraphs + 4 || above > 0 || requests.count > 100 {
                Issue.record(
                    "A move built \(requests.count) paragraphs (\(near) in its blocks of \(blockParagraphs), \(above) above)",
                )
            }
            opened += after == nil ? 0 : 1
            withFonts += styler.openBlock?.fonts == nil ? 0 : 1
            let allowed = [before, after].compactMap(\.self)
            for write in styler.colors.writeLog
                where !allowed.contains(where: { NSIntersectionRange($0, write) == write })
            {
                outside += 1
                Issue.record("A colour write at \(write) lies outside \(allowed)")
            }
            await model.idle()
        }
        #expect(edits.events == 0, "The storage processed \(edits.events) edits")
        #expect(outside == 0)
        let sortedBuilt = builtPerMove.sorted(), sortedRebuilt = rebuiltPerMove.sorted()
        print(
            "OPENBLOCK SICP paragraphs built per move median=\(sortedBuilt[sortedBuilt.count / 2])",
            "max=\(sortedBuilt.last ?? 0); in the two blocks median=\(sortedRebuilt[sortedRebuilt.count / 2])",
            "max=\(sortedRebuilt.last ?? 0)",
        )
        #expect(opened >= 190, "Only \(opened) of the paragraphs opened")
        let sortedAdded = added.dropFirst().sorted(), sortedTotal = total.dropFirst().sorted()
        func p95(_ values: [Double]) -> Double {
            values[min(values.count - 1, values.count * 95 / 100)]
        }
        print(String(
            format: "OPENBLOCK SICP moves=%d opened=%d withFonts=%d added median=%.3f p95=%.3f max=%.3f ms; move median=%.2f p95=%.2f ms",
            sortedAdded.count, opened, withFonts, sortedAdded[sortedAdded.count / 2], p95(sortedAdded),
            sortedAdded.last ?? 0, sortedTotal[sortedTotal.count / 2], p95(sortedTotal),
        ))
        #expect(withFonts >= 150, "Only \(withFonts) paragraphs opened in the document's font")
        #expect(QuietUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 11: a misspelled word in an open block keeps its
    /// underline, and in Focus the open block draws at full contrast with
    /// faint markers.
    @Test func openBlockAcceptance11SpellingUnderlinesAndFocusContrast() async throws {
        let source = """
        A paragraph above the open one.

        Some *strong* words with teh mistake in an open block of plain prose.

        ```py
        def raw(): return 1
        ```

        \(selectionFiller)
        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let text = source as NSString
        let paragraph = text.range(of: "Some *strong*").location
        let teh = text.range(of: "teh")
        app.window.orderFront(nil)
        await app.layout()
        app.workspace.useSpellChecker(QuietSpelling(), timing: SpellCheckTiming(
            pause: .milliseconds(20), viewport: .milliseconds(1),
        ))
        let spelling = app.workspace.spelling
        try await app.wait { spelling.misspellings.contains(teh) }
        let (manager, model) = try await openQuietBlock(app, caret: paragraph + 2)
        let editor = try #require(app.workspace.editor)
        let undo = QuietUndo(editor)
        try await app.wait { spelling.shownMisspellings(in: teh).contains(teh) }
        await app.layout()
        let flag = editor.styler?.colors.value(.spellingState, at: teh.location, effectiveRange: &quietRange) as? Int
        #expect(flag != nil, "No spelling state on the misspelled word")
        let underline = try redInk(editor, under: teh, "open-block-spelling.png")
        print("OPENBLOCK spelling underline points=\(underline)")
        #expect(underline > 6, "No underline under the misspelled word in the open block")

        // Focus: full contrast, faint markers, not dimmed.
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.isRunning }
        try await waitForOpenFonts(app, editor, scale: WritingMetrics.focusScale)
        await model.idle()
        await app.layout()
        let span = try #require(model.openBlock?.span)
        let fragments = writingFragments(manager).filter { NSLocationInRange($0.offset, span) }
        #expect(!fragments.isEmpty && fragments.allSatisfy { $0.fragment?.dimmed == false }, "The open block is dimmed")
        let background = (255, 255, 255)
        let canvas = try quietCanvas(editor, background, "open-block-focus.png")
        let star = NSRange(location: paragraph + 5, length: 1)
        let word = (editor.string as NSString).range(of: "strong")
        let starInk = try #require(strongest(canvas, editor, star, background))
        let wordInk = try #require(strongest(canvas, editor, word, background))
        let faint = composite(wordInk, over: background, alpha: Theme.faintOpacity)
        print("OPENBLOCK focus star=\(starInk) word=\(wordInk)")
        #expect(distance(starInk, faint) <= 24 && distance(wordInk, (0x37, 0x47, 0x4F)) <= 40)
        #expect(try redInk(editor, under: teh, "open-block-focus-spelling.png") > 6)
        #expect(QuietUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Acceptance test 12: a Pinyin composition in an open block keeps the
    /// document's font, and nothing rebuilds or recolours while it is marked.
    @Test func openBlockAcceptance12APinyinCompositionKeepsTheDocumentFont() async throws {
        let source = """
        A paragraph above the open one.

        Plain words of an open paragraph, *strong* and _emphasis_, typed into.

        Another paragraph below it.

        ```py
        def raw(): return 1
        ```

        \(selectionFiller)
        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let text = source as NSString
        let paragraph = text.range(of: "Plain words").location
        let below = text.range(of: "Another paragraph").location
        let (manager, model) = try await openQuietBlock(app, caret: paragraph + 5)
        let editor = try #require(app.workspace.editor)
        let styler = try #require(editor.styler)
        let base = try #require(styler.openBlock?.fonts?.base)
        let changes = editor.writing.openBlockChanges, swaps = editor.writing.swapCount
        let overlay = styler.colors.overlay
        styler.colors.logsWrites = true
        styler.colors.resetWriteLog()
        defer { styler.colors.logsWrites = false }

        typePinyin(editor, "zhong'wen")
        #expect(editor.hasMarkedText())
        manager.textViewportLayoutController.layoutViewport()
        let marked = editor.markedRange()
        let markedFont = try #require(lineFont(manager, marked.location + 1))
        print("OPENBLOCK pinyin marked font=\(markedFont.fontName) \(markedFont.pointSize)")
        #expect(markedFont.fontName == base.fontName, "Marked text draws in \(markedFont.fontName)")
        // The caret moves to another block while marked: nothing changes.
        model.selectionDidChange(caret: below + 3)
        editor.writing.selectionDidChange()
        editor.writing.flush()
        await app.layout()
        #expect(editor.writing.openBlockChanges == changes, "The open block changed while text was marked")
        #expect(editor.writing.swapCount == swaps)
        #expect(styler.colors.writeLog.isEmpty, "Colours were written while text was marked")
        #expect(styler.colors.overlay?.range.location == overlay?.range.location)

        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        manager.textViewportLayoutController.layoutViewport()
        let committed = editor.string as NSString
        let chinese = committed.range(of: "中文")
        #expect(chinese.location == paragraph + 5)
        let cjk = try #require(lineFont(manager, chinese.location))
        let latin = try #require(lineFont(manager, paragraph + 1))
        print("OPENBLOCK pinyin committed cjk=\(cjk.fontName) latin=\(latin.fontName)")
        #expect(latin.fontName == base.fontName && cjk.fontName != base.fontName)
        #expect(committed.components(separatedBy: "中文").count == 2 && !committed.contains("zhong"))
        // Typed at the block's first character, a word joins the open block.
        editor.setSelectedRange(NSRange(location: paragraph, length: 0))
        editor.insertText("Quiet ", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.textViewportLayoutController.layoutViewport()
        #expect(lineFont(manager, paragraph)?.fontName == base.fontName, "Text typed at the start left the open block")
        #expect(styler.openBlock?.span.location == paragraph)
        await model.idle()
        await app.layout()
        #expect(styler.openBlock?.span == model.openBlock?.span && lineFont(manager, paragraph)?.fontName == base
            .fontName)
        #expect(editor.undoManager?.canUndo == true)
        expectPlainStorage(editor)
    }

    /// Acceptance test 13: a document in Libertinus Serif (Typst's default,
    /// not on the Mac) opens its block in Libertinus Serif with no fallback
    /// for Latin text; inline math and call arguments draw in the monospace
    /// font. A display equation, a raw block and an open fold keep the code
    /// look.
    @Test func openBlockAcceptance13LibertinusSerifAndTheCodeLook() async throws {
        let source = """
        = Libertinus heading

        Plain words with $x^2 + y$ math and #text(fill: red)[red words] in the default font.

        #set par(justify: false)
        #set heading(numbering: "1.")

        $ integral_0^1 x dif x $

        ```py
        def raw(): return 1
        ```

        Closing paragraph.

        \(selectionFiller)
        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let text = source as NSString
        let paragraph = text.range(of: "Plain words").location
        let (manager, model) = try await openQuietBlock(app, caret: paragraph + 3)
        let editor = try #require(app.workspace.editor)
        let undo = QuietUndo(editor)
        let renderer = try #require(editor.writing.renderer)
        let font = try #require(model.textFont(at: paragraph))
        let info = try #require(await renderer.fontInfo(font.id))
        #expect(info.family == "Libertinus Serif" && info.embedded)
        #expect(NSFont(name: "LibertinusSerif-Regular", size: 12) == nil, "This Mac has Libertinus Serif installed")
        let span = try #require(model.openBlock?.span)
        let words = ["Plain", "words", "math", "red words", "default", "font"].map { text.range(of: $0, range: span) }
        for word in words {
            for offset in word.location ..< NSMaxRange(word) {
                let drawn = try #require(lineFont(manager, offset))
                var unit = [text.character(at: offset)]
                var glyph: [CGGlyph] = [0]
                #expect(drawn.familyName == "Libertinus Serif", "\(offset) draws \(drawn.fontName)")
                #expect(CTFontGetGlyphsForCharacters(drawn as CTFont, &unit, &glyph, 1), "No glyph at \(offset)")
            }
        }
        let math = text.range(of: "x^2", range: span)
        let arguments = text.range(of: "(fill: red)", range: span)
        for offset in [math.location, math.location + 2, arguments.location + 1, arguments.location + 7] {
            let drawn = try #require(lineFont(manager, offset))
            #expect(drawn.isFixedPitch, "Code at \(offset) draws \(drawn.fontName)")
        }
        print("OPENBLOCK libertinus family=\(info.family) math=\(lineFont(manager, math.location)?.fontName ?? "nil")")

        // The code look: a display equation, a raw block, an open fold.
        let editorFont = try #require(editor.styler?.font(for: .plain))
        let codeLooks = [
            ("equation", text.range(of: "integral").location),
            ("raw", text.range(of: "def raw").location + 2),
            ("fold", text.range(of: "#set heading").location + 3),
        ]
        for (name, offset) in codeLooks {
            editor.setSelectedRange(NSRange(location: offset, length: 0))
            await app.layout()
            #expect(model.openBlock == nil, "\(name) is an open block")
            #expect(editor.styler?.openBlock == nil)
            let drawn = try #require(lineFont(manager, offset))
            #expect(
                drawn.fontName == editorFont.fontName && drawn.pointSize == editorFont.pointSize,
                "\(name): \(drawn)",
            )
        }
        #expect(model.fold(holding: text.range(of: "#set heading").location)?.isOpen == true)
        #expect(QuietUndo(editor) == undo)
        expectPlainStorage(editor)
    }

    /// Pictures of the open block for the design review, written to
    /// `build/pictures` when `PROSE_SAVE_PICTURES=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_SAVE_PICTURES"] == "1"))
    func openBlockPicturesForReview() async throws {
        let text = WelcomeDocument.source() as NSString
        let cases: [(String, Int)] = [
            ("a-setup-row", 0),
            ("b-first-paragraph", text.range(of: "A sentence, a sketch").location + 4),
            ("c-heading", text.range(of: "= Write in Typst").location + 4),
            ("d-strong-markers", text.range(of: "Use *⌘O*").location + 2),
        ]
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let app = try WritingFixture(text: WelcomeDocument.source(), startService: false)
            defer { app.close() }
            try WelcomeDocument.prepareAssets(in: app.root)
            _ = try await openQuietBlock(app, caret: cases[1].1, dark: dark)
            let editor = try #require(app.workspace.editor)
            for (name, caret) in cases {
                editor.setSelectedRange(NSRange(location: caret, length: 0))
                if caret > 0 {
                    try await waitForOpenFonts(app, editor, scale: WritingMetrics.scale)
                }
                editor.reveal(editor.selectedRange())
                await app.layout()
                try savePicture(
                    editor,
                    folder.appendingPathComponent("open-block-\(name)-\(dark ? "dark" : "light").png"),
                )
            }
            if !dark {
                editor.setSelectedRange(NSRange(location: cases[1].1, length: 0))
                app.workspace.setMode(.focus)
                try await app.wait { editor.writing.focused && editor.writing.isRunning }
                try await waitForOpenFonts(app, editor, scale: WritingMetrics.focusScale)
                await editor.writing.model?.idle()
                await app.layout()
                try savePicture(editor, folder.appendingPathComponent("open-block-b-first-paragraph-focus-light.png"))
            }
        }
    }
}

// MARK: - Fixtures and helpers

private let sicpPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/Books/SICP/main.typ").path

/// Every marker kind the colour test measures, in blocks that render.
private let markerSource = """
#set heading(numbering: "1.")

= Marker heading <key>

Words with *strong* and _emph_ and #emph[called] text, see @key here.

- list item words

```py
def raw(): return 1
```

\(selectionFiller)
"""

private nonisolated(unsafe) var quietRange = NSRange()

/// Opens `app`'s document in Writing mode with the caret at `caret`, and
/// waits until the open block draws in the document's fonts.
@MainActor
@discardableResult
private func openQuietBlock(
    _ app: WritingFixture,
    caret: Int,
    dark: Bool = false,
) async throws -> (NSTextLayoutManager, WritingLayout) {
    app.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    app.window.orderFront(nil)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let manager = try #require(editor.textLayoutManager)
    editor.setSelectedRange(NSRange(location: caret, length: 0))
    let model = try await enterWritingMode(app)
    writingScrollToTop(editor)
    await app.layout()
    await model.idle()
    if model.openBlock != nil {
        try await waitForOpenFonts(app, editor, scale: WritingMetrics.scale)
    }
    await app.layout()
    return (manager, model)
}

/// Waits until the open block draws in the document's fonts at `scale`.
@MainActor
private func waitForOpenFonts(_ app: WritingFixture, _ editor: ManuscriptTextView, scale: Double) async throws {
    try await app.wait {
        editor.styler?.openBlock?.fonts != nil && editor.writing.openFontKey?.scale == scale
            && editor.styler?.openBlock?.span == editor.writing.model?.openBlock?.span
    }
    editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
}

/// The font TextKit laid out the character at `offset` in.
@MainActor
private func lineFont(_ manager: NSTextLayoutManager, _ offset: Int) -> NSFont? {
    guard let location = TextKit2Geometry.location(offset, in: manager),
          let fragment = manager.textLayoutFragment(for: location)
    else {
        return nil
    }
    let local = offset - TextKit2Geometry.offset(of: fragment.rangeInElement.location, in: manager)
    for line in fragment.textLineFragments where NSLocationInRange(local, line.characterRange) {
        return line.attributedString.attribute(.font, at: local, effectiveRange: nil) as? NSFont
    }
    return nil
}

/// Every letter in `range` is laid out in `base` at `size`, or in its
/// strong or emphasis face of the same family and size.
@MainActor
private func expectLineFonts(
    _ manager: NSTextLayoutManager,
    _ text: NSString,
    in range: NSRange,
    base: NSFont,
    size: Double,
    _ label: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) throws {
    var letters = 0, inBase = 0
    for offset in range.location ..< NSMaxRange(range) {
        guard let scalar = Unicode.Scalar(text.character(at: offset)), CharacterSet.letters.contains(scalar) else {
            continue
        }
        letters += 1
        let drawn = try #require(
            lineFont(manager, offset),
            "\(label): no line at \(offset)",
            sourceLocation: sourceLocation,
        )
        #expect(
            abs(drawn.pointSize - size) < 0.01 && drawn.familyName == base.familyName,
            "\(label): \(offset) draws \(drawn.fontName) \(drawn.pointSize), not \(base.fontName) \(size)",
            sourceLocation: sourceLocation,
        )
        inBase += drawn.fontName == base.fontName ? 1 : 0
    }
    print(
        "OPENBLOCK fonts \(label): \(inBase) of \(letters) letters in \(base.fontName) \(String(format: "%.2f", size))",
    )
    #expect(letters > 0 && inBase * 2 > letters, "\(label)", sourceLocation: sourceLocation)
}

/// The height block `offset`'s render draws at, once the caret is elsewhere.
@MainActor
private func renderedHeight(
    _ app: WritingFixture,
    _ editor: ManuscriptTextView,
    _ model: WritingLayout,
    at offset: Int,
) async throws -> CGFloat {
    parkAtEnd(editor)
    var height: CGFloat = 0
    try await app.wait {
        if case let .rendered(rendering, _) = role(model, editor.string as NSString, offset) {
            height = rendering.height
            return true
        }
        return false
    }
    return height
}

/// Puts the caret at the end of the text, away from the blocks measured.
@MainActor
private func parkAtEnd(_ editor: ManuscriptTextView) {
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
}

/// The height the open block's paragraphs take.
@MainActor
private func openHeight(_ manager: NSTextLayoutManager, _ span: NSRange) -> CGFloat {
    writingFragments(manager).filter { NSLocationInRange($0.offset, span) }.reduce(0) { $0 + $1.frame.height }
}

/// What a test that does not edit must leave as it was.
@MainActor
private struct QuietUndo: Equatable {
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String

    init(_ editor: ManuscriptTextView) {
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
    }
}

/// `needle` inside `block`, after `after` when given.
private func locate(
    _ needle: String,
    in source: NSString,
    within block: NSRange,
    after: String? = nil,
) throws -> NSRange {
    var range = block
    if let after {
        let anchor = source.range(of: after, range: block)
        range = NSRange(location: NSMaxRange(anchor), length: NSMaxRange(block) - NSMaxRange(anchor))
    }
    let found = source.range(of: needle, range: range)
    try #require(found.location != NSNotFound, "\(needle) is not in the block")
    return found
}

/// A picture of the editor's visible rect on a page of `background`.
@MainActor
private func quietCanvas(
    _ editor: ManuscriptTextView,
    _ background: (Int, Int, Int),
    _ name: String,
) throws -> WritingCanvas {
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
    editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
    try writingSave(bitmap, name)
    return WritingCanvas(editor: editor, bitmap: bitmap, background: background)
}

@MainActor
private func savePicture(_ editor: ManuscriptTextView, _ url: URL) throws {
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
    editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    print("OPENBLOCK picture \(url.path)")
}

/// The colour of the strongest ink over the glyphs of `range`: the pixel
/// farthest from the page, which a glyph's stroke covers fully.
@MainActor
private func strongest(
    _ canvas: WritingCanvas,
    _ editor: ManuscriptTextView,
    _ range: NSRange,
    _ background: (Int, Int, Int),
) -> (Int, Int, Int)? {
    var rect = CGRect.null
    for offset in range.location ..< NSMaxRange(range) {
        if let glyph = editor.characterRect(at: offset) {
            rect = rect.union(glyph.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y))
        }
    }
    guard !rect.isNull else {
        return nil
    }
    var best: (Int, Int, Int)?, bestDistance = 0
    _ = canvas.matching(in: rect) { red, green, blue in
        let away = distance((red, green, blue), background)
        if away > bestDistance {
            bestDistance = away
            best = (red, green, blue)
        }
        return false
    }
    return best
}

private func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
}

private func composite(_ ink: (Int, Int, Int), over page: (Int, Int, Int), alpha: CGFloat) -> (Int, Int, Int) {
    func mix(_ a: Int, _ b: Int) -> Int {
        Int((CGFloat(a) * alpha + CGFloat(b) * (1 - alpha)).rounded())
    }
    return (mix(ink.0, page.0), mix(ink.1, page.1), mix(ink.2, page.2))
}

/// The WCAG contrast ratio of two sRGB colours.
private func contrastRatio(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
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

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// Red ink (the spelling underline's colour) below `word`, counted in the
/// band from the word's middle to 6 pt under it.
@MainActor
private func redInk(_ editor: ManuscriptTextView, under word: NSRange, _ name: String) throws -> Int {
    let first = try #require(editor.characterRect(at: word.location))
    let last = try #require(editor.characterRect(at: NSMaxRange(word) - 1))
    let band = NSRect(x: first.minX - 1, y: first.midY, width: last.maxX - first.minX + 2, height: first.height / 2 + 6)
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: band))
    editor.cacheDisplay(in: band, to: bitmap)
    try writingSave(bitmap, name)
    var count = 0
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               colour.redComponent - max(colour.greenComponent, colour.blueComponent) > 0.2
            {
                count += 1
            }
        }
    }
    return count
}

/// Types `pinyin` as an input method does: marked text growing one key at
/// a time.
@MainActor
private func typePinyin(_ editor: ManuscriptTextView, _ pinyin: String) {
    for end in 1 ... pinyin.count {
        let prefix = String(pinyin.prefix(end))
        editor.setMarkedText(
            prefix,
            selectedRange: NSRange(location: prefix.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
    }
}

/// A checker that reports `teh` only.
@MainActor
private final class QuietSpelling: SpellChecker {
    private var nextTag = 900

    func openDocument() -> Int {
        nextTag += 1
        return nextTag
    }

    func closeDocument(_: Int) {}

    func misspellings(in text: String, ranges: [NSRange], document _: Int) -> [NSRange] {
        let source = text as NSString
        var found: [NSRange] = []
        for range in ranges {
            var search = range
            while true {
                let hit = source.range(of: "teh", range: search)
                guard hit.location != NSNotFound else {
                    break
                }
                found.append(hit)
                search = NSRange(location: NSMaxRange(hit), length: NSMaxRange(range) - NSMaxRange(hit))
            }
        }
        return found
    }

    func ignore(_: String, document _: Int) {}

    func learn(_: String) {}

    func guesses(for _: NSRange, in _: String, document _: Int) -> [String] {
        []
    }
}

private extension NSString {
    /// The paragraphs `range` covers.
    func paragraphCount(of range: NSRange) -> Int {
        var count = 0, cursor = range.location
        while cursor < NSMaxRange(range), cursor < length {
            count += 1
            cursor = NSMaxRange(paragraphRange(for: NSRange(location: cursor, length: 0)))
        }
        return max(count, 1)
    }
}
