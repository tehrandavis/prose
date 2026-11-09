import AppKit
import ProseCore

/// "Check Spelling While Typing", for all documents (decision 8 of the
/// Phase 4 note). Default on. It is kept in this Mac's user defaults, not in
/// the synced preferences: like NSTextView's own setting, it belongs to the
/// Mac rather than to the writing.
enum SpellCheckPreference {
    static let key = "checkSpellingWhileTyping"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Spell check of the open file. The workspace owns the model; the editor
/// forwards it the text, the edits, the selection, marked text and the
/// visible range, and draws what it reports (step G): the rendering
/// attribute `.spellingState` in source, the fragment's own underline in
/// rendered blocks.
extension Workspace {
    func makeSpellCheckModel(
        checker: any SpellChecker = SystemSpellChecker(),
        timing: SpellCheckTiming = .standard,
    ) -> SpellCheckModel {
        let model = SpellCheckModel(checker: checker, timing: timing)
        model.isEnabled = checkSpellingWhileTyping
        model.hasMarkedText = { [weak self] in self?.editor?.hasMarkedText() ?? false }
        model.onChange = { [weak self] ranges in self?.editor?.spellingChanged(ranges) }
        return model
    }

    /// Replaces the model with one that asks `checker`, for the open file.
    /// Tests use a scripted checker where the result must not depend on the
    /// system's dictionary.
    func useSpellChecker(_ checker: any SpellChecker, timing: SpellCheckTiming = .standard) {
        spelling.close()
        spelling = makeSpellCheckModel(checker: checker, timing: timing)
        editor?.spellingChanged([NSRange(location: 0, length: (editor?.string as NSString?)?.length ?? 0)])
        if let editor {
            editor.spellingDidLoad(editor.string)
            editor.spellingViewportDidChange()
        }
    }

    /// Edit › Spelling and Grammar › Check Document Now (`⌘;`): selects the
    /// next misspelling after the selection's end, wrapping once at the end
    /// of the file, and shows it; beeps when there is none (spell check off
    /// included). In Writing and Focus mode the selection opens the word's
    /// block as any keyboard selection does. Returns what it selected.
    @discardableResult
    func checkDocumentNow() async -> NSRange? {
        guard let editor, !isLibraryHome, !editor.hasMarkedText() else {
            NSSound.beep()
            return nil
        }
        let start = NSMaxRange(editor.selectedRange())
        let found = await spelling.nextMisspelling(after: start)
        guard let found, self.editor === editor, !editor.hasMarkedText(),
              NSMaxRange(found) <= (editor.string as NSString).length
        else {
            recordOperation("spelling.next", ["after": String(start), "found": "none"])
            NSSound.beep()
            return nil
        }
        editor.selectMisspelling(found)
        recordOperation("spelling.next", ["after": String(start), "found": NSStringFromRange(found)])
        return found
    }

    /// The setting changed: the model follows it, and the choice is kept.
    func spellCheckSettingChanged() {
        SpellCheckPreference.set(checkSpellingWhileTyping)
        spelling.isEnabled = checkSpellingWhileTyping
        recordOperation("spelling.setting", ["enabled": String(checkSpellingWhileTyping)])
        editor?.spellingViewportDidChange()
    }

    func toggleSpellCheck() {
        checkSpellingWhileTyping.toggle()
    }

    func spellCheckDocumentNow() {
        Task { await checkDocumentNow() }
    }

    /// The misspellings to draw in the open file: all but the caret's word.
    var currentMisspellings: [NSRange] {
        spelling.shownMisspellings
    }
}

extension ManuscriptTextView {
    /// The editor holds new text: spell check reads it afresh, keeping the
    /// file's spell document tag when the file is the same.
    func spellingDidLoad(_ content: String) {
        guard let workspace else {
            return
        }
        if workspace.isLibraryHome {
            workspace.spelling.close()
            return
        }
        workspace.spelling.open(file: workspace.documentURL, text: content)
        workspace.spelling.selectionDidChange(selectedRange())
    }

