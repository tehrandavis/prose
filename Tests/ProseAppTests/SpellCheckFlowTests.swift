import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// Phase 4 step F: spell check's model in the real editor, and the check
/// step G builds on: TextKit 2 draws the system's spelling underline for a
/// `.spellingState` rendering attribute (decision 9 of
/// `docs/plans/2026-11-09-phase-4-focus-toolbar-spellcheck.md`).
extension WritingFlowTests {
    /// TextKit 2 draws the spelling underline for `.spellingState` set as a
    /// rendering attribute through `RenderingAttributes`, below the word and
    /// nowhere else, with NSTextView's own spell checking off. It survives a
    /// full restyle and a syntax colour pass, goes when removed, and goes with
    /// the text when a file loads. A source block in Writing mode draws it
    /// too. The storage never changes.
    @Test func textKitDrawsTheSpellingStateSetAsARenderingAttribute() async throws {
        let source = "Hello teh world and some words.\n\nA second paragraph of plain words.\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        let editor = try #require(app.workspace.editor)
        let styler = try #require(editor.styler)
        // This test sets the attribute itself; the model would draw `teh` too.
        app.workspace.spelling.isEnabled = false
        await app.settle(editor)
        #expect(!editor.isContinuousSpellCheckingEnabled)
        let text = source as NSString
        let teh = text.range(of: "teh")
        let flag = NSAttributedString.SpellingState.spelling.rawValue
        #expect(try spellingInk(editor).isEmpty, "Red ink before any spelling state")

        styler.colors.set(.spellingState, value: flag, range: teh)
        styler.colors.commit()
        await app.layout()
        try expectUnderline(editor, under: teh, "Code mode")
        #expect(styler.colors
            .value(.spellingState, at: teh.location, effectiveRange: &placeholderRange) as? Int == flag)

        // A full restyle (a new text size) keeps it, at the word's new place.
        app.workspace.fontSize += 3
        editor.highlight()
        await app.settle(editor)
        try expectUnderline(editor, under: teh, "after a full restyle")
        app.workspace.fontSize -= 3
        editor.highlight()
        await app.settle(editor)
        // A syntax colour over the word keeps it.
        styler.colors.setColors([(teh, NSColor.systemBlue)])
        await app.layout()
        try expectUnderline(editor, under: teh, "under a syntax colour")
        styler.colors.setColors([])

        // Writing mode: the active block draws source through TextKit's own
        // drawing, underline included.
        editor.setSelectedRange(NSRange(location: teh.location + 1, length: 0))
        let model = try await enterWritingMode(app)
        #expect(role(model, text, teh.location) == .source)
        await app.layout()
        try expectUnderline(editor, under: teh, "Writing mode source block")
        app.workspace.setMode(.code)
        await app.layout()

        // Removed: gone.
        styler.colors.set(.spellingState, value: nil, range: teh)
        styler.colors.commit()
        await app.layout()
        #expect(try spellingInk(editor).isEmpty, "Red ink after removing the spelling state")

        // A new text drops it with the old text.
        styler.colors.set(.spellingState, value: flag, range: teh)
        styler.colors.commit()
        editor.load("Other words, then teh again.\n", selection: NSRange(location: 0, length: 0))
        await app.settle(editor)
        #expect(try spellingInk(editor).isEmpty, "Red ink after loading new text")
        #expect(styler.colors.value(.spellingState, at: 18, effectiveRange: &placeholderRange) == nil)

