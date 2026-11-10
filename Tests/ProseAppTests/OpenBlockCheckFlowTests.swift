import AppKit
import CoreText
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 6 step D, the check of decision 5 (Quiet Writing note): can TextKit
/// 2 be made to ask the content storage delegate again for exactly the open
/// block's paragraphs, with nothing in the storage changing? Each candidate
/// trigger is tried on the real window, editor and engine, and every number
/// is printed with the prefix `CHECK`. The tests keep documenting the
/// mechanism Writing mode uses (`SourceStyler.rebuildParagraphs(in:)`).
extension WritingFlowTests {
    /// Rebuild, nothing else moves, TextKit 1 and cost, for each trigger.
    @Test func openBlockCheckTriggersAndWhatTheyLeaveAlone() async throws {
        let check = try await OpenBlockCheck.open()
        defer { check.app.close() }
        let (editor, manager, styler) = (check.editor, check.manager, check.styler)
        let storage = try #require(editor.textStorage)
        let content = try #require(manager.textContentManager as? NSTextContentStorage)
        let span = check.span
        let block = NSRange(location: span.location, length: span.length - 1)

        // A semantic colour over one word of the block, to see that
        // rendering attributes survive a rebuild.
        let word = (editor.string as NSString).range(of: "rendering", options: [], range: span)
        styler.colors.set(.foregroundColor, value: NSColor.systemRed, range: word)
        styler.colors.commit()

        let snapshot = OpenBlockSnapshot(editor)
        let attributed = NSAttributedString(attributedString: storage)
        let masks = OpenBlockCounter()
        let processed = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil,
        ) { _ in
            masks.events += 1
        }
        let textChanges = OpenBlockCounter()
        let changed = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: editor, queue: nil,
        ) { _ in
            textChanges.events += 1
        }
        defer {
            NotificationCenter.default.removeObserver(processed)
            NotificationCenter.default.removeObserver(changed)
        }
        let built = SourceStyler.paragraphsBuilt

        typealias Trigger = (NSRange) -> Void
        let triggers: [(String, Trigger)] = [
            ("invalidateLayout", { range in
                if let textRange = TextKit2Geometry.textRange(range, in: manager) {
                    manager.invalidateLayout(for: textRange)
                }
            }),
            ("recordEditAction", { range in
                if let textRange = TextKit2Geometry.textRange(range, in: manager) {
                    content.performEditingTransaction {
                        content.recordEditAction(in: textRange, newTextRange: textRange)
                    }
                }
            }),
            ("synchronize", { range in
                if let textRange = TextKit2Geometry.textRange(range, in: manager) {
                    manager.invalidateLayout(for: textRange)
                    content.synchronizeTextLayoutManagers(nil)
                    manager.ensureLayout(for: textRange)
                }
            }),
            ("storageEditedAttributes", { range in
                content.performEditingTransaction {
                    storage.beginEditing()
                    storage.edited(.editedAttributes, range: range, changeInLength: 0)
                    storage.endEditing()
                }
            }),
            ("contentStorageProcessEditing", { range in styler.rebuildParagraphs(in: range) }),
        ]
        var working: [String] = []
        for (name, trigger) in triggers {
            for opening in [true, false] {
                styler.openBlock = opening ? check.style : nil
                styler.resetOpenParagraphRequests()
                let before = SourceStyler.paragraphsBuilt
                trigger(span)
                // One layout pass.
                manager.textViewportLayoutController.layoutViewport()
                let asked = SourceStyler.paragraphsBuilt - before
                let inBlock = styler.openParagraphRequests.count
                let font = check.lineFont(at: span.location + 2)
                let isDocument = font?.fontName == check.fonts.base.fontName
                print(
                    "CHECK trigger=\(name) opening=\(opening) paragraphsAsked=\(asked) inBlock=\(inBlock)",
                    "blockParagraphs=\(check.paragraphs) lineFont=\(font?.fontName ?? "nil") \(font?.pointSize ?? 0)",
                )
                if opening, isDocument, asked <= check.paragraphs + 2, inBlock == check.paragraphs {
                    working.append(name)
                }
                if !opening, isDocument {
                    // Close it with the trigger that works, so the next
                    // candidate starts from the editor's fonts.
                    styler.rebuildParagraphs(in: span)
                    manager.textViewportLayoutController.layoutViewport()
                }
            }
        }
        print("CHECK working=\(working)")
        #expect(working.contains("contentStorageProcessEditing"))
        #expect(!working.contains("invalidateLayout"))

        // Nothing else moves: the storage, the selection, undo, the
        // workspace, and no observer saw an edit from the processEditing
        // trigger (the storage edit trigger shows up in the masks).
        masks.events = 0
        textChanges.events = 0
        for _ in 0 ..< 10 {
            styler.openBlock = check.style
            styler.rebuildParagraphs(in: span)
            manager.textViewportLayoutController.layoutViewport()
            styler.openBlock = nil
            styler.rebuildParagraphs(in: span)
            manager.textViewportLayoutController.layoutViewport()
        }
        print("CHECK nothingMoves storageEdits=\(masks.events) textDidChange=\(textChanges.events)")
        #expect(masks.events == 0, "The storage processed \(masks.events) edits")
        #expect(textChanges.events == 0)
        #expect(OpenBlockSnapshot(editor) == snapshot, "Something moved")
        #expect(storage.isEqual(to: attributed), "The storage's attributes changed")
        var red = false
        if let location = TextKit2Geometry.location(word.location, in: manager) {
            manager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
                red = (attributes[.foregroundColor] as? NSColor) == NSColor.systemRed
                return false
            }
        }
        print("CHECK renderingAttributesKept=\(red)")
        #expect(red, "A rebuild dropped the block's rendering attributes")
        print("CHECK paragraphsBuiltOverall=\(SourceStyler.paragraphsBuilt - built)")

        // Cost: open (rebuild and layout) the ten-line paragraph, 50 times.
        // The pass mark is on the main thread's CPU time: under outside load the
        // wall clock measured 2.4 to 10.4 ms for the same work (1.41 ms at its
        // quietest), as the wall-clock search assertion of Phase 5 did.
        var times: [Double] = [], building: [Double] = [], cpu: [Double] = []
        var closing: [Double] = []
        for _ in 0 ..< 50 {
            let closeStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            styler.openBlock = nil
            styler.rebuildParagraphs(in: span)
            manager.textViewportLayoutController.layoutViewport()
            closing.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - closeStart) / 1e6)
            let start = ContinuousClock.now, built = SourceStyler.openParagraphTime
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            styler.openBlock = check.style
            styler.rebuildParagraphs(in: span)
            manager.textViewportLayoutController.layoutViewport()
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6)
            times.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
            building.append(Double((SourceStyler.openParagraphTime - built).components.attoseconds) / 1e15)
        }
        let median = times.sorted()[times.count / 2]
        let cpuMedian = cpu.sorted()[cpu.count / 2]
        print(String(
            format: "CHECK cost cpuMedianMs=%.3f wallMedianMs=%.3f wallMaxMs=%.3f paragraphsMadeMedianMs=%.3f lines=10",
            cpuMedian, median, times.max() ?? 0, building.sorted()[building.count / 2],
        ))
        // The 2 ms mark holds on a quiet machine (1.41 ms at load 24). Under
        // heavy outside load the same work takes 3 to 6 ms of CPU time, so
        // the suite's assertion compares it with closing the block, which
        // rebuilds and lays out the same ten paragraphs in the editor's font
        // in the same loop: the document's fonts may cost no more than twice
        // that. No absolute bound holds here: at load 30 the same work took
        // more than 8 ms of CPU time.
        let closeMedian = closing.sorted()[closing.count / 2]
        print(String(format: "CHECK cost closeCpuMedianMs=%.3f openToClose=%.2f", closeMedian, cpuMedian / closeMedian))
        #expect(cpuMedian < 2 * closeMedian, "Opening took \(cpuMedian) ms, closing \(closeMedian) ms")
        #expect(block.length > 0)
        expectPlainStorage(editor)
        #expect(!editor.switchedToTextKit1)
        styler.openBlock = nil
        styler.rebuildParagraphs(in: span)
    }

    /// Geometry and typing, with the block open through the processEditing
    /// trigger.
    @Test func openBlockCheckGeometryAndTyping() async throws {
        let check = try await OpenBlockCheck.open()
        defer { check.app.close() }
        let (editor, manager, styler) = (check.editor, check.manager, check.styler)
        let text = editor.string as NSString
        let span = check.span
        let raw = text.range(of: "def raw()").location
        let rawOffsets = Array(raw ..< raw + 19)
        let beforeRaw = rawOffsets.compactMap { TextKit2Geometry.caretRect(at: $0, in: manager) }
        let lineStarts = check.lineStarts
        let monoCaret = try #require(TextKit2Geometry.caretRect(at: lineStarts[0] + 12, in: manager))

        styler.openBlock = check.style
        styler.rebuildParagraphs(in: span)
        manager.textViewportLayoutController.layoutViewport()

        // Line fragments come from the new fonts.
        let fragment = try #require(TextKit2Geometry.location(span.location, in: manager)
            .flatMap { manager.textLayoutFragment(for: $0) })
        let lines = fragment.textLineFragments
        // Line 1 wraps; lines 2 and 3 are paragraphs of their own.
        let pitch = lines.count > 1 ? lines[1].typographicBounds.minY - lines[0].typographicBounds.minY : 0
        let second = try #require(TextKit2Geometry.location(lineStarts[1], in: manager)
            .flatMap { manager.textLayoutFragment(for: $0) })
        let third = try #require(TextKit2Geometry.location(lineStarts[2], in: manager)
            .flatMap { manager.textLayoutFragment(for: $0) })
        let between = third.layoutFragmentFrame.minY - second.layoutFragmentFrame.minY
        print(String(format: "CHECK geometry paragraphPitch=%.2f", between))
        #expect(abs(between - check.pitch) < 1, "Paragraphs are \(between) pt apart, not \(check.pitch)")
        let natural = check.fonts.base.ascender - check.fonts.base.descender + check.fonts.base.leading
        print(String(
            format: "CHECK geometry lines=%d pitch=%.2f expectedPitch=%.2f naturalLine=%.2f",
            lines.count, pitch, check.pitch, natural,
        ))
        #expect(abs(pitch - check.pitch) < 1, "Lines are \(pitch) pt apart, not \(check.pitch)")
        let caret = try #require(TextKit2Geometry.caretRect(at: lineStarts[0] + 12, in: manager))
        print(String(
            format: "CHECK caret x=%.2f height=%.2f monospaceX=%.2f monospaceHeight=%.2f",
            caret.minX, caret.height, monoCaret.minX, monoCaret.height,
        ))
        #expect(abs(caret.minX - monoCaret.minX) > 5, "Widths still follow the monospace font")
        #expect(abs(caret.height - monoCaret.height) > 1, "Heights still follow the monospace font")

        // Hit tests round trip on every character of the first source line.
        var failures = 0, tried = 0
        let first = NSRange(location: lineStarts[0], length: lineStarts[1] - lineStarts[0] - 1)
        for offset in first.location ..< NSMaxRange(first) - 1 {
            guard let left = TextKit2Geometry.caretRect(at: offset, in: manager),
                  let right = TextKit2Geometry.caretRect(at: offset + 1, in: manager),
                  abs(left.midY - right.midY) < 1, right.minX > left.minX
            else {
                continue
            }
            tried += 1
            let point = CGPoint(x: (left.minX + right.minX) / 2, y: left.midY)
            if TextKit2Geometry.character(at: point, in: manager, text: editor.string as NSString) != offset {
                failures += 1
            }
        }
        print("CHECK hitTests tried=\(tried) failures=\(failures)")
        #expect(tried > 40 && failures == 0)

        // The next source block moves by one constant.
        let afterRaw = rawOffsets.compactMap { TextKit2Geometry.caretRect(at: $0, in: manager) }
        #expect(afterRaw.count == beforeRaw.count)
        let shifts = zip(beforeRaw, afterRaw).map { $1.minY - $0.minY }
        let spread = (shifts.max() ?? 0) - (shifts.min() ?? 0)
        let sameX = zip(beforeRaw, afterRaw)
            .allSatisfy { abs($0.minX - $1.minX) < 0.5 && abs($0.height - $1.height) < 0.5 }
        print(String(
            format: "CHECK nextBlock shift=%.2f spread=%.3f sameX=%d",
            shifts.first ?? 0,
            spread,
            sameX ? 1 : 0,
        ))
        #expect(spread < 0.5 && sameX)

        // Typing: TextKit builds the edited paragraph through the delegate.
        let typed = lineStarts[2] + 4
        editor.setSelectedRange(NSRange(location: typed, length: 0))
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.textViewportLayoutController.layoutViewport()
        let typedFont = check.lineFont(at: typed)
        print("CHECK typing font=\(typedFont?.fontName ?? "nil") \(typedFont?.pointSize ?? 0)")
        #expect(typedFont?.fontName == check.fonts.base.fontName)
        let cjk = typed + 1
        editor.insertText("中文😀", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.textViewportLayoutController.layoutViewport()
        let now = editor.string as NSString
        var missing = 0
        for offset in [cjk, cjk + 1, cjk + 2] {
            let font = try #require(check.lineFont(at: offset))
            let range = now.rangeOfComposedCharacterSequence(at: offset)
            var units = Array(now.substring(with: range).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let covered = CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count)
            print("CHECK fallback offset=\(offset) font=\(font.fontName) covered=\(covered)")
            missing += covered ? 0 : 1
            #expect(font.fontName != check.fonts.base.fontName)
        }
        #expect(missing == 0, "\(missing) characters have no glyph in their font")
        #expect(styler.openBlock?.span.length == span.length + 5)
        #expect(!editor.switchedToTextKit1)
        styler.openBlock = nil
        styler.rebuildParagraphs(in: NSRange(location: span.location, length: span.length + 5))
    }
}

