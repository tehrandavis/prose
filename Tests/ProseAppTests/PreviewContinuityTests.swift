import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import ProseTestSupport
import Testing
import WebKit

@Suite(.serialized) @MainActor struct PreviewContinuityTests {
    @Test func lazyPagesRestoreBeforePaintingAndScrollingSupersedesRestoration() async throws {
        let fixture = try PreviewReadingFixture(script: PreviewScripts.reading, lazySVG: true)
        defer { fixture.close() }
        try await fixture.ready()
        let web = fixture.web
        #expect(try await web
            .evaluateJavaScript("window.proseRestoreReading({page:1,x:.5,y:.4,viewportY:.2})") as? Bool == true)
        // WebKit delivers the scroll event and bounded restore passes asynchronously;
        // a fixed sleep can read the previous anchor on a busy CI runner.
        try await waitForJavaScript(web, condition: "window.proseCaptureReading()?.page === 1")
        let first = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
        #expect(PreviewReadingAnchor(message: first)?.page == 1)
        // A rendering pass only adds glyphs. It must not restore an old page.
        try await web.evaluateJavaScript("""
        window.prosePrepareResize();
        document.getElementById('typst-container-main').scrollTop = 2200;
        document.querySelector('.typst-page').innerHTML = '<rect width="600" height="1000"/>';
        """)
        try await waitForJavaScript(web, condition: "window.proseCaptureReading()?.page === 2")
        let last = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
        #expect(PreviewReadingAnchor(message: last)?.page == 2)
    }

    @Test func normalizedReadingAnchorSurvivesZoomAndSourceJumpCancelsRestore() async throws {
        let fixture = try PreviewReadingFixture(script: PreviewScripts.reading)
        defer { fixture.close() }
        try await fixture.ready()
        let web = fixture.web
        let anchor = try #require(PreviewReadingAnchor(page: 1, x: 0.5, y: 0.35, viewportY: 0.2))
        #expect(try await web
            .evaluateJavaScript("window.proseRestoreReading(\(anchor.javaScript))") as? Bool == true)
        try await Task.sleep(for: .milliseconds(500))
        let beforeMessage = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
        let before = try #require(PreviewReadingAnchor(message: beforeMessage))
        #expect(before.page == 1)
        #expect(abs(before.y - anchor.y) < 0.02)
        let coordinator = PreviewView.Coordinator(onError: { _ in })
        coordinator.zoom = 1.4
        coordinator.applyZoom(to: web)
        try await Task.sleep(for: .milliseconds(500))
        let zoomedMessage = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
        let zoomed = try #require(PreviewReadingAnchor(message: zoomedMessage))
        #expect(zoomed.page == before.page)
        #expect(abs(zoomed.y - before.y) < 0.02)
        // Entering and leaving a bounded reading column must retain the same
        // page-relative position even when the zoom setting does not change.
        for limit: CGFloat? in [400, nil] {
            coordinator.maxPageWidth = limit
            coordinator.applyZoom(to: web)
            try await Task.sleep(for: .milliseconds(500))
            let message = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
            let resized = try #require(PreviewReadingAnchor(message: message))
            #expect(resized.page == before.page)
            #expect(abs(resized.y - before.y) < 0.02)
            let width = try #require(await web.evaluateJavaScript(
                "document.getElementById('typst-container').getBoundingClientRect().width",
            ) as? Double)
            // Non-overlay scrollbars reduce the percentage width's containing block.
            let available = try #require(await web.evaluateJavaScript(
                "document.getElementById('typst-container-main').clientWidth",
            ) as? Double)
            // Beside the text (no limit), pages leave a gutter of canvas on each side.
            let expected = limit.map { min(available, Double($0)) * Double(coordinator.zoom) }
                ?? available * Double(coordinator.zoom) - Double(2 * PreviewScripts.sideGutter)
            #expect(abs(width - expected) < 1)
        }
        try await web
            .evaluateJavaScript(
                "window.prosePrepareResize(); window.proseSourceJump(); document.getElementById('typst-container-main').scrollTop = 0;",
            )
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await web
            .evaluateJavaScript("document.getElementById('typst-container-main').scrollTop") as? Double == 0)
        // A shortened document must still provide a bounded, valid return.
        try await web.evaluateJavaScript("document.querySelectorAll('.typst-page-inner')[2].remove();")
        #expect(try await web
            .evaluateJavaScript("window.proseRestoreReading({page:99,x:.5,y:.3,viewportY:.2})") as? Bool == true)
        #expect(try await web
            .evaluateJavaScript("window.proseRestoreReading({page:-1,x:.5,y:.3,viewportY:.2})") as? Bool == false)
    }

    @Test func readingPositionSurvivesALiveSplitDividerDrag() async throws {
        let fixture = try PreviewReadingFixture(script: PreviewScripts.reading)
        defer { fixture.close() }
        try await fixture.ready()
        let web = fixture.web
        let window = try #require(web.window)
        let anchor = try #require(PreviewReadingAnchor(page: 1, x: 0.5, y: 0.35, viewportY: 0.2))
        #expect(try await web
            .evaluateJavaScript("window.proseRestoreReading(\(anchor.javaScript))") as? Bool == true)
        try await Task.sleep(for: .milliseconds(500))
        let beforeMessage = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
        let before = try #require(PreviewReadingAnchor(message: beforeMessage))
        // Dragging the divider resizes the preview on every pointer event,
        // narrowing and widening the pages faster than the restore passes.
        let widths = Array(stride(from: 600, through: 360, by: -20)) + Array(stride(from: 380, through: 520, by: 20))
        for width in widths {
            window.setContentSize(NSSize(width: CGFloat(width), height: 500))
            try await Task.sleep(for: .milliseconds(8))
        }
        try await Task.sleep(for: .milliseconds(600))
        let afterMessage = try #require(await web.evaluateJavaScript("window.proseCaptureReading()"))
        let after = try #require(PreviewReadingAnchor(message: afterMessage))
        #expect(after.page == before.page)
        #expect(abs(after.y - before.y) < 0.02)
        #expect(web.frame.width == 520)
    }

    @Test func nativeReturnRestoresBookmarkedPageAndAcknowledgesSuccess() async throws {
        let fixture = try PreviewReadingFixture(script: PreviewScripts.reading)
        defer { fixture.close() }
        try await fixture.ready()
        let session = PreviewReadingSession()
        let coordinator = PreviewView.Coordinator(readingSession: session, onError: { _ in })
        try session.observe(#require(PreviewReadingAnchor(page: 2, x: 0.5, y: 0.4, viewportY: 0.2)))
        session.rememberReturnPosition()
        session.returnToReading()
        coordinator.restoreReading(in: fixture.web)
        let deadline = ContinuousClock.now + .seconds(5)
        while session.restore != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(session.restore == nil)
        #expect(session.returnAnchor == nil)
        try await Task.sleep(for: .milliseconds(500))
        let result = try #require(await fixture.web.evaluateJavaScript("window.proseCaptureReading()"))
        let anchor = try #require(PreviewReadingAnchor(message: result))
        #expect(anchor.page == 2)
        #expect(abs(anchor.y - 0.4) < 0.02)
    }

    @Test func pressedPreviewTextIsReportedByItsGlyphBoundsForTheNextSourceJump() async throws {
        let fixture = try PreviewReadingFixture(script: PreviewScripts.reading, lazySVG: true)
        defer { fixture.close() }
        try await fixture.ready()
        let session = PreviewReadingSession()
        let coordinator = PreviewView.Coordinator(readingSession: session, onError: { _ in })
        try await coordinator.receiveReading(fixture.pressHeadingRun())
        #expect(session.takeClick() == PreviewClick(text: "LB-001", line: "LB-001 大文档检查"))
    }

    @Test func nativeReadingBridgePausesFollowAndRetainsBookmark() {
        let session = PreviewReadingSession()
        let coordinator = PreviewView.Coordinator(readingSession: session, onError: { _ in })
        coordinator.receiveReading([
            "kind": "anchor",
            "anchor": ["page": 2, "x": 0.5, "y": 0.4, "viewportY": 0.2] as [String: Any],
        ])
        session.rememberReturnPosition()
        session.followsWriting = true
        coordinator.receiveReading(["kind": "manualScroll"])
        #expect(!session.followsWriting)
        #expect(session.returnAnchor?.page == 2)
        let web = PreviewWebView()
        var invalidations = 0
        web.onWillLoad = { invalidations += 1 }
        _ = web.reload()
        #expect(invalidations == 1)
    }
}