        // The storage holds the source and no spelling attribute.
        var stored = false
        let storage = try #require(editor.textStorage)
        storage.enumerateAttribute(.spellingState, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            stored = stored || value != nil
        }
        #expect(!stored)
        #expect(editor.string == "Other words, then teh again.\n")
    }

    /// The model follows the editor: the file's text, edits, the caret and
    /// the setting, with the real checker. Acceptance test 14 at the model
    /// level in the app: typing before a misspelling moves it, correcting it
    /// removes it, and a half-typed word under the caret is not shown until
    /// the caret leaves. Edit › Spelling and Grammar › Check Spelling While
    /// Typing turns it off and on, and the choice is kept.
    @Test func spellCheckFollowsTheEditorAndTheSetting() async throws {
        let previous = UserDefaults.standard.object(forKey: SpellCheckPreference.key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SpellCheckPreference.key)
            } else {
                UserDefaults.standard.removeObject(forKey: SpellCheckPreference.key)
            }
        }
        SpellCheckPreference.set(true)
        let source = "The teh letter came from a far wrold.\n\nCode `rawteh` and $tehh$ stay.\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let editor = try #require(app.workspace.editor)
        await app.settle(editor)
        let spelling = app.workspace.spelling
        #expect(spelling.isEnabled && spelling.file == app.workspace.documentURL)
        let tag = try #require(spelling.documentTag)
        func words(_ ranges: [NSRange]) -> [String] {
            ranges.map { (editor.string as NSString).substring(with: $0) }
        }
        try await app.wait { words(spelling.misspellings) == ["teh", "wrold"] }
        #expect(words(app.workspace.currentMisspellings) == ["teh", "wrold"])
        #expect(spelling.hasMarkedText() == false)

        // Typing before a misspelling moves it.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Dear: ", replacementRange: editor.selectedRange())
        let moved = (editor.string as NSString).range(of: "teh")
        #expect(spelling.misspellings.first == moved)
        // Correcting the word removes it, and the check after the pause
        // leaves it out.
        editor.insertText("the", replacementRange: moved)
        #expect(words(spelling.misspellings) == ["wrold"])
        await spelling.idle()
        #expect(words(spelling.misspellings) == ["wrold"])
        // A half-typed word under the caret: found, not shown.
        let end = (editor.string as NSString).range(of: "came").location - 1
        editor.setSelectedRange(NSRange(location: end, length: 0))
        for character in " recieve" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        await spelling.idle()
        #expect(words(spelling.misspellings) == ["recieve", "wrold"])
        #expect(words(app.workspace.currentMisspellings) == ["wrold"])
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(words(app.workspace.currentMisspellings) == ["recieve", "wrold"])
        // Marked text reaches the model.
        editor.setMarkedText(
            "x",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0),
        )
        #expect(spelling.hasMarkedText())
        editor.unmarkText()
        editor.undoManager?.undo()
        #expect(!spelling.hasMarkedText())
        // The same file loaded again keeps its spell document tag.
        editor.load(editor.string, selection: NSRange(location: 0, length: 0))
        await app.settle(editor)
        #expect(spelling.documentTag == tag)

        // The menu item shows and changes the setting.
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let submenu = try #require(edit.items.first { $0.title == "Spelling and Grammar" }?.submenu)
        let item = try #require(submenu.items.first { $0.title == "Check Spelling While Typing" })
        #expect(delegate.validateMenuItem(item) && item.state == .on)
        delegate.toggleSpellCheck()
        #expect(!app.workspace.checkSpellingWhileTyping && !spelling.isEnabled)
        #expect(spelling.misspellings.isEmpty)
        #expect(UserDefaults.standard.object(forKey: SpellCheckPreference.key) as? Bool == false)
        #expect(delegate.validateMenuItem(item) && item.state == .off)
        editor.insertText("teh ", replacementRange: NSRange(location: 0, length: 0))
        await spelling.idle()
        #expect(spelling.misspellings.isEmpty)
        delegate.toggleSpellCheck()
        #expect(SpellCheckPreference.isEnabled())
        try await app.wait { words(spelling.misspellings) == ["teh", "recieve", "wrold"] }
        // Spell check never touched the storage.
        #expect(editor.string == app.workspace.text)
        let storage = try #require(editor.textStorage)
        var stored = false
        storage.enumerateAttribute(.spellingState, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            stored = stored || value != nil
        }
        #expect(!stored)
    }
}

private nonisolated(unsafe) var placeholderRange = NSRange()

/// Points (view coordinates) of red ink in the top 160 pt of the visible
/// area: the spelling underline's colour, which no other part of these
/// documents uses. `save` keeps the picture as evidence.
@MainActor
private func spellingInk(
    _ editor: ManuscriptTextView,
    in area: NSRect? = nil,
    save name: String? = nil,
) throws -> [CGPoint] {
    let visible = editor.visibleRect
    let rect = area?.intersection(visible)
        ?? NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: min(160, visible.height))
    let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: rect))
    editor.cacheDisplay(in: rect, to: bitmap)
    if let name {
        try writingSave(bitmap, name)
    }
    let scale = CGFloat(bitmap.pixelsWide) / rect.width
    var points: [CGPoint] = []
    func add(_ x: Int, _ y: Int, red: CGFloat, green: CGFloat, blue: CGFloat) {
        if red - max(green, blue) > 0.2 {
            points.append(CGPoint(x: rect.minX + CGFloat(x) / scale, y: rect.minY + CGFloat(y) / scale))
        }
    }
    if bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3, !bitmap.isPlanar, let data = bitmap.bitmapData {
        let step = bitmap.bitsPerPixel / 8, row = bitmap.bytesPerRow
        // Alpha first or last; the colour channels are in order after it.
        let first = bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                let pixel = data + y * row + x * step + first
                add(x, y, red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255)
            }
        }
        return points
    }
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                add(x, y, red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent)
            }
        }
    }
    return points
}

