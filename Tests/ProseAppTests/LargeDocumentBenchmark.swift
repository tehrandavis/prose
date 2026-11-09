import AppKit
import Darwin
import PDFKit
@testable import ProseApp
import ProseCore
import Testing

extension WritingFlowTests {
    /// Opt-in: fetch the real fixture with scripts/prepare-large-document.py.
    /// This drives the production text view, native layout and real Tinymist.
    /// With `PROSE_WRITING_MODE=1` the same run happens in Writing mode
    /// (acceptance test 14 of the Phase 3 note): every jump, and the typing,
    /// lands in a block that is rendered when it starts, so each one swaps.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_LARGE_FIXTURE"] != nil))
    func realMultiMegabyteDocumentNavigationScrollingAndTyping() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PROSE_LARGE_FIXTURE"])
        let writingMode = ProcessInfo.processInfo.environment["PROSE_WRITING_MODE"] == "1"
        let restoreDefault = writingMode ? writingModeDefault(true) : {}
        defer { restoreDefault() }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try #require(String(data: data, encoding: .utf8))
        #expect(data.count > 1_000_000)
        let initialMemory = physicalFootprint()
        // On macOS 15 every edit walks each text element TextKit has built
        // after it; a step that builds the whole book makes typing slow.
        let builtBefore = SourceStyler.paragraphsBuilt
        var built: [String: Int] = [:]
        func record(_ phase: String) {
            built[phase] = SourceStyler.paragraphsBuilt - builtBefore
        }
        let opened = ContinuousClock.now
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let openTime = seconds(opened.duration(to: .now))
        for name in ["fig", "styles"] {
            let dependency = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dependency.path) {
                try FileManager.default.copyItem(at: dependency, to: app.root.appendingPathComponent(name))
            }
        }
        print("PROSE LARGE open: \(openTime)s, \(data.count) bytes")
        let editor = try #require(app.workspace.editor)
        let scroll = try #require(editor.enclosingScrollView)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))
        let textSystem = editor.textLayoutManager == nil ? "textkit1" : "textkit2"
        var report: [String: Any] = ["bytes": data.count, "utf16": source.utf16.count, "open_seconds": openTime,
                                     "text_system": textSystem, "memory_before_mib": initialMemory,
                                     "memory_open_mib": physicalFootprint(),
                                     "editor_mode": writingMode ? "writing" : "code"]
        record("open")
        let serviceStarted = ContinuousClock.now
        app.workspace.startService()
        let deadline = ContinuousClock.now + .seconds(120)
        while app.workspace.syntaxSnapshot?.source != source, deadline > .now {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(app.workspace.syntaxSnapshot?.source == source, "Real semantic highlighting must finish")
        report["semantic_ready_seconds"] = seconds(serviceStarted.duration(to: .now))
        report["syntax_tokens"] = app.workspace.syntaxSnapshot?.tokens.count ?? 0
        report["memory_highlighted_mib"] = physicalFootprint()
        let codeWord = ProcessInfo.processInfo.environment["PROSE_CODE_WORD"] ?? "sum(range"
        let sum = (source as NSString).range(of: codeWord)
        #expect(sum.location != NSNotFound)
        if sum.location != NSNotFound {
            #expect(editorColor(editor, at: sum.location) == Theme.sourceFunction)
        }
        // Publishing semantic tokens precedes SwiftUI's next native layout.
        // Finish and report that initial presentation before timing navigation,
        // just as we settle the window between every subsequent jump below.
        record("highlighted")
        let presentationStart = ContinuousClock.now
        await app.layout()
        editor.prepareForPointerInteraction()
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        report["initial_presentation_ms"] = seconds(presentationStart.duration(to: .now)) * 1000
        report["editor_ready_seconds"] = seconds(opened.duration(to: .now))
        // Opening starts Tinymist's one-time first compile and preview of the
        // whole book, which keeps several of its threads busy for a few
        // seconds. In the app the editor's main thread runs at foreground
        // priority, above Tinymist; this command-line test process runs it at
        // the same priority as Tinymist, so on CI's three cores that compile
        // preempted whichever jump overlapped it (200 ms wall for 40 ms of
        // work). Time navigation once the engine is idle.
        let settleStart = ContinuousClock.now
        try await engineSettled(state: app.workspace.stateDirectory)
        report["engine_settle_seconds"] = seconds(settleStart.duration(to: .now))
        let ns = source as NSString
        var offsets = [0.1, 0.9, 0.5, 0.99, 0.01, 0.75].map { fraction in
            let start = Int(Double(ns.length) * fraction)
            let range = ns.paragraphRange(for: NSRange(location: start, length: 0))
            return min(ns.length - 1, range.location + min(4, max(0, range.length - 2)))
        }
        var writing: WritingBenchmark?
        if writingMode {
            writing = try await WritingBenchmark.enter(app, report: &report)
            record("writing")
            offsets = await writing?.renderTargets(offsets, report: &report) ?? offsets
            record("targets")
        }
        var navigation: [Double] = [], hitTesting: [Double] = [], search: [Double] = []
        var jumpTimes: [Double] = [], highlightTimes: [Double] = [], layoutTimes: [Double] = []
        var navigationSamples: [[String: Double]] = []
        var jumpsOnTarget = 0, maximumHitError = 0
        var navigationCPU: [Double] = []
        for offset in offsets {
            writing?.expectRendered(at: offset, "Jump target")
            let swapsBefore = editor.writing.swapCount
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = ContinuousClock.now
            app.workspace.jump(to: offset)
            jumpTimes.append(seconds(start.duration(to: .now)))
            let highlightStart = ContinuousClock.now
            editor.highlight()
            highlightTimes.append(seconds(highlightStart.duration(to: .now)))
            let layoutStart = ContinuousClock.now
            editor.prepareForPointerInteraction()
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            layoutTimes.append(seconds(layoutStart.duration(to: .now)))
            navigation.append(seconds(start.duration(to: .now)))
            navigationCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9)
            try navigationSamples.append(["offset": Double(offset), "total_ms": #require(navigation.last) * 1000,
                                          "jump_ms": #require(jumpTimes.last) * 1000,
                                          "highlight_ms": #require(highlightTimes.last) * 1000,
                                          "draw_ms": #require(layoutTimes.last) * 1000,
                                          "thread_cpu_ms": #require(navigationCPU.last) * 1000])
            #expect(editor.selectedRange().location == offset)
            if let writing {
                // The jump opened the rendered block it landed in.
                navigationSamples[navigationSamples.count - 1]["swaps"] = Double(editor.writing.swapCount - swapsBefore)
                #expect(editor.writing.swapCount > swapsBefore, "The jump to \(offset) swapped no block")
                #expect(writing.isSource(offset), "The jump to \(offset) left its block rendered")
                writing.recordDraws()
            }
            await app.layout()
            let hitStart = ContinuousClock.now
            // Independently map a rendered glyph back to an insertion point,
            // and check the jump really brought it into the viewport.
            let glyph = try #require(editor.characterRect(at: offset))
            let point = NSPoint(x: glyph.minX + 1, y: glyph.midY)
            let hit = editor.characterIndexForInsertion(at: point)
            let visible = editor.visibleRect.contains(point)
            jumpsOnTarget += visible ? 1 : 0
            maximumHitError = max(maximumHitError, abs(hit - offset))
            #expect(visible, "Jump to \(offset) left \(glyph) outside \(editor.visibleRect)")
            #expect(hit == offset, "Hit \(hit), wanted \(offset), point \(point)")
            navigationSamples[navigationSamples.count - 1]["hit_error"] = Double(hit - offset)
            hitTesting.append(seconds(hitStart.duration(to: .now)))
            let searchStart = ContinuousClock.now
            let found = ns.range(
                of: ProcessInfo.processInfo.environment["PROSE_SEARCH_WORD"] ?? "Prince Andrew",
                options: [],
                range: NSRange(location: offset, length: ns.length - offset),
            )
            _ = found.location
            search.append(seconds(searchStart.duration(to: .now)))
        }
        record("jumped")
        writing?.phaseEnded("jumps")
        report["jumps_on_target"] = jumpsOnTarget
        report["max_hit_error"] = maximumHitError
        report["navigation_ms"] = milliseconds(navigation)
        report["navigation_samples"] = navigationSamples
        report["jump_ms"] = milliseconds(jumpTimes)
        report["highlight_ms"] = milliseconds(highlightTimes)
        report["layout_ms"] = milliseconds(layoutTimes)
        report["hit_testing_ms"] = milliseconds(hitTesting)
        report["search_ms"] = milliseconds(search)
        var scrolling: [Double] = [], drawing: [Double] = []
        // Scrolling three screens down and back must show every line where it
        // was. TextKit 2 replaces estimated heights above the viewport while
        // scrolling and moves the clip origin with them, so compare positions
        // within the viewport; the document-coordinate shift is reported.
        let scrollStart = scroll.contentView.bounds.origin
        if let writing {
            // The viewport the jumps left has its renders before scrolling.
            await writing.settle()
        }
        // In Writing mode the first visible line can be a rendered block, which
        // has no source line rectangle; follow its fragment's top instead.
        let writingAnchor = try writing.map { _ in
            try #require(editor.writingAnchor(changing: []), "No line at the top of the viewport")
        }
        let anchor = try #require(editor.visibleCharacterRange()).location
        let anchorRect = try writing == nil ? #require(editor.characterRect(at: anchor)) : .zero
        let anchorInViewport = anchorRect.minY - editor.visibleRect.minY
        var renderWaits: [Double] = [], renderWaitCPU: [Double] = []
        for index in 0 ..< 60 {
            let start = ContinuousClock.now
            let y = max(0, scroll.contentView.bounds.origin.y + (index < 30 ? 80 : -80))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.prepareForPointerInteraction()
            #expect((editor.visibleCharacterRange()?.length ?? 0) > 0)
            scrolling.append(seconds(start.duration(to: .now)))
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
            drawing.append(seconds(start.duration(to: .now)))
            if let writing {
                // Untimed: the renders the new viewport asks for arrive and
                // swap, keeping the top line, as they would between frames.
                writing.recordDraws()
                let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let waitStart = ContinuousClock.now
                await writing.settle(layout: false)
                renderWaits.append(seconds(waitStart.duration(to: .now)))
                renderWaitCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9)
            }
        }
        let drift: CGFloat
        if let writingAnchor, let writing {
            let top = try #require(writing.fragmentTop(writingAnchor.offset))
            drift = top - editor.containerVisibleRect().minY - writingAnchor.y
            report["scroll_anchor_offset"] = writingAnchor.offset
            report["scroll_render_wait_ms"] = milliseconds(renderWaits)
            report["scroll_render_wait_thread_cpu_ms"] = milliseconds(renderWaitCPU)
        } else {
            let finalRect = try #require(editor.characterRect(at: anchor))
            drift = finalRect.minY - editor.visibleRect.minY - anchorInViewport
            report["scroll_reestimated_pt"] = finalRect.minY - anchorRect.minY
        }
        report["scroll_drift_pt"] = drift
        report["scroll_origin_shift_pt"] = scroll.contentView.bounds.origin.y - scrollStart.y
        #expect(abs(drift) < 0.5, "A line moved by \(drift) pt in the viewport after scrolling away and back")
        report["scroll_layout_ms"] = milliseconds(scrolling)
        report["scroll_draw_ms"] = milliseconds(drawing)
        record("scrolled")
        writing?.phaseEnded("scroll")
        writing?.expectRendered(at: offsets[2], "Typing target")
        app.workspace.jump(to: offsets[2])
        editor.highlight()
        if let writing {
            #expect(writing.isSource(offsets[2]), "The caret's block did not open for typing")
            // Type with the viewport around the caret rendered.
            await writing.settle()
            writing.phaseEnded("typing_jump")
        }
        let typingStart = UsageSnapshot()
        var typing: [Double] = [], typingCPU: [Double] = [], insertTimes: [Double] = [], metricTimes: [Double] = []
        var typingSamples: [[String: Any]] = []
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        // Retain the first keystroke: no warm-up samples are discarded. Eighty
        // inputs give p95 a meaningful tail instead of equating it with max.
        for character in String(repeating: "Smooth 中文😀 input", count: 5) {
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let start = ContinuousClock.now
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            insertTimes.append(seconds(start.duration(to: .now)))
            let metricsStart = ContinuousClock.now
            _ = app.workspace.position
            _ = app.workspace.wordCount
            metricTimes.append(seconds(metricsStart.duration(to: .now)))
            typing.append(seconds(start.duration(to: .now)))
            typingCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e9)
            try typingSamples.append([
                "index": typing.count - 1,
                "character": String(character),
                "wall_ms": #require(typing.last) * 1000,
                "thread_cpu_ms": #require(typingCPU.last) * 1000,
                "insert_ms": #require(insertTimes.last) * 1000,
                "metrics_ms": #require(metricTimes.last) * 1000,
            ])
            try await Task.sleep(for: .milliseconds(25))
        }
        record("typed")
        report["typing_phase"] = typingStart.usage(to: UsageSnapshot())
        writing?.phaseEnded("typing")
        report["paragraphs_built"] = built
        editor.undoManager?.endUndoGrouping()
        report["typing_ms"] = milliseconds(typing)
        report["typing_samples"] = typingSamples
        report["typing_thread_cpu_ms"] = milliseconds(typingCPU)
        let budgetFailures = typingBudgetFailures(wall: typing, cpu: typingCPU)
        report["typing_budget_failures"] = budgetFailures
        #expect(budgetFailures.isEmpty, "\(budgetFailures.joined(separator: "; "))")
        #expect(try #require(navigation.max()) < 0.2, "Distant navigation including drawing must stay below 200 ms")
        #expect(built["typed", default: 0] < 5000, "TextKit built \(built) paragraphs; a step builds the whole book")
        report["insert_ms"] = milliseconds(insertTimes)
        report["metrics_ms"] = milliseconds(metricTimes)
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        // Both engines catch up with the edits: Tinymist compiles for the
        // preview, and in Writing mode the block engine takes the new text,
        // renders the caret's block and runs its full compile (refresh) after
        // the 1.5 s pause. Both modes measure at least the same 4 s window.
        let afterTyping = UsageSnapshot()
        try await Task.sleep(until: afterTyping.time + .seconds(4), clock: .continuous)
        await writing?.model.idle()
        try await childrenIdle()
        report["after_typing"] = afterTyping.usage(to: UsageSnapshot())
        report["memory_after_mib"] = physicalFootprint()
        report["preview_status"] = app.workspace.serviceStatus
        if ProcessInfo.processInfo.environment["PROSE_BENCH_EXPORT"] == "1" {
            let started = ContinuousClock.now
            let pdfURL = app.root.appendingPathComponent("complete-book.pdf")
            try await app.workspace.exportPDF(to: pdfURL)
            report["export_seconds"] = seconds(started.duration(to: .now))
            let pdf = try #require(PDFDocument(url: pdfURL))
            report["export_pages"] = pdf.pageCount
            #expect(pdf.pageCount > 400)
        }
        // From engine start to Tinymist's first successful compile ("Checking…" in the
        // app). Read from the operation log so measuring it does not change the run.
        report["first_compile_seconds"] = firstCompileSeconds(in: app.workspace.stateDirectory) ?? NSNull()
        report["memory_peak_mib"] = peakFootprint()
        report["children_peak_mib"] = childrenPeakFootprint()
        if let writing {
            writing.finish(report: &report)
            expectPlainStorage(editor)
        }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = ProcessInfo.processInfo.environment["PROSE_PERFORMANCE_REPORT"] {
            try json.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("PROSE LARGE REPORT\n" + String(decoding: json, as: UTF8.self))
    }
}