    /// The characters in view, for the paragraphs spell check reads first.
    /// Writing mode has measured them already when it runs.
    func spellingViewportDidChange() {
        guard !loading, let spelling = workspace?.spelling, spelling.isEnabled, spelling.file != nil else {
            return
        }
        let range = writing.isRunning ? writing.visibleRange ?? visibleCharacterRange() : visibleCharacterRange()
        if let range {
            spelling.setVisibleRange(range)
        }
    }
}

// MARK: - Drawing

extension ManuscriptTextView {
    /// The flag TextKit 2 draws the system's spelling underline for.
    static let spellingFlag = NSAttributedString.SpellingState.spelling.rawValue

    /// Spell check's shown misspellings changed in `ranges` (today's text).
    /// During an edit TextKit has not seen the new text yet, so the change is
    /// drawn once the storage has finished processing it.
    func spellingChanged(_ ranges: [NSRange]) {
        spellingPending += ranges
        if textStorage?.editedMask.isEmpty == false {
            scheduleSpelling()
        } else {
            applySpelling()
        }
    }

    /// An edit moved the text under ranges still waiting to be drawn.
    func spellingTextDidChange(edited: NSRange, delta: Int) {
        guard !spellingPending.isEmpty else {
            return
        }
        let original = NSRange(location: edited.location, length: edited.length - delta)
        spellingPending = spellingPending.map { SourceStyling.rebase($0, editing: original, delta: delta) }
        scheduleSpelling()
    }

