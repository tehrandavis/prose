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
/// visible range. Nothing is drawn yet (step G).
extension Workspace {
    func makeSpellCheckModel() -> SpellCheckModel {
        let model = SpellCheckModel(checker: SystemSpellChecker())
        model.isEnabled = checkSpellingWhileTyping
        model.hasMarkedText = { [weak self] in self?.editor?.hasMarkedText() ?? false }
        return model
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