/// A count an observer block can change.
final class OpenBlockCounter: @unchecked Sendable {
    var events = 0
}

/// What a rebuild must leave as it was.
@MainActor
private struct OpenBlockSnapshot: Equatable {
    let selection: NSRange
    let canUndo: Bool
    let canRedo: Bool
    let undoName: String
    let revision: Int
    let saveStatus: String
    let blockCount: Int?

    init(_ editor: ManuscriptTextView) {
        selection = editor.selectedRange()
        canUndo = editor.undoManager?.canUndo ?? false
        canRedo = editor.undoManager?.canRedo ?? false
        undoName = editor.undoManager?.undoActionName ?? ""
        revision = editor.workspace?.revision ?? -1
        saveStatus = editor.workspace?.saveStatus ?? ""
        blockCount = editor.writing.model.map(\.blocks.count)
    }
}

/// The check's document in Writing mode, with the caret in a ten-line
/// paragraph, and a serif font set to open it with.
@MainActor
struct OpenBlockCheck {
    let app: WritingFixture
    let editor: ManuscriptTextView
    let manager: NSTextLayoutManager
    let styler: SourceStyler
    let span: NSRange
    let paragraphs: Int
    let lineStarts: [Int]
    let fonts: OpenBlockStyle.Fonts
    let style: OpenBlockStyle
    let pitch: CGFloat