/// Writing mode in the book benchmark: enters it, renders the blocks the
/// jumps and the typing land in, and counts swaps and rendered draws.
@MainActor
private final class WritingBenchmark {
    let app: WritingFixture
    let editor: ManuscriptTextView
    let manager: NSTextLayoutManager
    let model: WritingLayout
    private var swapsAtPhase: Int
    private var swaps: [String: Int] = [:]
    /// The most rendered draws seen for each fragment with an image in view.
    private var renderedDraws: [ObjectIdentifier: Int] = [:]

    private init(app: WritingFixture, editor: ManuscriptTextView, manager: NSTextLayoutManager, model: WritingLayout) {
        self.app = app
        self.editor = editor
        self.manager = manager
        self.model = model
        swapsAtPhase = editor.writing.swapCount
    }

    /// Switches the open book to Writing mode and waits for the engine, the
    /// viewport's renders and the first full compile.
    static func enter(_ app: WritingFixture, report: inout [String: Any]) async throws -> WritingBenchmark {
        let editor = try #require(app.workspace.editor)
        let manager = try #require(editor.textLayoutManager)
        #expect(WritingController.isEnabled)
        report["memory_before_writing_mib"] = physicalFootprint()
        report["memory_peak_before_writing_mib"] = peakFootprint()
        let usage = UsageSnapshot()
        let model = try await enterWritingMode(app)
        report["writing_entry"] = usage.usage(to: UsageSnapshot())
        report["writing_entered_with_renders"] = editor.writing.enteredWithRenders ?? NSNull()
        report["memory_writing_entered_mib"] = physicalFootprint()
        report["memory_peak_writing_entry_mib"] = peakFootprint()
        #expect(app.workspace.editorMode == .writing && editor.writing.isRunning)
        #expect(model.lastError == nil, "The engine refused the book: \(model.lastError ?? "")")
        let benchmark = WritingBenchmark(app: app, editor: editor, manager: manager, model: model)
        benchmark.phaseEnded("entry")
        return benchmark
    }

