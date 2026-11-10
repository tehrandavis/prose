import Foundation

/// When `SpellCheckModel` checks.
public struct SpellCheckTiming: Sendable {
    /// After typing pauses, before the edited paragraph is checked.
    public var pause: Duration
    /// After a file opens or the view scrolls, before the paragraphs in and
    /// near the viewport are checked; it coalesces a scroll.
    public var viewport: Duration

    public init(pause: Duration = .milliseconds(300), viewport: Duration = .milliseconds(50)) {
        self.pause = pause
        self.viewport = viewport
    }

    public static let standard = SpellCheckTiming()
}

/// Spell check for one open file (decision 8 of the Phase 4 note): the
/// misspellings of today's text, and the checks that find them.
///
/// The view forwards edits, the selection, marked text and the visible range.
/// The model mirrors the text, moves its misspellings across each native edit
/// (as `SourceStyler` moves its runs) and checks paragraphs (`NSString`
/// paragraphs: lines) in and near the viewport when a file opens or the view
/// scrolls, and the edited paragraphs once typing pauses. Checkable ranges
/// (`SpellCheckRanges`) come from a syntax tree that a background actor keeps
/// in step with the edits, so no parse runs on the main thread. Results are
/// cached per paragraph by its text and checkable ranges.
///
/// It never writes to the text storage. `onChange` names the ranges whose
/// shown misspellings changed, so the drawing (step G) can follow.
///
/// A misspelling the caret is inside (its ends included) is not shown until
/// the caret leaves it, so a half-typed word is not marked. While text is
/// marked, no result is applied and the caret's word stays as it was; both
/// catch up when the composition ends (`selectionDidChange`).
@MainActor
public final class SpellCheckModel {
    /// Whether the view is composing text.
    public var hasMarkedText: () -> Bool = { false }
    /// UTF-16 ranges whose shown misspellings changed, sorted and merged.
    public var onChange: (([NSRange]) -> Void)?

