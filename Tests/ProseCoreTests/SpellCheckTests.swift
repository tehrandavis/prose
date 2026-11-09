import Foundation
@testable import ProseCore
import Testing

// Spell check: what is checked (decision 7 of the Phase 4 note) and the
// model that checks it (decision 8). Acceptance tests 9 and 14, at the
// model level.

/// A Typst file with every kind spell check skips, each holding a misspelled
/// word, and every kind it reads, each holding one too.
private let spellFixture = """
#set text(lang: "en")
#show heading: set text(fill: blue)
#let note(body) = [Letnote #body]
#import "lib.typ": helper
#include "chaptre.typ"

= Heading wrold

A paragraf with `rawword` and $alpha + betta$ and #text(fill: red, "strng") here.
- list itemm
+ enum itemz
/ Termm: descripton
*strongg* and _emphh_ together.
Footnote#footnote[footnoet text] and #emph[wordz].
#figure(image("fig.png"), caption: [A captoin here])
See @refrence[supplemnt] and <labell> and https://exampel.com/pathh.
// a commnet here
/* block commnet */
Escape \\#hashh and shorthand --- dash... done.
```py
def rawblok(): pass
```

"""

/// Words in the prose of `spellFixture`, each a misspelling.
private let checkedWords = [
    "wrold", "paragraf", "itemm", "itemz", "Termm", "descripton", "strongg", "emphh", "footnoet", "wordz",
    "captoin", "hashh",
]

/// Misspelled words in parts spell check skips.
private let skippedWords = [
    "Letnote", "chaptre", "rawword", "betta", "strng", "refrence", "supplemnt", "labell", "exampel", "pathh",
    "commnet", "rawblok",
]

/// The words (runs of letters) inside `ranges`.
private func words(_ ranges: [NSRange], in source: NSString) -> [String] {
    ranges.flatMap { range in
        source.substring(with: range).components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }
}

private func whole(_ text: NSString) -> NSRange {
    NSRange(location: 0, length: text.length)
}

@Test func spellCheckRangesReadProseAndSkipEverythingElse() throws {
    let source = spellFixture as NSString
    let tree = try #require(SyntaxTree(spellFixture))
    let ranges = SpellCheckRanges.ranges(tree, source: source, within: whole(source))
    let found = Set(words(ranges, in: source))
    for word in checkedWords {
        #expect(found.contains(word), "\(word) is prose")
    }
    for word in skippedWords {
        #expect(!found.contains(word), "\(word) is not prose")
    }
    // No range enters a node of a skipped kind or a piece of code.
    let code: Set<SyntaxKind> = [.hash, .ident, .leftParen, .rightParen, .leftBracket, .rightBracket, .comma, .colon]
    for node in try #require(tree.nodes())
        where SpellCheckRanges.skipped.contains(node.kind) || code.contains(node.kind)
    {
        for range in ranges {
            #expect(
                NSIntersectionRange(range, node.range).length == 0,
                "\(node.kind) \(source.substring(with: node.range))",
            )
        }
    }
    // Sorted and disjoint.
    for (first, second) in zip(ranges, ranges.dropFirst()) {
        #expect(NSMaxRange(first) < second.location)
    }
    // A window returns the same ranges, clipped.
    let line = source.range(of: "- list itemm")
    let window = SpellCheckRanges.ranges(tree, source: source, within: line)
    #expect(words(window, in: source) == ["list", "itemm"])
    #expect(SpellCheckRanges.ranges([], source: source, within: line).isEmpty)
    #expect(try SpellCheckRanges.ranges(#require(tree.nodes()), source: source, within: NSRange()).isEmpty)
}