    /// Scrolls to each target without moving the caret, so its block renders,
    /// then back. A target in a block that never renders (a raw block, one of
    /// more than 400 lines, a pill) moves to the first line of the nearest
    /// block that does. Returns the targets.
    func renderTargets(_ offsets: [Int], report: inout [String: Any]) async -> [Int] {
        let anchor = editor.writingAnchor(changing: [])
        var targets: [Int] = [], samples: [[String: Any]] = []
        for offset in offsets {
            editor.reveal(NSRange(location: offset, length: 0))
            await settle()
            var target = offset
            if !isRendered(offset) {
                for candidate in renderableTargets(near: offset).prefix(5) {
                    editor.reveal(NSRange(location: candidate, length: 0))
                    await settle()
                    if isRendered(candidate) {
                        target = candidate
                        break
                    }
                }
            }
            #expect(isRendered(target), "No rendered block near \(offset)")
            targets.append(target)
            samples.append(["offset": offset, "target": target, "moved": target != offset,
                            "paragraphs_built": SourceStyler.paragraphsBuilt])
        }
        // Back to the line that was at the top, as the Code mode run starts.
        // Heights changed where blocks rendered, so the old scroll position
        // now shows other text; scrolling the clip view straight to it laid
        // out about 4,950 paragraphs of SICP's index while TextKit replaced
        // estimated heights.
        editor.restoreWritingAnchor(anchor)
        await settle()
        report["writing_targets"] = samples
        report["writing_start_offset"] = anchor?.offset ?? 0
        report["writing_start_visible"] = editor.visibleCharacterRange()?.location ?? -1
        phaseEnded("targets")
        return targets
    }

