import AppKit
import Foundation

/// A spell checker for `SpellCheckModel` (decision 8 of the Phase 4 note).
/// The app uses `SystemSpellChecker`; tests script one.
///
/// Documents are spell document tags: words ignored in a document stay
/// ignored for that tag until it is closed. Learned words go to the user's
/// dictionary for every document.
@MainActor
public protocol SpellChecker: AnyObject {
    /// A new spell document tag.
    func openDocument() -> Int
    /// Forgets the tag and its ignored words.
    func closeDocument(_ tag: Int)
    /// The misspelled words of `text` inside `ranges` (UTF-16, within `text`),
    /// as UTF-16 ranges of `text`, sorted. Runs off the main thread.
    func misspellings(in text: String, ranges: [NSRange], document tag: Int) async -> [NSRange]
    /// Stops reporting `word` in the document `tag`.
    func ignore(_ word: String, document tag: Int)
    /// Adds `word` to the user's dictionary.
    func learn(_ word: String)
    /// Suggested replacements for the word at `range` of `text`.
    func guesses(for range: NSRange, in text: String, document tag: Int) -> [String]
}

/// `NSSpellChecker.shared`, spelling only.
///
/// **Threads.** AppKit documents no thread safety for NSSpellChecker beyond
/// its asynchronous API, and it is not in AppKit's list of thread-safe
/// classes. `requestChecking(of:range:types:options:inSpellDocumentWithTag:completionHandler:)`
/// is the API AppKit itself documents for checking "in the background" (its
/// header: "Requests unified text checking in the background ... The
/// completion handler will be called (in an arbitrary context) when results
/// are available"). So every call starts on the main actor, the checking
/// runs wherever AppKit runs it, and the completion handler only converts
/// the results to ranges before it resumes the caller. `checkString` on a
/// queue of Prose's own would rely on undocumented behaviour.
///
/// The language follows the system's spelling setting: no language and no
/// orthography are passed. Text outside the checkable ranges is replaced by
/// spaces of the same UTF-16 length, so offsets stay those of `text` and one
/// request checks a whole batch of paragraphs.
@MainActor
public final class SystemSpellChecker: SpellChecker {
    private let checker: NSSpellChecker

    public init(checker: NSSpellChecker = .shared) {
        self.checker = checker
    }

    public func openDocument() -> Int {
        NSSpellChecker.uniqueSpellDocumentTag()
    }

    public func closeDocument(_ tag: Int) {
        checker.closeSpellDocument(withTag: tag)
    }

    public func misspellings(in text: String, ranges: [NSRange], document tag: Int) async -> [NSRange] {
        let masked = Self.masked(text, keeping: ranges)
        guard masked.length > 0, !ranges.isEmpty else {
            return []
        }
        let found: [NSRange] = await withCheckedContinuation { continuation in
            checker.requestChecking(
                of: masked as String,
                range: NSRange(location: 0, length: masked.length),
                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                options: nil,
                inSpellDocumentWithTag: tag,
                completionHandler: Self.completion(continuation),
            )
        }
        let source = text as NSString
        return found.filter { range in
            NSMaxRange(range) <= source.length && SpellCheckRanges.reports(source.substring(with: range))
        }
    }

    public func ignore(_ word: String, document tag: Int) {
        checker.ignoreWord(word, inSpellDocumentWithTag: tag)
    }

    public func learn(_ word: String) {
        checker.learnWord(word)
    }

    public func guesses(for range: NSRange, in text: String, document tag: Int) -> [String] {
        checker.guesses(forWordRange: range, in: text, language: nil, inSpellDocumentWithTag: tag) ?? []
    }

    /// The completion handler, built outside the main actor: AppKit calls it
    /// on a queue of its own, and a closure formed in a main-actor method
    /// would trap there.
    private nonisolated static func completion(
        _ continuation: CheckedContinuation<[NSRange], Never>,
    ) -> @Sendable (Int, [NSTextCheckingResult], NSOrthography, Int) -> Void {
        { _, results, _, _ in
            continuation.resume(returning: results.filter { $0.resultType == .spelling }.map(\.range))
        }
    }

    /// `text` with every UTF-16 unit outside `ranges` replaced by a space.
    nonisolated static func masked(_ text: String, keeping ranges: [NSRange]) -> NSString {
        let source = text as NSString
        var units = [unichar](repeating: 0x20, count: source.length)
        for range in ranges {
            let range = NSIntersectionRange(range, NSRange(location: 0, length: source.length))
            guard range.length > 0 else {
                continue
            }
            units.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    source.getCharacters(base + range.location, range: range)
                }
            }
        }
        return NSString(characters: units, length: units.count)
    }
}