    /// "Check Spelling While Typing". Off holds no misspellings and checks nothing.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            if isEnabled {
                reopen = text as String
                unsent = []
                scheduleViewport()
            } else {
                forget()
            }
            resumeWaitersIfIdle()
        }
    }

    public private(set) var file: URL?
    /// The spell document tag of the open file; ignored words last as long as it.
    public private(set) var documentTag: Int?
    /// Every misspelling of today's text, sorted, the caret's word included.
    public private(set) var misspellings: [NSRange] = []

    private let checker: any SpellChecker
    private let timing: SpellCheckTiming
    private let source = SpellCheckSource()
    private let text = NSMutableString()
    /// Text known to be checked, as sorted, merged ranges of whole paragraphs.
    private var checked: [NSRange] = []
    /// Paragraphs edited since the last check.
    private var edited: [NSRange] = []
    private var visible: NSRange?
    /// The empty selection's location; nil for a selection with length.
    private var caret: Int?
    /// The caret as last used to hide a misspelling; it stays while text is marked.
    private var hidingCaret: Int?
    private var cache: [SpellParagraphKey: [NSRange]] = [:]

    /// Increases with every open, close and switch off; older results are dropped.
    private var generation = 0
    /// Increases with every edit.
    private var revision = 0
    /// Edits since the oldest result still on its way: the revision each one
    /// made, its range in the text before it and its change in length.
    private var log: [(revision: Int, range: NSRange, delta: Int, text: String)] = []
    /// The text the background syntax tree must start from, then edits for it.
    private var reopen: String?
    private var unsent: [TextReplacement] = []
    private var pauseTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    /// The last job; each job waits for the one before, so the actor sees
    /// edits in order.
    private var lastJob: Task<Void, Never>?
    private var jobsRunning = 0
    /// Results that wait for a composition to end.
    private var arrived: [SpellResult] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Characters around the viewport checked with it, at least.
    public static let margin = 2000
    /// Cached paragraphs before the cache starts again.
    static let cacheLimit = 20000
    /// Characters `nextMisspelling` checks per step.
    static let searchStep = 16000

    /// For tests and measurements: checker requests made, paragraphs checked,
    /// paragraphs answered from the cache, and main-thread time spent
    /// preparing requests and applying results.
    public private(set) var requests = 0
    public private(set) var paragraphsChecked = 0
    public private(set) var cacheHits = 0
    public private(set) var mainThreadTime: Duration = .zero

    public init(checker: any SpellChecker, timing: SpellCheckTiming = .standard) {
        self.checker = checker
        self.timing = timing
    }

    // MARK: - Lifecycle

    /// A file was opened or its text replaced. Another file gets a new spell
    /// document tag; the same file keeps its tag and its ignored words.
    public func open(file: URL, text: String) {
        if file != self.file || documentTag == nil {
            closeTag()
            cache = [:]
            documentTag = checker.openDocument()
        }
        self.file = file
        forget()
        self.text.setString(text)
        visible = nil
        caret = nil
        hidingCaret = nil
        if isEnabled {
            reopen = text
            scheduleViewport()
        }
    }

    /// The file closed: forgets everything and closes its spell document tag.
    public func close() {
        forget()
        closeTag()
        cache = [:]
        file = nil
        text.setString("")
        resumeWaitersIfIdle()
    }

    private func closeTag() {
        if let documentTag {
            checker.closeDocument(documentTag)
        }
        documentTag = nil
    }

    /// Drops misspellings, checks and timers, and reports what was shown.
    private func forget() {
        generation += 1
        pauseTask?.cancel()
        viewportTask?.cancel()
        pauseTask = nil
        viewportTask = nil
        let shown = shownMisspellings
        misspellings = []
        checked = []
        edited = []
        arrived = []
        log = []
        reopen = nil
        unsent = []
        report(shown)
    }

    // MARK: - Input from the view

    /// Forwarded from the text storage delegate when characters changed.
    /// `edited` is in the new text `storage`; `delta` is its change in length.
    public func textDidChange(edited: NSRange, delta: Int, in storage: NSString) {
        let original = NSRange(location: edited.location, length: edited.length - delta)
        guard original.location >= 0, original.length >= 0, NSMaxRange(original) <= text.length,
              NSMaxRange(edited) <= storage.length
        else {
            // Out of step: start again from the view's text.
            text.setString(storage as String)
            if file != nil, isEnabled {
                forget()
                reopen = storage as String
                scheduleViewport()
            }
            return
        }
        let replacement = storage.substring(with: edited)
        text.replaceCharacters(in: original, with: replacement)
        guard isEnabled, file != nil else {
            return
        }
        revision += 1
        if jobsRunning > 0 || !arrived.isEmpty {
            log.append((revision, original, delta, replacement))
        }
        if reopen != nil {
            reopen = text as String
        } else {
            unsent.append(TextReplacement(range: original, text: replacement))
        }
        var changed: [NSRange] = []
        misspellings = misspellings.compactMap { range in
            guard let moved = Self.rebase(range, editing: original, delta: delta, in: text) else {
                changed.append(SourceStyling.rebase(range, editing: original, delta: delta))
                return nil
            }
            return moved
        }
        let paragraphs = NSUnionRange(
            text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: 0)),
            text.paragraphRange(for: NSRange(location: min(NSMaxRange(edited), text.length), length: 0)),
        )
        checked = Self.subtract(
            paragraphs,
            from: checked.map { SourceStyling.rebase($0, editing: original, delta: delta) },
        )
        self.edited = SpellCheckRanges.merged(
            self.edited.map { SourceStyling.rebase($0, editing: original, delta: delta) } + [paragraphs],
        )
        if let caret {
            self.caret = caret >= NSMaxRange(original) ? caret + delta : min(caret, NSMaxRange(edited))
        }
        if let hidingCaret {
            self.hidingCaret = hidingCaret >= NSMaxRange(original) ? hidingCaret + delta
                : min(hidingCaret, NSMaxRange(edited))
        }
        report(changed)
        schedulePause()
    }

    /// The selection or the marked text changed. Applies results that waited
    /// for a composition, and shows or hides the caret's word.
    public func selectionDidChange(_ selection: NSRange) {
        caret = selection.length == 0 ? selection.location : nil
        guard !hasMarkedText() else {
            return
        }
        let before = hiddenMisspelling
        hidingCaret = caret
        let after = hiddenMisspelling
        if before != after {
            report([before, after].compactMap(\.self))
        }
        applyArrived()
    }

    /// The characters in view changed.
    public func setVisibleRange(_ range: NSRange) {
        guard range != visible else {
            return
        }
        visible = range
        scheduleViewport()
    }

    // MARK: - Output

    /// The misspellings to draw: all but the one the caret is inside.
    public var shownMisspellings: [NSRange] {
        guard let hidden = hiddenMisspelling else {
            return misspellings
        }
        return misspellings.filter { $0 != hidden }
    }

    /// Shown misspellings that intersect `range`.
    public func shownMisspellings(in range: NSRange) -> [NSRange] {
        let hidden = hiddenMisspelling
        var index = firstMisspelling(endingAfter: range.location)
        var result: [NSRange] = []
        while index < misspellings.count, misspellings[index].location < NSMaxRange(range) {
            if misspellings[index] != hidden {
                result.append(misspellings[index])
            }
            index += 1
        }
        return result
    }

    /// The misspelling that holds the character at `offset`, shown or not:
    /// what a right-click on that character offers suggestions for.
    public func misspelling(at offset: Int) -> NSRange? {
        let index = firstMisspelling(endingAfter: offset)
        guard index < misspellings.count, misspellings[index].location <= offset else {
            return nil
        }
        return misspellings[index]
    }

    /// The misspelling the caret is inside, ends included.
    private var hiddenMisspelling: NSRange? {
        guard let caret = hidingCaret else {
            return nil
        }
        let index = firstMisspelling(endingAfter: caret - 1)
        guard index < misspellings.count, misspellings[index].location <= caret else {
            return nil
        }
        return misspellings[index]
    }

    /// The first misspelling that starts at or after `location`.
    private func firstMisspelling(startingAtLeast location: Int) -> Int {
        var low = 0, high = misspellings.count
        while low < high {
            let middle = (low + high) / 2
            if misspellings[middle].location < location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The first misspelling whose end lies after `location`.
    private func firstMisspelling(endingAfter location: Int) -> Int {
        var low = 0, high = misspellings.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(misspellings[middle]) <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Returns once nothing is waiting: no timer and no check on its way.
    /// Results held for a composition do not count.
    public func idle() async {
        guard !isIdle else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private var isIdle: Bool {
        pauseTask == nil && viewportTask == nil && jobsRunning == 0
    }

    private func resumeWaitersIfIdle() {
        guard isIdle else {
            return
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    // MARK: - Commands

    /// The first misspelling at or after `offset`, checking paragraphs
    /// forward in the background until it finds one, then from the start of
    /// the text. Nil when there is none, spell check is off, text is marked,
    /// or the text changes during the search.
    public func nextMisspelling(after offset: Int) async -> NSRange? {
        guard isEnabled, file != nil, !hasMarkedText() else {
            return nil
        }
        let generation = generation, revision = revision
        let length = text.length, origin = min(max(0, offset), length)
        var cursor = text.paragraphRange(for: NSRange(location: origin, length: 0)).location
        var wrapped = false
        while true {
            let end = min(length, wrapped ? origin : cursor + Self.searchStep)
            let window = text.paragraphRange(for: NSRange(location: cursor, length: max(0, end - cursor)))
            await enqueue { Self.subtract($0.checked, from: [window], keepingParagraphsOf: $0.text) }.value
            guard generation == self.generation, revision == self.revision, !hasMarkedText() else {
                return nil
            }
            let index = firstMisspelling(startingAtLeast: wrapped ? window.location : max(window.location, origin))
            if index < misspellings.count, misspellings[index].location < NSMaxRange(window) {
                return misspellings[index]
            }
            cursor = NSMaxRange(window)
            if wrapped, cursor >= origin {
                return nil
            }
            if cursor >= length {
                guard !wrapped, origin > 0 else {
                    return nil
                }
                wrapped = true
                cursor = 0
            }
        }
    }

    /// "Ignore Spelling": `word` is no longer reported for this file's session.
    public func ignore(_ word: String) {
        guard let documentTag else {
            return
        }
        checker.ignore(word, document: documentTag)
        drop(word)
    }

    /// "Learn Spelling": `word` goes to the user's dictionary.
    public func learn(_ word: String) {
        checker.learn(word)
        drop(word)
    }

    /// Suggestions for the word at `range` of today's text.
    public func guesses(for range: NSRange) -> [String] {
        guard let documentTag, range.location >= 0, NSMaxRange(range) <= text.length else {
            return []
        }
        let paragraph = text.paragraphRange(for: range)
        return checker.guesses(
            for: NSRange(location: range.location - paragraph.location, length: range.length),
            in: text.substring(with: paragraph),
            document: documentTag,
        )
    }

    /// Removes misspellings of `word` and forgets cached results, which may hold it.
    private func drop(_ word: String) {
        cache = [:]
        var removed: [NSRange] = []
        let shown = shownMisspellings
        misspellings.removeAll { range in
            let matches = text.substring(with: range) == word
            if matches, shown.contains(range) {
                removed.append(range)
            }
            return matches
        }
        report(removed)
    }

    // MARK: - Scheduling

    private func schedulePause() {
        pauseTask?.cancel()
        viewportTask?.cancel()
        viewportTask = nil
        pauseTask = timer(timing.pause) { $0.pauseTask = nil }
    }

    private func scheduleViewport() {
        guard isEnabled, file != nil, pauseTask == nil else {
            // The pause's check covers the viewport too.
            return
        }
        viewportTask?.cancel()
        viewportTask = timer(timing.viewport) { $0.viewportTask = nil }
    }

    private func timer(_ delay: Duration, _ fire: @escaping (SpellCheckModel) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else {
                return
            }
            fire(self)
            enqueue { $0.targets() }
            resumeWaitersIfIdle()
        }
    }

    /// Paragraphs to check now: the edited ones and those in and near the
    /// viewport that are not checked.
    private func targets() -> [NSRange] {
        let length = text.length
        let visible = visible.map { NSIntersectionRange($0, NSRange(location: 0, length: length)) }
            ?? NSRange(location: 0, length: min(length, Self.margin))
        let margin = max(Self.margin, visible.length / 2)
        let start = max(0, visible.location - margin), end = min(length, NSMaxRange(visible) + margin)
        let window = text.paragraphRange(for: NSRange(location: start, length: end - start))
        let wanted = SpellCheckRanges.merged([window] + edited.map {
            NSIntersectionRange($0, NSRange(location: 0, length: length))
        })
        edited = []
        return Self.subtract(checked, from: wanted, keepingParagraphsOf: text)
    }

    // MARK: - Checking

    /// After the jobs before it, checks the paragraphs `ranges` gives when
    /// the job starts (in the text of that moment); returns the job.
    @discardableResult
    private func enqueue(_ ranges: @escaping (SpellCheckModel) -> [NSRange]) -> Task<Void, Never> {
        let previous = lastJob
        jobsRunning += 1
        let job = Task { [weak self] in
            await previous?.value
            await self?.run(ranges)
            guard let self else {
                return
            }
            jobsRunning -= 1
            if jobsRunning == 0, arrived.isEmpty {
                log = []
            }
            resumeWaitersIfIdle()
        }
        lastJob = job
        return job
    }

    private func run(_ wanted: (SpellCheckModel) -> [NSRange]) async {
        let generation = generation
        guard isEnabled, file != nil, let documentTag else {
            return
        }
        var start = ContinuousClock.now
        let ranges = wanted(self).compactMap { range -> NSRange? in
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
            return clipped.length > 0 ? text.paragraphRange(for: clipped) : nil
        }
        guard !ranges.isEmpty else {
            return
        }
        // The actor's text after these edits is today's text, at `revision`.
        let revision = revision
        let reopen = reopen, edits = unsent
        self.reopen = nil
        unsent = []
        mainThreadTime += start.duration(to: .now)
        let (paragraphs, reparsed) = await source.paragraphs(reopen: reopen, edits: edits, ranges: ranges)
        guard generation == self.generation else {
            return
        }
        if !reparsed.isEmpty {
            // First, so this job's own results, read from the new tree, stand.
            arrived.append(SpellResult(paragraph: NSRange(), misspellings: [], revision: revision, reparsed: reparsed))
        }
        start = ContinuousClock.now
        var results: [SpellResult] = []
        var misses: [SpellParagraph] = []
        for paragraph in paragraphs {
            if paragraph.checkable.isEmpty {
                results.append(SpellResult(paragraph: paragraph.range, misspellings: [], revision: revision))
            } else if let cached = cache[paragraph.key] {
                cacheHits += 1
                results.append(SpellResult(paragraph: paragraph.range, misspellings: cached, revision: revision))
            } else {
                misses.append(paragraph)
            }
        }
        if !misses.isEmpty {
            // One request for the batch: the paragraphs' texts in order, with
            // their checkable ranges moved by their place in the batch.
            var batch = "", checkable: [NSRange] = [], offsets: [Int] = []
            var offset = 0
            for paragraph in misses {
                offsets.append(offset)
                batch += paragraph.text
                checkable += paragraph.checkable.map { NSRange(location: $0.location + offset, length: $0.length) }
                offset += (paragraph.text as NSString).length
            }
            mainThreadTime += start.duration(to: .now)
            requests += 1
            paragraphsChecked += misses.count
            let reported = await checker.misspellings(in: batch, ranges: checkable, document: documentTag)
            guard generation == self.generation else {
                return
            }
            // Built-in words are never reported, from any checker.
            let words = batch as NSString
            let found = reported.filter { range in
                NSMaxRange(range) > words.length || !SpellCheckRanges.isBuiltIn(words.substring(with: range))
            }
            start = ContinuousClock.now
            var cursor = 0
            for (index, paragraph) in misses.enumerated() {
                let lower = offsets[index], upper = lower + (paragraph.text as NSString).length
                var own: [NSRange] = []
                while cursor < found.count, found[cursor].location < upper {
                    if found[cursor].location >= lower, NSMaxRange(found[cursor]) <= upper {
                        own.append(NSRange(location: found[cursor].location - lower, length: found[cursor].length))
                    }
                    cursor += 1
                }
                if cache.count >= Self.cacheLimit {
                    cache = [:]
                }
                cache[paragraph.key] = own
                results.append(SpellResult(paragraph: paragraph.range, misspellings: own, revision: revision))
            }
        }
        arrived += results
        applyArrived()
        mainThreadTime += start.duration(to: .now)
    }

    /// Applies results that arrived, moved across the edits made since they
    /// were asked for, unless text is marked.
    private func applyArrived() {
        guard !arrived.isEmpty, !hasMarkedText() else {
            return
        }
        let results = arrived
        arrived = []
        var changed: [NSRange] = []
        var rescan = false
        let caret = hidingCaret
        let shown = { (range: NSRange) in
            caret.map { range.location > $0 || NSMaxRange(range) < $0 } ?? true
        }
        for result in results {
            if !result.reparsed.isEmpty {
                let stale = result.reparsed.map { text.paragraphRange(for: moved($0, from: result.revision)) }
                let before = checked
                checked = Self.subtract(SpellCheckRanges.merged(stale), from: checked)
                if checked != before {
                    rescan = true
                }
                continue
            }
            guard let paragraph = rebased(result.paragraph, from: result.revision) else {
                // A later edit changed the paragraph: check it again.
                edited = SpellCheckRanges.merged(edited + [moved(result.paragraph, from: result.revision)])
                continue
            }
            let found = result.misspellings.map {
                NSRange(location: $0.location + paragraph.location, length: $0.length)
            }
            let low = firstMisspelling(endingAfter: paragraph.location)
            var high = low
            while high < misspellings.count, misspellings[high].location < NSMaxRange(paragraph) {
                high += 1
            }
            let old = Array(misspellings[low ..< high])
            if old != found {
                misspellings.replaceSubrange(low ..< high, with: found)
                let removed = old.filter { !found.contains($0) && shown($0) }
                let added = found.filter { !old.contains($0) && shown($0) }
                changed += removed + added
            }
            checked = SpellCheckRanges.merged(checked + [paragraph])
        }
        if jobsRunning == 0 {
            log = []
        }
        if !edited.isEmpty || rescan, pauseTask == nil {
            scheduleViewport()
        }
        report(changed)
    }

    /// `range` of the text at `revision`, in today's text; nil when an edit
    /// since then touched it.
    private func rebased(_ range: NSRange, from revision: Int) -> NSRange? {
        var range = range
        for entry in log where entry.revision > revision {
            if entry.range.location <= NSMaxRange(range), NSMaxRange(entry.range) >= range.location {
                return nil
            }
            range = SourceStyling.rebase(range, editing: entry.range, delta: entry.delta)
        }
        return range
    }

    /// `range` of the text at `revision`, in today's text, edits included.
    private func moved(_ range: NSRange, from revision: Int) -> NSRange {
        var range = range
        for entry in log where entry.revision > revision {
            range = SourceStyling.rebase(range, editing: entry.range, delta: entry.delta)
        }
        return NSIntersectionRange(range, NSRange(location: 0, length: text.length))
    }

    private func report(_ ranges: [NSRange]) {
        let merged = SpellCheckRanges.merged(ranges.map {
            NSIntersectionRange($0, NSRange(location: 0, length: text.length))
        }.filter { $0.length > 0 })
        if !merged.isEmpty {
            onChange?(merged)
        }
    }

    // MARK: - Range arithmetic

    /// A misspelling after a native replacement of `edit` (old coordinates)
    /// that changed the length by `delta`, in the new text `text`; nil when
    /// the edit changed the word: it overlaps it, or touches it and leaves a
    /// letter or digit against it.
    static func rebase(_ word: NSRange, editing edit: NSRange, delta: Int, in text: NSString) -> NSRange? {
        if edit.location < NSMaxRange(word), NSMaxRange(edit) > word.location {
            return nil
        }
        if edit.length == 0, edit.location > word.location, edit.location < NSMaxRange(word) {
            return nil
        }
        if NSMaxRange(edit) <= word.location {
            let moved = NSRange(location: word.location + delta, length: word.length)
            if NSMaxRange(edit) == word.location, isWord(text, moved.location - 1) {
                return nil
            }
            return moved
        }
        if edit.location == NSMaxRange(word), isWord(text, NSMaxRange(word)) {
            return nil
        }
        return word
    }

    private static func isWord(_ text: NSString, _ offset: Int) -> Bool {
        guard offset >= 0, offset < text.length else {
            return false
        }
        let unit = text.character(at: offset)
        return Unicode.Scalar(unit).map { CharacterSet.alphanumerics.contains($0) || $0 == "'" } ?? true
    }

    /// `ranges` without the parts in `cut`. Both sorted and merged.
    static func subtract(_ cut: NSRange, from ranges: [NSRange]) -> [NSRange] {
        subtract([cut], from: ranges)
    }

    static func subtract(_ cut: [NSRange], from ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges {
            var pieces = [range]
            for hole in cut where hole.length > 0 {
                pieces = pieces.flatMap { piece -> [NSRange] in
                    let overlap = NSIntersectionRange(piece, hole)
                    guard overlap.length > 0 else {
                        return [piece]
                    }
                    return [
                        NSRange(location: piece.location, length: overlap.location - piece.location),
                        NSRange(location: NSMaxRange(overlap), length: NSMaxRange(piece) - NSMaxRange(overlap)),
                    ].filter { $0.length > 0 }
                }
            }
            result += pieces
        }
        return SpellCheckRanges.merged(result)
    }

    /// The paragraphs of `ranges` that `cut` does not wholly cover.
    static func subtract(_ cut: [NSRange], from ranges: [NSRange], keepingParagraphsOf text: NSString) -> [NSRange] {
        subtract(cut, from: ranges).map { text.paragraphRange(for: $0) }.reduce(into: []) { result, range in
            result = SpellCheckRanges.merged(result + [range])
        }
    }
}

/// A paragraph's text and its checkable ranges, relative to the paragraph.
struct SpellParagraph: Sendable {
    let range: NSRange
    let text: String
    let checkable: [NSRange]

    var key: SpellParagraphKey {
        SpellParagraphKey(text: text, checkable: checkable)
    }
}

/// What a paragraph's result depends on.
struct SpellParagraphKey: Hashable {
    let text: String
    let checkable: [NSRange]
}

/// A paragraph's misspellings, relative to the paragraph, for the text at `revision`.
struct SpellResult {
    let paragraph: NSRange
    let misspellings: [NSRange]
    let revision: Int
    /// When not empty, this is no result: these ranges were reparsed, and
    /// the paragraphs they reach are no longer known to be checked.
    var reparsed: [NSRange] = []
}

/// The text and syntax tree spell check reads, off the main thread. Edits
/// arrive in order with each request.
actor SpellCheckSource {
    private let text = NSMutableString()
    private var tree: SyntaxTree?

    /// Starts from `reopen` when given, applies `edits` in order, and returns
    /// the paragraphs of `ranges` (whole paragraphs of the text after them)
    /// and what typst-syntax reparsed for the edits, in the same text. A
    /// reparse can reach past the edited paragraph (an unclosed `$`, a raw
    /// fence, a comment), and the paragraphs it reaches may read differently.
    func paragraphs(
        reopen: String?,
        edits: [TextReplacement],
        ranges: [NSRange],
    ) -> (paragraphs: [SpellParagraph], reparsed: [NSRange]) {
        if let reopen {
            text.setString(reopen)
            tree = SyntaxTree(reopen)
        }
        var reparsed: [NSRange] = []
        for edit in edits {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= text.length else {
                tree = nil
                continue
            }
            text.replaceCharacters(in: edit.range, with: edit.text)
            let delta = (edit.text as NSString).length - edit.range.length
            reparsed = reparsed.map { SourceStyling.rebase($0, editing: edit.range, delta: delta) }
            if let changed = tree?.edit(edit.range, replacement: edit.text) {
                reparsed.append(changed)
            } else {
                tree = nil
            }
        }
        if tree == nil {
            tree = SyntaxTree(text as String)
            if reopen == nil {
                reparsed = [NSRange(location: 0, length: text.length)]
            }
        }
        guard let tree else {
            return ([], [])
        }
        var paragraphs: [SpellParagraph] = []
        for range in ranges {
            let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
            guard range.length > 0 else {
                continue
            }
            // Paragraph ends are line breaks, so no word is cut at them.
            let all = SpellCheckRanges.ranges(tree, source: text, within: range)
            var next = 0
            var location = range.location
            while location < NSMaxRange(range) {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                while next < all.count, NSMaxRange(all[next]) <= paragraph.location {
                    next += 1
                }
                var checkable: [NSRange] = []
                var index = next
                while index < all.count, all[index].location < NSMaxRange(paragraph) {
                    let clipped = NSIntersectionRange(all[index], paragraph)
                    if clipped.length > 0 {
                        checkable.append(NSRange(
                            location: clipped.location - paragraph.location,
                            length: clipped.length,
                        ))
                    }
                    index += 1
                }
                paragraphs.append(SpellParagraph(
                    range: paragraph,
                    text: text.substring(with: paragraph),
                    checkable: checkable,
                ))
                location = max(NSMaxRange(paragraph), location + 1)
            }
        }
        return (paragraphs, reparsed)
    }
}