/// Red ink lies below the glyphs of `word` and nowhere else.
@MainActor
private func expectUnderline(
    _ editor: ManuscriptTextView,
    under word: NSRange,
    _ context: String,
    in area: NSRect? = nil,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) throws {
    let first = try #require(editor.characterRect(at: word.location), sourceLocation: sourceLocation)
    let last = try #require(editor.characterRect(at: NSMaxRange(word) - 1), sourceLocation: sourceLocation)
    let ink = try spellingInk(
        editor,
        in: area,
        save: "spelling-\(context.replacingOccurrences(of: " ", with: "-")).png",
    )
    #expect(ink.count > 6, "\(context): \(ink.count) red points", sourceLocation: sourceLocation)
    let xs = ink.map(\.x), ys = ink.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
        return
    }
    #expect(
        minX >= first.minX - 1 && maxX <= last.maxX + 1,
        "\(context): ink x \(minX)…\(maxX), word \(first.minX)…\(last.maxX)",
        sourceLocation: sourceLocation,
    )
    #expect(
        minY >= first.midY && maxY <= first.maxY + 6,
        "\(context): ink y \(minY)…\(maxY), line \(first.minY)…\(first.maxY)",
        sourceLocation: sourceLocation,
    )
}

// MARK: - Step G: drawing, the context menu, Check Document Now, accessibility

/// A checker that reports a fixed list of words, so the tests do not depend
/// on the system's dictionary, and records ignore and learn.
@MainActor
private final class ScriptedSpelling: SpellChecker {
    var misspelled: Set<String> = ["teh", "wrold", "paragraf", "recie"]
    var ignored: [Int: Set<String>] = [:]
    var learned: Set<String> = []
    private var nextTag = 500

    func openDocument() -> Int {
        nextTag += 1
        return nextTag
    }

    func closeDocument(_ tag: Int) {
        ignored[tag] = nil
    }

    func misspellings(in text: String, ranges: [NSRange], document tag: Int) -> [NSRange] {
        let source = text as NSString
        var found: [NSRange] = []
        for range in ranges {
            var start: Int?
            for offset in range.location ... NSMaxRange(range) {
                let letter = offset < NSMaxRange(range)
                    && Unicode.Scalar(source.character(at: offset)).map(CharacterSet.letters.contains) == true
                if letter, start == nil {
                    start = offset
                } else if !letter, let first = start {
                    let word = NSRange(location: first, length: offset - first)
                    let string = source.substring(with: word)
                    if misspelled.contains(string), ignored[tag]?.contains(string) != true, !learned.contains(string) {
                        found.append(word)
                    }
                    start = nil
                }
            }
        }
        return found.sorted { $0.location < $1.location }
    }

    func ignore(_ word: String, document tag: Int) {
        ignored[tag, default: []].insert(word)
    }

    func learn(_ word: String) {
        learned.insert(word)
    }

    func guesses(for range: NSRange, in text: String, document _: Int) -> [String] {
        let word = (text as NSString).substring(with: range)
        return word == "teh" ? ["the", "ten"] : word == "wrold" ? [] : [word + "x"]
    }
}

private let quickSpelling = SpellCheckTiming(pause: .milliseconds(20), viewport: .milliseconds(1))

/// A document for Writing mode: misspellings in rendered paragraphs, a raw
/// block that always draws source (where `park` puts the caret), and filler.
private let renderedSpellingSource = """
= Spelling fixture

A first paragraph with teh word, then plain words that run on for a while.

Another paragraph of good words only, kept plain and simple.

A third paragraph where wrold sits.

```py
def raw(): return 1
```

The end.

"""

/// The storage with its attributes, to show that spell check changed nothing in it.
@MainActor
private func storageSnapshot(_ editor: ManuscriptTextView) -> NSAttributedString {
    NSAttributedString(attributedString: editor.textStorage ?? NSTextStorage())
}

/// A right mouse press at `point` (view coordinates), not posted.
@MainActor
private func rightClick(_ editor: ManuscriptTextView, at point: CGPoint) throws -> NSEvent {
    let window = try #require(editor.window)
    return try #require(NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: editor.convert(point, to: nil),
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1,
    ))
}

/// The area below a source line that holds `word`, across the view, in view coordinates.
@MainActor
private func lineArea(_ editor: ManuscriptTextView, _ word: NSRange) throws -> NSRect {
    let rect = try #require(editor.characterRect(at: word.location))
    return NSRect(x: editor.visibleRect.minX, y: rect.minY, width: editor.visibleRect.width, height: rect.height + 6)
}