    /// Places on the first lines of the blocks nearest to `offset` that render
    /// or wait for a render, nearest first.
    private func renderableTargets(near offset: Int) -> [Int] {
        let text = editor.string as NSString
        var candidates: [(distance: Int, offset: Int)] = []
        for (index, block) in model.blocks.enumerated() {
            switch model.state(ofBlockAt: index) {
            case .rendered, .source(.waiting):
                let line = text.paragraphRange(for: NSRange(location: block.range.location, length: 0))
                let candidate = block.range.location + min(4, max(0, line.length - 2))
                candidates.append((abs(candidate - offset), candidate))
            default:
                continue
            }
        }
        return candidates.sorted { $0.distance < $1.distance }.map(\.offset)
    }

    /// Whether the block that holds `offset` draws rendered.
    func isRendered(_ offset: Int) -> Bool {
        guard let block = model.blockRange(holding: offset) else {
            return false
        }
        let text = editor.string as NSString
        let first = text.paragraphRange(for: NSRange(location: block.location, length: 0))
        if case .rendered = model.role(forParagraph: first) {
            return true
        }
        return false
    }

    /// Whether the paragraph of `offset` draws source.
    func isSource(_ offset: Int) -> Bool {
        let text = editor.string as NSString
        return model.role(forParagraph: text.paragraphRange(for: NSRange(location: offset, length: 0))) == .source
    }