    static let source: String = {
        let lines = (1 ... 10).map {
            "Line \($0) of the open paragraph, with rendering words, *strong* text and _emphasis_ in it."
                + ($0 == 1 ? " It goes on long enough that the line wraps in the column, once the open block" +
                    " sets it in the document's font and size, so two lines of one paragraph can be measured." : "")
        }
        return "= Check heading\n\nA short paragraph above.\n\n" + lines.joined(separator: "\n")
            + "\n\n```py\ndef raw(): return 1\n```\n\nA paragraph after the raw block.\n\n" + selectionFiller
    }()

    static func open() async throws -> OpenBlockCheck {
        let app = try WritingFixture(text: source, startService: false)
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let styler = try #require(editor.styler)
        let text = editor.string as NSString
        let start = text.range(of: "Line 1 of").location
        editor.setSelectedRange(NSRange(location: start + 3, length: 0))
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        await app.layout()
        await model.idle()
        let active = try #require(model.activeBlock)
        let span = model.span(ofBlockAt: active)
        #expect(span.location == start)
        // Writing mode opened the block in the document's font. The check
        // starts from the editor's fonts and opens it in its own (Times New
        // Roman), with no awaits until it ends, so nothing else changes it.
        styler.openBlock = nil
        styler.rebuildParagraphs(in: span)
        manager.textViewportLayoutController.layoutViewport()
        var lineStarts: [Int] = []
        var cursor = span.location
        while cursor < NSMaxRange(span) {
            lineStarts.append(cursor)
            cursor = NSMaxRange(text.paragraphRange(for: NSRange(location: cursor, length: 0)))
        }
        let base = try #require(NSFont(name: "Times New Roman", size: 21) ?? NSFont(name: "Times", size: 21))
        let manager2 = NSFontManager.shared
        let pitch: CGFloat = 30
        let fonts = OpenBlockStyle.Fonts(
            base: base,
            strong: manager2.convert(base, toHaveTrait: .boldFontMask),
            emphasis: manager2.convert(base, toHaveTrait: .italicFontMask),
            strongEmphasis: manager2.convert(
                manager2.convert(base, toHaveTrait: .boldFontMask),
                toHaveTrait: .italicFontMask,
            ),
            code: .monospacedSystemFont(ofSize: 19, weight: .regular),
            paragraphStyle: OpenBlockStyle.Fonts.paragraphStyle(pitch: pitch, font: base),
        )
        return OpenBlockCheck(
            app: app,
            editor: editor,
            manager: manager,
            styler: styler,
            span: span,
            paragraphs: lineStarts.count,
            lineStarts: lineStarts,
            fonts: fonts,
            style: OpenBlockStyle(span: span, fonts: fonts),
            pitch: pitch,
        )
    }

    /// The font TextKit laid out the character at `offset` in.
    func lineFont(at offset: Int) -> NSFont? {
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
}