/// The glyph boxes of `range` in the rendered block that starts at `block`,
/// in view coordinates.
@MainActor
private func renderedBoxes(_ editor: ManuscriptTextView, block: Int, range: NSRange) throws -> CGRect {
    let manager = try #require(editor.textLayoutManager)
    let shown = try #require(renderedBlock(manager, at: block), "Block \(block) is not rendered")
    let boxes = glyphBoxes(shown).filter { $0.offset.map { NSLocationInRange($0, range) } ?? false }.map(\.box)
    let first = try #require(boxes.first, "No glyphs for \(range)")
    let origin = editor.textContainerOrigin
    return boxes.dropFirst().reduce(first) { $0.union($1) }.offsetBy(dx: origin.x, dy: origin.y)
}

/// A picture of the visible rect, and its pixels as sRGB bytes.
@MainActor
private struct SpellingPicture {
    let rect: NSRect
    let width: Int
    let height: Int
    let scale: CGFloat
    let pixels: [UInt8]

    init(_ editor: ManuscriptTextView, save name: String? = nil) throws {
        rect = editor.visibleRect
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: rect))
        editor.cacheDisplay(in: rect, to: bitmap)
        if let name {
            try writingSave(bitmap, name)
        }
        let wide = bitmap.pixelsWide, high = bitmap.pixelsHigh
        width = wide
        height = high
        scale = CGFloat(wide) / rect.width
        var pixels = [UInt8](repeating: 0, count: wide * high * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(bitmap.cgImage)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: high))
        }
        self.pixels = pixels
    }

    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let index = (y * width + x) * 4
        return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
    }

    /// The view point of pixel (x, y).
    func point(_ x: Int, _ y: Int) -> CGPoint {
        CGPoint(x: rect.minX + (CGFloat(x) + 0.5) / scale, y: rect.minY + (CGFloat(y) + 0.5) / scale)
    }

    /// Points whose red stands above green and blue: the underline.
    func red(in area: NSRect? = nil) -> [CGPoint] {
        var found: [CGPoint] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (red, green, blue) = pixel(x, y)
                if red - max(green, blue) > 50 {
                    let point = point(x, y)
                    if area.map({ $0.contains(point) }) ?? true {
                        found.append(point)
                    }
                }
            }
        }
        return found
    }

    /// The 98th percentile of red minus green in `area`: the underline's
    /// strength at its dots' cores.
    func redStrength(in area: NSRect) -> Int {
        var values: [Int] = []
        for y in 0 ..< height {
            for x in 0 ..< width where area.contains(point(x, y)) {
                let (red, green, _) = pixel(x, y)
                values.append(red - green)
            }
        }
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
    }

    /// Points where this picture and `other` differ.
    func differences(from other: SpellingPicture) -> [CGPoint] {
        var found: [CGPoint] = []
        guard width == other.width, height == other.height else {
            return [CGPoint(x: -1, y: -1)]
        }
        for y in 0 ..< height {
            for x in 0 ..< width where pixel(x, y) != other.pixel(x, y) {
                found.append(point(x, y))
            }
        }
        return found
    }
}

extension WritingFlowTests {
    /// Acceptance tests 10 and 14 at the drawing level: a misspelled word in
    /// source gets the system's underline, which moves with typing before it,
    /// goes when the word is corrected, and waits while the caret is in a
    /// half-typed word. The characters and the storage's attributes never
    /// change for it.
    @Test func spellingUnderlinesSourceAndFollowsTheText() async throws {
        let source = "Hello teh world and some words.\n\nA second paragraf of plain words.\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        let editor = try #require(app.workspace.editor)
        await app.settle(editor)
        let before = storageSnapshot(editor)
        let checker = ScriptedSpelling()
        app.workspace.useSpellChecker(checker, timing: quickSpelling)
        let spelling = app.workspace.spelling
        func words(_ ranges: [NSRange]) -> [String] {
            ranges.map { (editor.string as NSString).substring(with: $0) }
        }
        try await app.wait { words(spelling.misspellings) == ["teh", "paragraf"] }
        await spelling.idle()
        await app.layout()
        var text = editor.string as NSString
        try expectUnderline(
            editor,
            under: text.range(of: "teh"),
            "source teh",
            in: lineArea(editor, text.range(of: "teh")),
        )
        try expectUnderline(
            editor,
            under: text.range(of: "paragraf"),
            "source paragraf",
            in: lineArea(editor, text.range(of: "paragraf")),
        )
        // Acceptance test 10: no character and no storage attribute changed.
        #expect(storageSnapshot(editor).isEqual(to: before))
        expectPlainStorage(editor)

        // Typing before the misspelling moves its underline with it at once.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Dear: ", replacementRange: editor.selectedRange())
        await app.layout()
        text = editor.string as NSString
        let moved = text.range(of: "teh")
        #expect(spelling.misspellings.first == moved)
        try expectUnderline(editor, under: moved, "moved teh", in: lineArea(editor, moved))

        // Correcting the word removes its underline, and the check after the
        // pause does not bring it back.
        editor.insertText("the", replacementRange: moved)
        await spelling.idle()
        await app.layout()
        #expect(try spellingInk(editor, in: lineArea(editor, moved)).isEmpty, "Ink under the corrected word")
        #expect(words(spelling.misspellings) == ["paragraf"])

        // A half-typed word under the caret is found but not underlined until
        // the caret leaves it.
        text = editor.string as NSString
        let end = text.range(of: "world").location + 5
        editor.setSelectedRange(NSRange(location: end, length: 0))
        for character in " recie" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        await spelling.idle()
        await app.layout()
        text = editor.string as NSString
        let half = text.range(of: "recie")
        #expect(words(spelling.misspellings) == ["recie", "paragraf"])
        #expect(try spellingInk(editor, in: lineArea(editor, half)).isEmpty, "Ink under the word being typed")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        await app.layout()
        try expectUnderline(editor, under: half, "left recie", in: lineArea(editor, half))
        // Only typing changed the storage; spell check wrote no attribute.
        var stored = false
        let storage = try #require(editor.textStorage)
        storage.enumerateAttribute(.spellingState, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            stored = stored || value != nil
        }
        #expect(!stored)
        expectPlainStorage(editor)
    }