    func expectRendered(at offset: Int, _ what: String) {
        #expect(isRendered(offset), "\(what) \(offset) is not in a rendered block when the action starts")
    }

    /// Lets the viewport's renders arrive and swap in.
    func settle(layout: Bool = true) async {
        if layout {
            await app.layout()
        } else {
            await Task.yield()
        }
        editor.writing.viewportDidChange()
        await model.idle()
        editor.prepareForPointerInteraction()
    }

    /// Notes the rendered fragments with an image in view and how often each
    /// has drawn so far.
    func recordDraws() {
        guard let viewport = manager.textViewportLayoutController.viewportRange else {
            return
        }
        manager.enumerateTextLayoutFragments(from: viewport.location) { fragment in
            if let fragment = fragment as? WritingFragment, case let .rendered(rendering, _) = fragment.role,
               rendering.image != nil
            {
                let id = ObjectIdentifier(fragment)
                renderedDraws[id] = max(renderedDraws[id] ?? 0, fragment.draws["rendered", default: 0])
            }
            return fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending
        }
    }

    /// The top of the fragment of the paragraph that starts at `offset`.
    func fragmentTop(_ offset: Int) -> CGFloat? {
        TextKit2Geometry.location(offset, in: manager)
            .flatMap { manager.textLayoutFragment(for: $0)?.layoutFragmentFrame.minY }
    }

