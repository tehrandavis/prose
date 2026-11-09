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
private func spellingInk(_ editor: ManuscriptTextView, save name: String? = nil) throws -> [CGPoint] {
    let visible = editor.visibleRect
    let rect = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: min(160, visible.height))
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
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
) throws {
    let first = try #require(editor.characterRect(at: word.location), sourceLocation: sourceLocation)
    let last = try #require(editor.characterRect(at: NSMaxRange(word) - 1), sourceLocation: sourceLocation)
    let ink = try spellingInk(editor, save: "spelling-\(context.replacingOccurrences(of: " ", with: "-")).png")
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