    /// Acceptance test 11: a misspelled word in a rendered block is
    /// underlined below its glyph boxes and nowhere else, in the system's
    /// colour and pattern; the image's pixels do not change elsewhere; in
    /// Focus a dimmed block's underline is at 45 percent.
    @Test func spellingUnderlinesRenderedBlocks() async throws {
        let app = try WritingFixture(text: renderedSpellingSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        park(editor)
        let checker = ScriptedSpelling()
        app.workspace.useSpellChecker(checker, timing: quickSpelling)
        let spelling = app.workspace.spelling
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()
        await model.idle()
        await app.layout()
        let text = editor.string as NSString
        let teh = text.range(of: "teh"), wrold = text.range(of: "wrold")
        let first = text.paragraphRange(for: teh), third = text.paragraphRange(for: wrold)
        #expect(role(model, text, teh.location).isRendered && role(model, text, wrold.location).isRendered)
        let before = storageSnapshot(editor)

        let picture = try SpellingPicture(editor, save: "spelling-rendered.png")
        let red = picture.red()
        let words = try [teh, wrold].map { try renderedBoxes(
            editor,
            block: text.paragraphRange(for: $0).location,
            range: $0,
        ) }
        #expect(red.count > 20, "Red points: \(red.count)")
        for (word, boxes) in zip(["teh", "wrold"], words) {
            let under = red.filter { boxes.insetBy(dx: -1, dy: -1).contains($0) }
            #expect(under.count > 10, "\(word): \(under.count) red points")
            let ys = under.map(\.y), xs = under.map(\.x)
            if let minY = ys.min(), let maxY = ys.max(), let minX = xs.min(), let maxX = xs.max() {
                // Below the middle of the glyphs, down to their boxes' bottom.
                #expect(minY >= boxes.midY && maxY <= boxes.maxY + 1, "\(word): ink y \(minY)…\(maxY), boxes \(boxes)")
                #expect(
                    minX >= boxes.minX - 0.5 && maxX <= boxes.maxX + 0.5,
                    "\(word): ink x \(minX)…\(maxX), boxes \(boxes)",
                )
            }
        }
        // Nowhere else: not under correctly spelled words.
        let stray = red.filter { point in !words.contains { $0.insetBy(dx: -1, dy: -1).contains(point) } }
        #expect(stray.isEmpty, "Red ink away from the misspelled words: \(stray.prefix(5))")
        // The system's colour: systemRed at 75 percent over the page,
        // (255, 108, 100), at the dots' cores.
        let core = picture.redStrength(in: words[0])
        #expect(abs(core - 147) <= 8, "Underline strength \(core)")
        let fragment = try #require(writingFragments(manager).first { $0.offset == first.location }?.fragment)
        #expect((fragment.draws["underlined"] ?? 0) > 0)

        // Without spell check the blocks draw again with no underline, and
        // every pixel away from the underlines is the same.
        spelling.isEnabled = false
        #expect(editor.writing.spellingRelaidOut.contains(first) && editor.writing.spellingRelaidOut.contains(third))
        await app.layout()
        let plain = try SpellingPicture(editor, save: "spelling-rendered-off.png")
        #expect(plain.red().isEmpty)
        let changed = picture.differences(from: plain)
        #expect(!changed.isEmpty)
        let outside = changed.filter { point in !words.contains { $0.insetBy(dx: -1, dy: -1).contains(point) } }
        #expect(outside.isEmpty, "Pixels changed away from the underlines: \(outside.prefix(5))")
        spelling.isEnabled = true
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()
        await app.layout()

        // Focus: the caret stays in the raw block, so both paragraphs are
        // dimmed, and their underlines with them.
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.enteredWithRenders != nil }
        await model.idle()
        await app.layout()
        await model.idle()
        await app.layout()
        #expect(role(model, text, teh.location).isRendered)
        #expect(editor.writing.dims(paragraphAt: first.location))
        let focus = try SpellingPicture(editor, save: "spelling-focus.png")
        let dimmedBoxes = try renderedBoxes(editor, block: first.location, range: teh)
        let dimmed = focus.redStrength(in: dimmedBoxes)
        let ratio = Double(dimmed) / Double(core)
        #expect(abs(ratio - WritingFocus.dimmedAlpha) <= 0.03, "Dimmed underline \(dimmed) of \(core): \(ratio)")
        #expect(focus.red(in: dimmedBoxes.insetBy(dx: -1, dy: -1)).count > 10)
        app.workspace.setMode(.writing)
        await app.layout()