    /// Swaps since the last phase ended.
    func phaseEnded(_ name: String) {
        swaps[name] = editor.writing.swapCount - swapsAtPhase
        swapsAtPhase = editor.writing.swapCount
    }

    /// Checks that the run measured Writing mode and reports what it did.
    func finish(report: inout [String: Any]) {
        let drawn = renderedDraws.values.filter { $0 > 0 }
        let draws = drawn.reduce(0, +)
        #expect(app.workspace.editorMode == .writing && editor.writing.isRunning, "The run left Writing mode")
        #expect(
            swaps["jumps", default: 0] >= 6 && swaps["scroll", default: 0] > 0 && swaps["typing_jump", default: 0] > 0,
            "Swaps by phase: \(swaps)",
        )
        #expect(draws > 0, "No rendered fragment drew during the run")
        report["writing"] = [
            "blocks": model.blocks.count,
            "swaps": swaps,
            "swaps_total": editor.writing.swapCount,
            "rendered_fragments_drawn": drawn.count,
            "rendered_fragment_draws": draws,
            "bitmap_mib": Double(model.bytesHeld) / 1_048_576,
            "sync_replies": model.syncReplies,
            "render_replies": model.renderReplies,
            "stale": model.stale,
            "last_error": model.lastError ?? NSNull(),
        ]
        print("PROSE WRITING swaps \(swaps), rendered draws \(draws) by \(drawn.count) fragments")
    }
}

/// Waits for Tinymist's first compile, then until its processes (this
/// process's children) use under a tenth of a core.
private func engineSettled(state: URL) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while firstCompileSeconds(in: state) == nil, deadline > .now {
        try await Task.sleep(for: .milliseconds(100))
    }
    try await childrenIdle(until: deadline)
}

/// Waits until this process's children (Tinymist) use under a tenth of a core.
private func childrenIdle(until deadline: ContinuousClock.Instant = .now + .seconds(60)) async throws {
    var previous = childrenCPUSeconds()
    while deadline > .now {
        try await Task.sleep(for: .milliseconds(200))
        let current = childrenCPUSeconds()
        if current - previous < 0.02 {
            return
        }
        previous = current
    }
}