@Test func spellCheckRangesNeverCutAWordAtANodeBoundary() throws {
    func checked(_ text: String) throws -> [String] {
        let source = text as NSString
        let tree = try #require(SyntaxTree(text))
        return SpellCheckRanges.ranges(tree, source: source, within: whole(source)).map { source.substring(with: $0) }
    }
    // A content block's bracket in the middle of a word: neither half.
    #expect(try checked("#emph[un]believable and more\n") == [" and more\n"])
    // Strong text closed straight into emphasis: neither half.
    #expect(try checked("Go *str*_ong_ now\n") == ["Go ", " now\n"])
    // Delimiters Typst reads as text stay in one range for the checker.
    #expect(try checked("a*b c\n") == ["a*b c\n"])
    #expect(try checked("snake_case word\n") == ["snake_case word\n"])
    // Brackets after a call's name and `#` before it end a word.
    #expect(try checked("Note#footnote[text] end\n") == ["Note", "text", " end\n"])
    // A smart quote is text: one word.
    #expect(try checked("don't stop\n") == ["don't stop\n"])
    // An escape ends a word; the text after it is read.
    #expect(try checked("\\*word\n") == ["word\n"])
}

@Test func spellCheckReportsWordsAsNSTextViewDoes() {
    for word in ["teh", "recieve", "Recieve", "RECIEVED", "O'Brien", "naïve", "colour"] {
        #expect(SpellCheckRanges.reports(word), "\(word)")
    }
    for word in ["x2b", "B2B", "NASA", "HTML", "ABCDE", "I", "camelCase", "iPhone", "McDonald", "teh9"] {
        #expect(!SpellCheckRanges.reports(word), "\(word)")
    }
}

@Test func systemSpellCheckerMasksTextOutsideTheRanges() {
    let masked = SystemSpellChecker.masked(
        "ab `cd` ef",
        keeping: [NSRange(location: 0, length: 3), NSRange(location: 7, length: 3)],
    )
    #expect(masked as String == "ab      ef")
    #expect(SystemSpellChecker.masked("😀x", keeping: [NSRange(location: 0, length: 2), NSRange(location: 9, length: 2)])
        as String == "😀 ")
}