        #expect(storageSnapshot(editor).isEqual(to: before))
        expectPlainStorage(editor)
    }
}

extension WritingFlowTests {
    /// Acceptance test 12: a right-click on a misspelled word, in source and
    /// in a rendered block, puts the suggestions first; one replaces the word
    /// as one undoable edit. Ignore Spelling removes the underline for the
    /// file's session; Learn Spelling goes to the checker.
    @Test func spellingContextMenuSuggestsIgnoresAndLearns() async throws {
        let app = try WritingFixture(text: renderedSpellingSource, startService: false)
        defer { app.close() }
        app.window.appearance = NSAppearance(named: .aqua)
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        let checker = ScriptedSpelling()
        app.workspace.useSpellChecker(checker, timing: quickSpelling)
        let spelling = app.workspace.spelling
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()
        await app.layout()
        var text = editor.string as NSString
        let teh = text.range(of: "teh")
        let undo = try #require(editor.undoManager)
        #expect(!undo.canUndo)

        // Source (Code mode): the suggestions, Learn and Ignore, then the editor's menu.
        let centre = try #require(editor.characterRect(at: teh.location + 1))
        let menu = try #require(editor.menu(for: rightClick(editor, at: CGPoint(x: centre.midX, y: centre.midY))))
        let titles = menu.items.map(\.title)
        #expect(editor.selectedRange() == teh, "NSTextView selects the right-clicked word in source")
        #expect(Array(titles.prefix(6)) == ["the", "ten", "", "Learn Spelling", "Ignore Spelling", ""], "\(titles)")
        #expect(menu.items[2].isSeparatorItem && menu.items[5].isSeparatorItem)
        #expect(titles.contains(WritingCommand.all.first { $0.id == "quickHelp" }?.title ?? "?"))
        #expect(editor.validateMenuItem(menu.items[0]) && editor.validateMenuItem(menu.items[3]))
        menu.performActionForItem(at: 0)
        #expect(editor.string == renderedSpellingSource.replacingOccurrences(of: "teh", with: "the"))
        #expect(undo.canUndo)
        undo.undo()
        #expect(editor.string == renderedSpellingSource)
        #expect(!undo.canUndo, "The replacement was more than one undo step")
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()

        // No spelling items over a correctly spelled word.
        let good = try #require(editor.characterRect(at: text.range(of: "plain").location + 1))
        let plainMenu = try #require(editor.menu(for: rightClick(editor, at: CGPoint(x: good.midX, y: good.midY))))
        #expect(!plainMenu.items.contains { $0.title == "Ignore Spelling" })

        // Rendered block (Writing mode): the press maps through the glyph boxes.
        park(editor)
        let model = try await enterWritingMode(app)
        writingScrollToTop(editor)
        await spelling.idle()
        await app.layout()
        text = editor.string as NSString
        let paragraph = text.paragraphRange(for: teh)
        #expect(role(model, text, teh.location).isRendered)
        let glyph = try glyphCentre(manager, block: paragraph.location, offset: teh.location + 1)
        let origin = editor.textContainerOrigin
        let rendered = try #require(editor.menu(for: rightClick(
            editor,
            at: CGPoint(x: glyph.x + origin.x, y: glyph.y + origin.y),
        )))
        #expect(Array(rendered.items.prefix(5).map(\.title)) == ["the", "ten", "", "Learn Spelling", "Ignore Spelling"])
        // The right-click selected the word as the pointer does: the block
        // stays drawn under the menu, and NSTextView did not select the
        // hidden source line's word.
        #expect(editor.selectedRange() == teh)
        #expect(role(model, text, teh.location).isRendered)
        rendered.performActionForItem(at: 1)
        #expect(editor.string == renderedSpellingSource.replacingOccurrences(of: "teh", with: "ten"))
        await model.idle()
        await app.layout()
        // As after any edit: the caret is after the new word, in its block, which draws source.
        #expect(editor.selectedRange() == NSRange(location: teh.location + 3, length: 0))
        #expect(role(model, editor.string as NSString, teh.location) == .source)
        undo.undo()
        #expect(editor.string == renderedSpellingSource)
        #expect(!undo.canUndo)
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()

        // Ignore Spelling in a rendered block: the underline goes, for the file's session.
        park(editor)
        await model.idle()
        await app.layout()
        let wrold = text.range(of: "wrold")
        #expect(role(model, text, wrold.location).isRendered)
        let third = text.paragraphRange(for: wrold)
        let point = try glyphCentre(manager, block: third.location, offset: wrold.location + 2)
        let ignoreMenu = try #require(editor.menu(for: rightClick(
            editor,
            at: CGPoint(x: point.x + origin.x, y: point.y + origin.y),
        )))
        // A word without suggestions says so.
        #expect(ignoreMenu.items.first?.title == "No Guesses Found" && ignoreMenu.items.first?.isEnabled == false)
        let ignore = try #require(ignoreMenu.items.firstIndex { $0.title == "Ignore Spelling" })
        let boxes = try renderedBoxes(editor, block: third.location, range: wrold)
        #expect(try SpellingPicture(editor).red(in: boxes.insetBy(dx: -1, dy: -1)).count > 10)
        ignoreMenu.performActionForItem(at: ignore)
        #expect(!spelling.misspellings.contains(wrold))
        #expect(checker.ignored[spelling.documentTag ?? -1]?.contains("wrold") == true)
        #expect(editor.writing.spellingRelaidOut.contains(third))
        await app.layout()
        #expect(try SpellingPicture(editor).red(in: boxes.insetBy(dx: -1, dy: -1)).isEmpty)
        // A check of its paragraph again leaves it out: the tag keeps it ignored.
        editor.insertText(" ", replacementRange: NSRange(location: NSMaxRange(wrold) + 1, length: 0))
        undo.undo()
        await spelling.idle()
        #expect(!spelling.misspellings.contains(wrold))

        // Learn Spelling goes through the checker.
        app.workspace.setMode(.code)
        await app.layout()
        let tehCentre = try #require(editor.characterRect(at: teh.location))
        let learnMenu = try #require(editor.menu(for: rightClick(
            editor,
            at: CGPoint(x: tehCentre.midX, y: tehCentre.midY),
        )))
        let learn = try #require(learnMenu.items.firstIndex { $0.title == "Learn Spelling" })
        learnMenu.performActionForItem(at: learn)
        #expect(checker.learned == ["teh"])
        #expect(spelling.misspellings.isEmpty)
        await app.layout()
        #expect(try spellingInk(editor, in: lineArea(editor, teh)).isEmpty)

        expectPlainStorage(editor)
    }
}