private func childrenCPUSeconds() -> Double {
    var pids = [pid_t](repeating: 0, count: 64)
    let count = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    var ticks: UInt64 = 0
    for pid in pids.prefix(max(0, count)) where pid > 0 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        if result == 0 {
            ticks += info.ri_user_time + info.ri_system_time
        }
    }
    return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

private func firstCompileSeconds(in state: URL) -> Double? {
    let log = (try? String(contentsOf: state.appendingPathComponent("Logs/events.jsonl"), encoding: .utf8)) ?? ""
    for line in log.split(separator: "\n") where line.contains("service.firstCompile") {
        if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let fields = entry["fields"] as? [String: String],
           let milliseconds = fields["milliseconds"].flatMap(Double.init)
        {
            return milliseconds / 1000
        }
    }
    return nil
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func milliseconds(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    guard let maximum = sorted.last else {
        return [:]
    }
    return ["median": sorted[sorted.count / 2] * 1000, "p95": p95(sorted) * 1000, "max": maximum * 1000]
}

private func p95(_ sorted: [Double]) -> Double {
    sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

private func typingBudgetFailures(wall: [Double], cpu: [Double]) -> [String] {
    guard wall.count >= 80, cpu.count == wall.count else {
        return ["Expected at least 80 paired typing samples"]
    }
    var failures: [String] = []
    if p95(wall.sorted()) >= 0.1 {
        failures.append("Typing wall-time p95 must stay below 100 ms")
    }
    if wall.contains(where: { $0 >= 0.25 }) {
        failures.append("Every input must finish within 250 ms wall time")
    }
    if cpu.contains(where: { $0 >= 0.1 }) {
        failures.append("Every input must stay below 100 ms of main-thread CPU work")
    }
    return failures
}

@Test func bookTypingBudgetDistinguishesSchedulingNoiseFromSustainedSlowInput() {
    let fast = Array(repeating: 0.012, count: 80)
    // A lone scheduling delay is visible in the report without hiding slow
    // editor work, a sustained latency regression, or a severe individual stall.
    #expect(typingBudgetFailures(wall: [0.1025] + fast.dropFirst(), cpu: fast).isEmpty)
    #expect(!typingBudgetFailures(wall: [0.1025] + fast.dropFirst(), cpu: [0.101] + fast.dropFirst()).isEmpty)
    #expect(!typingBudgetFailures(wall: Array(repeating: 0.11, count: 5) + fast.dropFirst(5), cpu: fast).isEmpty)
    #expect(!typingBudgetFailures(wall: [0.3] + fast.dropFirst(), cpu: fast).isEmpty)
    #expect(!typingBudgetFailures(wall: Array(fast.prefix(16)), cpu: Array(fast.prefix(16))).isEmpty)
}

private func physicalFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// The largest physical footprint this process has had, in MiB.
private func peakFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
}

/// The sum of the largest physical footprints of this process's live
/// children (Tinymist), in MiB.
private func childrenPeakFootprint() -> Double {
    var pids = [pid_t](repeating: 0, count: 64)
    let count = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var bytes: UInt64 = 0
    for pid in pids.prefix(max(0, count)) where pid > 0 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if result == 0 {
            bytes += info.ri_lifetime_max_phys_footprint
        }
    }
    return Double(bytes) / 1_048_576
}

/// CPU used so far: this thread (the main thread), the whole process, and its
/// children (Tinymist).
private struct UsageSnapshot {
    let time = ContinuousClock.now
    let thread = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    let process: Double = {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func value(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1e6
        }
        return value(usage.ru_utime) + value(usage.ru_stime)
    }()

    let children = childrenCPUSeconds()

    /// What was used from this snapshot to `end`, in seconds.
    func usage(to end: UsageSnapshot) -> [String: Double] {
        ["wall_seconds": seconds(time.duration(to: end.time)), "main_thread_cpu_seconds": end.thread - thread,
         "process_cpu_seconds": end.process - process, "children_cpu_seconds": end.children - children]
    }
}