/// The real checker: known misspellings in prose, none in math or raw text,
/// none for words the filter leaves, and ignore and guesses through the tag.
@Test @MainActor func systemSpellCheckerFindsMisspellingsInProseOnly() async throws {
    let text = "We recieve teh letter in $recieve$ and `teh`, from NASA on an iPhone x2b.\n"
    let model = SpellCheckModel(
        checker: SystemSpellChecker(),
        timing: SpellCheckTiming(pause: .milliseconds(1), viewport: .milliseconds(1)),
    )
    model.open(file: URL(fileURLWithPath: "/tmp/real.typ"), text: text)
    await model.idle()
    let source = text as NSString
    #expect(model.misspellings.map { source.substring(with: $0) } == ["recieve", "teh"])
    #expect(model.misspellings.first?.location == source.range(of: "recieve").location)
    let guesses = try model.guesses(for: #require(model.misspellings.last))
    #expect(guesses.contains("the"), "\(guesses)")
    // Ignoring lasts for the document's tag: a fresh check of the same
    // words leaves them out.
    model.ignore("teh")
    let checker = SystemSpellChecker()
    let tag = try #require(model.documentTag)
    let again = await checker.misspellings(
        in: "teh teh recieve",
        ranges: [NSRange(location: 0, length: 15)],
        document: tag,
    )
    #expect(again == [NSRange(location: 8, length: 7)])
    #expect(await checker.misspellings(in: "", ranges: [], document: tag).isEmpty)
    model.close()
}

// MARK: - The model, with a scripted checker

/// Reports the words of `misspelled` inside the ranges, unless ignored for the
/// document or learned. `hold` keeps results until `release()`.
@MainActor
private final class ScriptedSpellChecker: SpellChecker {
    var misspelled: Set<String> = ["teh", "recieve", "wrold", "paragraf", "speling"]
    var ignored: [Int: Set<String>] = [:]
    var learned: Set<String> = []
    var opened: [Int] = []
    var closed: [Int] = []
    var requests: [(text: String, ranges: [NSRange])] = []
    var hold = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var nextTag = 100

    func openDocument() -> Int {
        nextTag += 1
        opened.append(nextTag)
        return nextTag
    }

    func closeDocument(_ tag: Int) {
        closed.append(tag)
        ignored[tag] = nil
    }

    func misspellings(in text: String, ranges: [NSRange], document tag: Int) async -> [NSRange] {
        requests.append((text, ranges))
        if hold {
            await withCheckedContinuation { held.append($0) }
        }
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
        ["guess:" + (text as NSString).substring(with: range)]
    }

    func release() {
        hold = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    var heldCount: Int {
        held.count
    }
}

private let quick = SpellCheckTiming(pause: .milliseconds(20), viewport: .milliseconds(1))
private let fileA = URL(fileURLWithPath: "/tmp/a.typ")
private let fileB = URL(fileURLWithPath: "/tmp/b.typ")

/// The text a model reads, and native edits of it.
@MainActor
private final class SpellHarness {
    let checker = ScriptedSpellChecker()
    let model: SpellCheckModel
    let text: NSMutableString
    var changes: [[NSRange]] = []
    var marked = false

    init(_ text: String, timing: SpellCheckTiming = quick, visible: NSRange? = nil) {
        self.text = NSMutableString(string: text)
        model = SpellCheckModel(checker: checker, timing: timing)
        model.onChange = { [weak self] in self?.changes.append($0) }
        model.hasMarkedText = { [weak self] in self?.marked ?? false }
        model.open(file: fileA, text: text)
        model.setVisibleRange(visible ?? NSRange(location: 0, length: self.text.length))
    }

    func edit(_ range: NSRange, _ replacement: String) {
        text.replaceCharacters(in: range, with: replacement)
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        model.textDidChange(edited: edited, delta: edited.length - range.length, in: text)
    }

    func type(_ string: String, at offset: Int) {
        var offset = offset
        for character in string {
            edit(NSRange(location: offset, length: 0), String(character))
            offset += String(character).utf16.count
            model.selectionDidChange(NSRange(location: offset, length: 0))
        }
    }

    var words: [String] {
        model.misspellings.map { text.substring(with: $0) }
    }

    var shownWords: [String] {
        model.shownMisspellings.map { text.substring(with: $0) }
    }

    func range(_ string: String) -> NSRange {
        text.range(of: string)
    }
}

@Test @MainActor func spellCheckModelMovesMisspellingsWithTheTextAndChecksAfterThePause() async {
    // Acceptance test 14 at the model level.
    let harness = SpellHarness("= A wrold\n\nThe teh letter.\n\nA clean line.\n")
    await harness.model.idle()
    #expect(harness.words == ["wrold", "teh"])
    #expect(harness.changes.last == [harness.range("wrold"), harness.range("teh")])
    // Typing before a misspelling moves it at once, with no check.
    let requests = harness.checker.requests.count
    harness.type("Dear ", at: harness.range("The").location)
    #expect(harness.words == ["wrold", "teh"])
    #expect(harness.model.misspellings[1] == harness.range("teh"))
    #expect(harness.checker.requests.count == requests)
    // Correcting the word removes it; the check after the pause does not
    // bring it back.
    let teh = harness.range("teh")
    harness.edit(NSRange(location: teh.location + 1, length: 2), "he")
    harness.model.selectionDidChange(NSRange(location: NSMaxRange(teh), length: 0))
    #expect(harness.words == ["wrold"])
    #expect(harness.changes.last == [teh])
    await harness.model.idle()
    #expect(harness.words == ["wrold"])
    #expect(harness.checker.requests.count == requests + 1)
    // A half-typed misspelling under the caret is found after the pause but
    // not shown until the caret leaves it.
    let end = harness.range("A clean line.").location + 7
    harness.changes = []
    harness.type(" recieve", at: end)
    await harness.model.idle()
    #expect(harness.words == ["wrold", "recieve"])
    #expect(harness.shownWords == ["wrold"])
    #expect(harness.changes.isEmpty)
    harness.model.selectionDidChange(NSRange(location: 0, length: 0))
    #expect(harness.shownWords == ["wrold", "recieve"])
    #expect(harness.changes == [[harness.range("recieve")]])
    #expect(harness.model.shownMisspellings(in: harness.range("A clean recieve")) == [harness.range("recieve")])
    // A selection with length hides nothing.
    harness.model.selectionDidChange(NSRange(location: harness.range("recieve").location + 2, length: 3))
    #expect(harness.shownWords == ["wrold", "recieve"])
    // Typing a letter against a misspelling changes the word; a space does not.
    let wrold = harness.range("wrold")
    harness.edit(NSRange(location: NSMaxRange(wrold), length: 0), " ")
    #expect(harness.words == ["wrold", "recieve"])
    harness.edit(NSRange(location: wrold.location, length: 0), "x")
    #expect(harness.words == ["recieve"])
    await harness.model.idle()
    #expect(harness.words == ["recieve"])
}

@Test @MainActor func spellCheckModelAppliesNothingWhileTextIsMarked() async {
    let harness = SpellHarness("First line.\n\nSecond wrold.\n", visible: NSRange(location: 0, length: 4))
    await harness.model.idle()
    #expect(harness.words == ["wrold"])
    harness.marked = true
    harness.changes = []
    // A composition at the start; a misspelling typed elsewhere is checked,
    // and its result waits.
    let second = harness.range("Second").location
    harness.edit(NSRange(location: second, length: 0), "speling ")
    harness.model.selectionDidChange(NSRange(location: 1, length: 0))
    await harness.model.idle()
    #expect(harness.words == ["wrold"])
    #expect(harness.changes.isEmpty)
    // The caret's word stays as it was while text is marked.
    harness.model.selectionDidChange(NSRange(location: harness.range("wrold").location + 1, length: 0))
    #expect(harness.changes.isEmpty)
    #expect(await harness.model.nextMisspelling(after: 0) == nil)
    // An edit during the composition moves the waiting result.
    harness.edit(NSRange(location: 0, length: 0), "X")
    harness.marked = false
    harness.model.selectionDidChange(NSRange(location: 0, length: 0))
    await harness.model.idle()
    #expect(harness.words == ["speling", "wrold"])
    #expect(harness.model.misspellings == [harness.range("speling"), harness.range("wrold")])
}

@Test @MainActor func spellCheckModelChecksTheViewportAndCachesParagraphs() async {
    let line = "A plain line of words that are spelled well.\n"
    var lines = (0 ..< 400).map { "\($0) " + line }
    lines[10] = "Near the top, teh mistake.\n"
    lines[390] = "Near the end, wrold mistake.\n"
    let harness = SpellHarness(lines.joined(), visible: NSRange(location: 0, length: 400))
    await harness.model.idle()
    // Only paragraphs in and near the viewport are checked.
    #expect(harness.words == ["teh"])
    let near = harness.model.paragraphsChecked
    #expect(near > 10 && near < 120, "\(near)")
    #expect(harness.checker.requests.count == 1)
    // Scrolling checks the new viewport.
    let end = harness.text.length
    harness.model.setVisibleRange(NSRange(location: end - 400, length: 400))
    await harness.model.idle()
    #expect(harness.words == ["teh", "wrold"])
    #expect(harness.checker.requests.count == 2)
    // Scrolling back checks nothing; the same visible range is no change.
    harness.model.setVisibleRange(NSRange(location: 0, length: 400))
    harness.model.setVisibleRange(NSRange(location: 0, length: 400))
    await harness.model.idle()
    #expect(harness.checker.requests.count == 2)
    // A paragraph whose text was checked before is answered from the cache
    // after an edit restores it.
    let hits = harness.model.cacheHits
    let mistake = harness.range("teh mistake")
    harness.edit(NSRange(location: mistake.location, length: 3), "the")
    await harness.model.idle()
    #expect(harness.words == ["wrold"])
    harness.edit(NSRange(location: mistake.location, length: 3), "teh")
    await harness.model.idle()
    #expect(harness.words == ["teh", "wrold"])
    #expect(harness.model.cacheHits > hits)
    #expect(harness.model.mainThreadTime > .zero)
    // Code-only paragraphs need no request.
    let code = SpellHarness("#let x = 1\n#set text(lang: \"en\")\n")
    await code.model.idle()
    #expect(code.checker.requests.isEmpty)
    #expect(code.model.paragraphsChecked == 0)
}

@Test @MainActor func spellCheckModelSettingOffHoldsAndChecksNothing() async {
    let harness = SpellHarness("The teh letter.\n")
    await harness.model.idle()
    #expect(harness.words == ["teh"])
    harness.changes = []
    harness.model.isEnabled = false
    #expect(harness.words.isEmpty)
    #expect(harness.changes == [[harness.range("teh")]])
    harness.model.isEnabled = false
    harness.type(" wrold", at: 3)
    harness.model.setVisibleRange(NSRange(location: 0, length: 3))
    await harness.model.idle()
    #expect(harness.words.isEmpty)
    #expect(harness.checker.requests.count == 1)
    #expect(await harness.model.nextMisspelling(after: 0) == nil)
    // On again: the text as it is now, parsed afresh.
    harness.model.isEnabled = true
    await harness.model.idle()
    #expect(harness.words == ["wrold", "teh"])
}

@Test @MainActor func spellCheckModelIgnoresAndLearnsThroughTheChecker() async throws {
    let harness = SpellHarness("teh one\n\nteh two\n\nwrold three\n")
    await harness.model.idle()
    #expect(harness.words == ["teh", "teh", "wrold"])
    let tag = try #require(harness.model.documentTag)
    harness.changes = []
    harness.model.ignore("teh")
    #expect(harness.checker.ignored[tag] == ["teh"])
    #expect(harness.words == ["wrold"])
    #expect(harness.changes.count == 1)
    // A new paragraph with the ignored word is not reported for this file.
    harness.type("\nteh four\n", at: harness.text.length)
    await harness.model.idle()
    #expect(harness.words == ["wrold"])
    harness.model.learn("wrold")
    #expect(harness.checker.learned == ["wrold"])
    #expect(harness.words.isEmpty)
    #expect(harness.model.guesses(for: harness.range("three")) == ["guess:three"])
    #expect(harness.model.guesses(for: NSRange(location: 10000, length: 2)).isEmpty)
}

@Test @MainActor func spellCheckModelKeepsOneTagPerOpenFile() async throws {
    let harness = SpellHarness("teh\n")
    let first = try #require(harness.model.documentTag)
    #expect(harness.checker.opened == [first])
    // The same file reloaded keeps its tag and its ignored words.
    harness.model.ignore("teh")
    harness.model.open(file: fileA, text: "teh again\n")
    #expect(harness.model.documentTag == first)
    #expect(harness.checker.closed.isEmpty)
    // Another file closes the tag and opens a new one.
    harness.model.open(file: fileB, text: "teh other\n")
    let second = try #require(harness.model.documentTag)
    #expect(second != first)
    #expect(harness.checker.closed == [first])
    harness.model.setVisibleRange(NSRange(location: 0, length: 4))
    await harness.model.idle()
    #expect(harness.model.misspellings == [NSRange(location: 0, length: 3)])
    // Closing closes it too, and forgets everything.
    harness.model.close()
    #expect(harness.checker.closed == [first, second])
    #expect(harness.model.documentTag == nil && harness.model.file == nil)
    #expect(harness.model.misspellings.isEmpty)
    harness.model.ignore("x")
    #expect(harness.model.guesses(for: NSRange(location: 0, length: 0)).isEmpty)
    #expect(await harness.model.nextMisspelling(after: 0) == nil)
    await harness.model.idle()
}

@Test @MainActor func spellCheckModelFindsTheNextMisspellingForward() async {
    let line = "Clean words only in this line of the book.\n"
    var lines = Array(repeating: line, count: 2000)
    lines[1500] = "Far below there is a wrold here.\n"
    lines[200] = "Near the top teh word.\n"
    let harness = SpellHarness(lines.joined(), visible: NSRange(location: 0, length: 100))
    await harness.model.idle()
    #expect(harness.words.isEmpty)
    let start = harness.range("Near the top").location
    // From the start of the text: the near one, already... not checked yet.
    let near = await harness.model.nextMisspelling(after: 0)
    #expect(near == harness.range("teh"))
    // From after it: the far one, checked in steps in the background.
    let far = await harness.model.nextMisspelling(after: start + 20)
    #expect(far == harness.range("wrold"))
    #expect(harness.checker.requests.count > 2)
    // From after the last one: back to the start.
    let wrapped = await harness.model.nextMisspelling(after: NSMaxRange(harness.range("wrold")))
    #expect(wrapped == harness.range("teh"))
    // A caret inside a word: that word is behind it.
    let inside = await harness.model.nextMisspelling(after: harness.range("teh").location + 1)
    #expect(inside == harness.range("wrold"))
    // None at all.
    let clean = SpellHarness(String(repeating: line, count: 50), visible: NSRange(location: 0, length: 10))
    await clean.model.idle()
    #expect(await clean.model.nextMisspelling(after: 300) == nil)
    let empty = SpellHarness("")
    #expect(await empty.model.nextMisspelling(after: 0) == nil)
}

@Test @MainActor func spellCheckModelMovesResultsThatArriveAfterEdits() async {
    let harness = SpellHarness("First teh line.\n\nSecond wrold line.\n\nThird recieve line.\n")
    harness.checker.hold = true
    while harness.checker.heldCount == 0 {
        await Task.yield()
    }
    // While the check runs: an edit before every paragraph, and one inside
    // the third.
    harness.edit(NSRange(location: 0, length: 0), "Zero.\n\n")
    let third = harness.range("Third")
    harness.edit(NSRange(location: NSMaxRange(third), length: 0), " more")
    harness.checker.release()
    await harness.model.idle()
    #expect(harness.words == ["teh", "wrold", "recieve"])
    #expect(harness.model.misspellings == [harness.range("teh"), harness.range("wrold"), harness.range("recieve")])
}

@Test @MainActor func spellCheckModelRebasesSeededRandomEditsLikeAFreshCheck() async {
    // Acceptance test 9: random edits, rebased and rechecked, give what a
    // fresh check of the final text gives.
    let pieces = [
        "teh ", "the ", "wrold ", "world ", "recieve ", "*teh* ", "_wrold_ ", "`teh` ", "$teh$ ", "#emph[teh] ",
        "\n", "\n\n", "= Head teh\n", "- item wrold\n", "// teh\n", "@teh ", "<wrold> ", "paragraf ", "x",
    ]
    for seed in [UInt64(1), 7, 42, 2026, 99991] {
        var random = SeededRandom(state: seed)
        let start = (0 ..< 40).map { _ in pieces[random.below(pieces.count)] }.joined()
        let harness = SpellHarness(start, timing: SpellCheckTiming(pause: .milliseconds(5), viewport: .milliseconds(1)))
        await harness.model.idle()
        for step in 0 ..< 60 {
            let length = harness.text.length
            let location = random.below(length + 1)
            let removed = random.below(3) == 0 ? min(random.below(12), length - location) : 0
            let inserted = random.below(4) == 0 ? "" : pieces[random.below(pieces.count)]
            harness.edit(NSRange(location: location, length: removed), inserted)
            harness.model.setVisibleRange(NSRange(location: 0, length: harness.text.length))
            // Before any recheck, every misspelling still covers a
            // misspelled word of the new text.
            for range in harness.model.misspellings {
                #expect(
                    harness.checker.misspelled.contains(harness.text.substring(with: range)),
                    "seed \(seed) step \(step)",
                )
            }
            if step.isMultiple(of: 7) {
                await harness.model.idle()
            }
        }
        await harness.model.idle()
        let fresh = SpellHarness(harness.text as String)
        await fresh.model.idle()
        #expect(harness.model.misspellings == fresh.model.misspellings, "seed \(seed)")
        #expect(!fresh.model.misspellings.isEmpty)
    }
}

@Test @MainActor func spellCheckModelStartsAgainWhenTheTextIsOutOfStep() async {
    let harness = SpellHarness("teh\n")
    await harness.model.idle()
    // An edit that does not fit the mirrored text: the model reads the
    // view's text afresh.
    let replaced = NSMutableString(string: "a wrold and more text\n")
    harness.model.textDidChange(edited: NSRange(location: 10, length: 5), delta: -20, in: replaced)
    harness.model.setVisibleRange(NSRange(location: 0, length: replaced.length))
    await harness.model.idle()
    #expect(harness.model.misspellings == [replaced.range(of: "wrold")])
    // Edits before a file opens only mirror the text.
    let unopened = SpellCheckModel(checker: ScriptedSpellChecker(), timing: quick)
    unopened.textDidChange(edited: NSRange(location: 0, length: 3), delta: 3, in: "teh")
    await unopened.idle()
    #expect(unopened.misspellings.isEmpty)
}

// MARK: - Cost on the book fixtures

/// Measures, with the real checker, a viewport check of War and Peace and
/// SICP: how long the check takes off the main thread and how much
/// main-thread time preparing it and applying its results takes.
@Test @MainActor func spellCheckViewportCostOnTheBooks() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    for (name, path, visible) in [
        ("war-and-peace", "Examples/Books/WarAndPeace/war-and-peace-highlighted.typ", 3000),
        ("sicp", "Examples/Books/SICP/main.typ", 6000),
    ] {
        let text = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
        let length = (text as NSString).length
        let model = SpellCheckModel(
            checker: SystemSpellChecker(),
            timing: SpellCheckTiming(pause: .milliseconds(300), viewport: .zero),
        )
        let clock = ContinuousClock()
        var started = clock.now
        model.open(file: URL(fileURLWithPath: "/tmp/\(name).typ"), text: text)
        model.setVisibleRange(NSRange(location: 0, length: visible))
        await model.idle()
        let first = milliseconds(started.duration(to: clock.now))
        var walls: [Double] = [], mains: [Double] = [], paragraphs: [Int] = [], found: [Int] = []
        for fraction in [0.3, 0.5, 0.7] {
            let main = model.mainThreadTime, checked = model.paragraphsChecked, count = model.misspellings.count
            started = clock.now
            model.setVisibleRange(NSRange(location: Int(Double(length) * fraction), length: visible))
            await model.idle()
            walls.append(milliseconds(started.duration(to: clock.now)))
            mains.append(milliseconds(model.mainThreadTime - main))
            paragraphs.append(model.paragraphsChecked - checked)
            found.append(model.misspellings.count - count)
        }
        print(
            "SPELL-BENCH \(name): open + first viewport \(String(format: "%.1f", first)) ms;",
            "viewport checks \(walls.map { String(format: "%.1f", $0) }) ms wall,",
            "\(mains.map { String(format: "%.2f", $0) }) ms main thread,",
            "\(paragraphs) paragraphs, \(found) misspellings",
        )
        #expect(paragraphs.allSatisfy { $0 > 0 })
        #expect(mains.allSatisfy { $0 < 50 }, "\(mains)")
        model.close()
    }
}

/// Phase 4 step G: a right-click finds the misspelling that holds a
/// character, shown or not.
@Test @MainActor func spellCheckModelFindsTheMisspellingAtAnOffset() async {
    let harness = SpellHarness("Some teh and wrold here.\n")
    await harness.model.idle()
    let teh = harness.range("teh"), wrold = harness.range("wrold")
    #expect(harness.model.misspellings == [teh, wrold])
    #expect(harness.model.misspelling(at: teh.location) == teh)
    #expect(harness.model.misspelling(at: NSMaxRange(teh) - 1) == teh)
    #expect(harness.model.misspelling(at: NSMaxRange(teh)) == nil)
    #expect(harness.model.misspelling(at: 0) == nil)
    #expect(harness.model.misspelling(at: wrold.location + 2) == wrold)
    // The caret's word is not shown, but it is still found.
    harness.model.selectionDidChange(NSRange(location: wrold.location + 2, length: 0))
    #expect(!harness.model.shownMisspellings.contains(wrold))
    #expect(harness.model.misspelling(at: wrold.location + 2) == wrold)
}