extension WritingFlowTests {
    /// Acceptance test 13: the accessibility attributed string of a range
    /// with a misspelling marks it misspelled, through the public method and
    /// through the parameterized attribute assistive apps use; its string is
    /// the source; a range without misspellings has no such key. The caret's
    /// word is misspelled but not marked as drawn.
    @Test func spellingMarksMisspellingsForAccessibility() async throws {
        let app = try WritingFixture(text: renderedSpellingSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        app.workspace.useSpellChecker(ScriptedSpelling(), timing: quickSpelling)
        let spelling = app.workspace.spelling
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()
        let text = editor.string as NSString
        let teh = text.range(of: "teh"), wrold = text.range(of: "wrold")
        let first = text.paragraphRange(for: teh)
        let plain = text.paragraphRange(for: text.range(of: "Another paragraph"))

        func keys(_ string: NSAttributedString?, _ key: NSAttributedString.Key) -> [NSRange] {
            var found: [NSRange] = []
            guard let string else {
                return found
            }
            string.enumerateAttribute(key, in: NSRange(location: 0, length: string.length)) { value, range, _ in
                if (value as? Bool) == true {
                    found.append(range)
                }
            }
            return found
        }
        func check(_ label: String) {
            for read in ["method", "attribute"] {
                func string(_ range: NSRange) -> NSAttributedString? {
                    read == "method" ? editor.accessibilityAttributedString(for: range)
                        : editor.perform(
                            NSSelectorFromString("accessibilityAttributeValue:forParameter:"),
                            with: NSAccessibility.ParameterizedAttribute.attributedStringForRange.rawValue,
                            with: NSValue(range: range),
                        )?.takeUnretainedValue() as? NSAttributedString
                }
                let marked = string(first)
                #expect(marked?.string == text.substring(with: first), "\(label) \(read): string")
                let local = NSRange(location: teh.location - first.location, length: teh.length)
                #expect(keys(marked, .accessibilityMisspelled) == [local], "\(label) \(read): misspelled")
                #expect(keys(marked, .accessibilityMarkedMisspelled) == [local], "\(label) \(read): marked")
                let clean = string(plain)
                #expect(clean?.string == text.substring(with: plain))
                #expect(keys(clean, .accessibilityMisspelled).isEmpty)
                #expect(keys(clean, .accessibilityMarkedMisspelled).isEmpty)
                // A range that starts inside the word marks only its part.
                let partial = NSRange(location: teh.location + 1, length: 6)
                #expect(keys(string(partial), .accessibilityMisspelled) == [NSRange(location: 0, length: 2)])
            }
        }
        check("Code mode")
        park(editor)
        _ = try await enterWritingMode(app)
        check("Writing mode")
        // The caret's word: misspelled, not drawn as such.
        editor.setSelectedRange(NSRange(location: wrold.location + 2, length: 0))
        let third = text.paragraphRange(for: wrold)
        let caretWord = editor.accessibilityAttributedString(for: third)
        let local = NSRange(location: wrold.location - third.location, length: wrold.length)
        #expect(keys(caretWord, .accessibilityMisspelled) == [local])
        #expect(keys(caretWord, .accessibilityMarkedMisspelled).isEmpty)
        expectPlainStorage(editor)
    }

    /// Edit › Spelling and Grammar › Check Document Now (`⌘;`) selects the
    /// next misspelling after the selection, wraps once at the end, and
    /// finds nothing when there is none. In Writing mode the word's block
    /// opens as for a keyboard selection; in Focus its line goes to the
    /// typewriter line.
    @Test func checkDocumentNowMovesToTheNextMisspellingAndWraps() async throws {
        let app = try WritingFixture(text: renderedSpellingSource, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let checker = ScriptedSpelling()
        app.workspace.useSpellChecker(checker, timing: quickSpelling)
        let spelling = app.workspace.spelling
        try await app.wait { spelling.misspellings.count == 2 }
        await spelling.idle()
        let text = editor.string as NSString
        let teh = text.range(of: "teh"), wrold = text.range(of: "wrold")

        // The menu item.
        let delegate = AppDelegate(workspace: app.workspace)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        delegate.installMenu()
        let edit = try #require(NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu)
        let submenu = try #require(edit.items.first { $0.title == "Spelling and Grammar" }?.submenu)
        let item = try #require(submenu.items.first { $0.title == "Check Document Now" })
        #expect(item.keyEquivalent == ";" && item.keyEquivalentModifierMask == .command)
        #expect(item.action == #selector(AppDelegate.checkDocumentNow))

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(await app.workspace.checkDocumentNow() == teh)
        #expect(editor.selectedRange() == teh)
        #expect(await app.workspace.checkDocumentNow() == wrold)
        #expect(editor.selectedRange() == wrold)
        // Wraps once at the end of the file.
        #expect(await app.workspace.checkDocumentNow() == teh)
        // Through the menu item: an asynchronous search, then the selection.
        delegate.perform(item.action, with: item)
        try await app.wait { editor.selectedRange() == wrold }

        // Writing mode: the selected word's block draws source, as for any
        // keyboard selection.
        park(editor)
        let model = try await enterWritingMode(app)
        #expect(role(model, text, teh.location).isRendered)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(await app.workspace.checkDocumentNow() == teh)
        await model.idle()
        await app.layout()
        #expect(role(model, text, teh.location) == .source)

        // Focus: the selected word's line is on the typewriter line.
        app.workspace.setMode(.focus)
        try await app.wait { editor.writing.focused && editor.writing.enteredWithRenders != nil }
        await model.idle()
        await app.layout()
        #expect(await app.workspace.checkDocumentNow() == wrold)
        await model.idle()
        await app.layout()
        let middle = try #require(editor.writing.caretMiddleInView(wrold.location))
        let line = WritingController.typewriterFraction * editor.containerVisibleRect().height
        #expect(abs(middle - line) <= 1, "Selected word's line at \(middle), typewriter line \(line)")
        app.workspace.setMode(.writing)
        await app.layout()

        // None left: nothing is selected (and the app beeps).
        spelling.learn("teh")
        spelling.learn("wrold")
        await spelling.idle()
        #expect(spelling.misspellings.isEmpty)
        let selection = editor.selectedRange()
        #expect(await app.workspace.checkDocumentNow() == nil)
        #expect(editor.selectedRange() == selection)
        expectPlainStorage(editor)
    }
}