    private func scheduleSpelling() {
        guard !spellingApplyScheduled else {
            return
        }
        spellingApplyScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.applySpelling()
            }
        }
    }

    /// Draws the waiting changes: in source, `.spellingState` on exactly the
    /// shown misspellings of each range, through `RenderingAttributes`, so a
    /// full restyle keeps it and only spans that differ are written; in
    /// rendered blocks, a new layout of the blocks so their fragments draw
    /// the new underlines. Nothing reaches the text storage.
    func applySpelling() {
        spellingApplyScheduled = false
        guard !spellingPending.isEmpty, textStorage?.editedMask.isEmpty != false else {
            return
        }
        let length = (string as NSString).length
        let whole = NSRange(location: 0, length: length)
        var ranges: [NSRange] = []
        for range in spellingPending.map({ NSIntersectionRange($0, whole) }).filter({ $0.length > 0 })
            .sorted(by: { $0.location < $1.location })
        {
            if let last = ranges.last, range.location <= NSMaxRange(last) {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        spellingPending = []
        guard let spelling = workspace?.spelling else {
            return
        }
        if let colors = styler?.colors, colors.length == length {
            for range in ranges {
                colors.setSpelling(spelling.shownMisspellings(in: range), in: range, value: Self.spellingFlag)
            }
            colors.commit()
        }
        if !loading {
            writing.spellingChanged(ranges)
        }
    }

    /// `⌘;` found `range`: it becomes the selection, which in Writing mode
    /// opens its block as a keyboard selection does, and comes into view. In
    /// Focus mode its line goes to the typewriter line, as the caret's does:
    /// decision 5 scrolls only for an empty selection, so this is the one
    /// selection with length that Focus places there.
    func selectMisspelling(_ range: NSRange) {
        setSelectedRange(range)
        if writing.focused, writing.isRunning {
            writing.placeCaretLine(
                range.location,
                at: WritingController.typewriterFraction * containerVisibleRect().height,
            )
        } else {
            reveal(range)
        }
    }
}

extension WritingController {
    /// The shown misspellings that a rendered block draws, read at each draw.
    func misspellings(in block: NSRange) -> [NSRange] {
        guard let spelling = editor?.workspace?.spelling, spelling.isEnabled else {
            return []
        }
        return spelling.shownMisspellings(in: block)
    }

    /// The system's spelling underline colour, as TextKit 2 draws it in
    /// source (sampled on macOS 27): systemRed at 75 percent in light
    /// appearance, a lighter red at 85 percent in dark appearance.
    func spellingColor() -> CGColor {
        let dark = editor?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let components: [CGFloat] = dark ? [1, 0.551, 0.551, 0.847] : [1, 0.231, 0.188, 0.749]
        return space.flatMap { CGColor(colorSpace: $0, components: components) }
            ?? CGColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }
}

// MARK: - Context menu

/// What a spelling item of the context menu acts on.
final class SpellingMenuChoice: NSObject {
    let range: NSRange
    let word: String
    let replacement: String?

    init(range: NSRange, word: String, replacement: String? = nil) {
        self.range = range
        self.word = word
        self.replacement = replacement
    }
}

extension ManuscriptTextView {
    /// For a right-click on the misspelled word at `word`, in source or in a
    /// rendered block (`misspelledWord(at:)`), puts the suggestions at the
    /// top of the editor's context menu, then Learn Spelling and Ignore
    /// Spelling, before the menu that was there.
    func insertSpellingItems(into menu: NSMenu, for word: NSRange) {
        for (index, item) in spellingItems(for: word).enumerated() {
            menu.insertItem(item, at: index)
        }
    }

    /// NSTextView's context menu. NSTextView selects the word under the
    /// pointer as it finds it in its own layout, which inside a rendered
    /// block or a pill is the hidden source lines: another word, and a
    /// keyboard-style selection that would open the block under the open
    /// menu. So in a rendered block or a pill Prose chooses the selection: a
    /// right-click on a misspelled word selects it as a pointer selection
    /// (decision 6: the block stays drawn), any other right-click keeps the
    /// selection, and NSTextView may not change it while it builds the menu.
    /// Over source NSTextView selects as it always has.
    func contextMenuSelecting(_ misspelling: NSRange?, for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard writing.drawnCharacter(at: local).drawn else {
            return super.menu(for: event)
        }
        if let misspelling, selectedRange() != misspelling {
            selectingWithMouse = true
            setSelectedRange(misspelling)
            selectingWithMouse = false
            selectionChanged(byPointer: true, anchor: misspelling.location)
        }
        holdsSelection = true
        defer { holdsSelection = false }
        return super.menu(for: event)
    }

    /// The misspelling under `point` (view coordinates), shown or not: in a
    /// rendered block, the one whose glyph box holds the point.
    func misspelledWord(at point: CGPoint) -> NSRange? {
        guard let spelling = workspace?.spelling, spelling.isEnabled, !hasMarkedText() else {
            return nil
        }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let drawn = writing.drawnCharacter(at: local)
        let offset: Int? = if drawn.drawn {
            drawn.offset
        } else if let manager = textLayoutManager {
            TextKit2Geometry.character(at: local, in: manager, text: string as NSString)
        } else {
            nil
        }
        return offset.flatMap { spelling.misspelling(at: $0) }
    }

    /// The suggestions (or "No Guesses Found"), a separator, Learn Spelling,
    /// Ignore Spelling and a separator, for the misspelling at `range`.
    func spellingItems(for range: NSRange) -> [NSMenuItem] {
        guard let spelling = workspace?.spelling else {
            return []
        }
        let word = (string as NSString).substring(with: range)
        var items: [NSMenuItem] = []
        let guesses = spelling.guesses(for: range)
        for guess in guesses {
            let item = NSMenuItem(title: guess, action: #selector(useSpellingGuess(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SpellingMenuChoice(range: range, word: word, replacement: guess)
            items.append(item)
        }
        if guesses.isEmpty {
            let none = NSMenuItem(title: L10n.text("No Guesses Found"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        items.append(.separator())
        for (title, action) in [
            (L10n.text("Learn Spelling"), #selector(learnMisspelling(_:))),
            (L10n.text("Ignore Spelling"), #selector(ignoreMisspelling(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = SpellingMenuChoice(range: range, word: word)
            items.append(item)
        }
        items.append(.separator())
        return items
    }

    /// Whether `choice` still names today's text there.
    private func current(_ choice: SpellingMenuChoice) -> Bool {
        let text = string as NSString
        return NSMaxRange(choice.range) <= text.length && text.substring(with: choice.range) == choice.word
    }

    /// Replaces the word with the suggestion: one ordinary, undoable edit
    /// through the input path, like typing it.
    @objc func useSpellingGuess(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SpellingMenuChoice, let replacement = choice.replacement,
              current(choice), isEditable, workspace?.canEditSource != false, !hasMarkedText()
        else {
            return
        }
        breakUndoCoalescing()
        insertText(replacement, replacementRange: choice.range)
        breakUndoCoalescing()
        workspace?.recordOperation("spelling.replace", ["range": NSStringFromRange(choice.range)])
    }

    @objc func learnMisspelling(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SpellingMenuChoice else {
            return
        }
        workspace?.spelling.learn(choice.word)
        workspace?.recordOperation("spelling.learn")
    }

    @objc func ignoreMisspelling(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SpellingMenuChoice else {
            return
        }
        workspace?.spelling.ignore(choice.word)
        workspace?.recordOperation("spelling.ignore")
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(useSpellingGuess(_:)):
            isEditable && workspace?.canEditSource != false
        case #selector(learnMisspelling(_:)), #selector(ignoreMisspelling(_:)):
            true
        default:
            super.validateMenuItem(menuItem)
        }
    }
}

// MARK: - Accessibility

extension ManuscriptTextView {
    // VoiceOver reads misspellings from the attributed string of a range.
    // Assistive apps ask through `accessibilityAttributeValue(_:forParameter:)`
    // with AXAttributedStringForRange, which NSTextView answers in its own
    // `accessibilityAttributedStringForRangeAttributeForParameter:` without
    // calling `accessibilityAttributedString(for:)` (checked with a scratch
    // subclass on macOS 27), so both are overridden. NSTextView builds the
    // string; Prose adds the spelling keys to it.

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        super.accessibilityAttributedString(for: range).map { markingMisspellings($0, range: range) }
    }

    @objc(accessibilityAttributedStringForRangeAttributeForParameter:)
    func spellingAccessibilityAttributedString(forRange parameter: AnyObject?) -> AnyObject? {
        let native = nativeAccessibility(#selector(spellingAccessibilityAttributedString(forRange:)), parameter)
        guard let range = (parameter as? NSValue)?.rangeValue, let string = native as? NSAttributedString else {
            return native
        }
        return markingMisspellings(string, range: range)
    }

    /// `string`, NSTextView's attributed string for `range`, with
    /// `AXMisspelled` on every misspelling in it and `AXMarkedMisspelled` on
    /// those drawn with the underline (all but the caret's word), value true.
    /// The characters stay the source's.
    func markingMisspellings(_ string: NSAttributedString, range: NSRange) -> NSAttributedString {
        guard let spelling = workspace?.spelling, spelling.isEnabled, string.length == range.length,
              range.length > 0
        else {
            return string
        }
        let shown = spelling.shownMisspellings(in: range)
        // The caret's word is misspelled but not drawn as such.
        let caret = selectedRange()
        let hidden = caret.length == 0 ? [caret.location, caret.location - 1].lazy
            .compactMap { spelling.misspelling(at: $0) }
            .first { !shown.contains($0) && NSIntersectionRange($0, range).length > 0 } : nil
        let all = shown + (hidden.map { [$0] } ?? [])
        guard !all.isEmpty else {
            return string
        }
        let marked = NSMutableAttributedString(attributedString: string)
        for misspelling in all {
            let piece = NSIntersectionRange(misspelling, range)
            guard piece.length > 0 else {
                continue
            }
            let local = NSRange(location: piece.location - range.location, length: piece.length)
            marked.addAttribute(.accessibilityMisspelled, value: true, range: local)
            if shown.contains(misspelling) {
                marked.addAttribute(.accessibilityMarkedMisspelled, value: true, range: local)
            }
        }
        return marked
    }
}
