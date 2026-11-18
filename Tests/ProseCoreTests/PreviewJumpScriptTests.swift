import Foundation
import ProseCore
import Testing

/// The glow that marks a click's spot in the preview (spec Section 3.3).
@Test func previewSetupMarksJumpsThroughTheScrollWrapper() {
    let script = PreviewScripts.setup(canvas: "#f5f5f7", scheme: "light")
    // The wrapper asks the glow first and may skip the scroll.
    #expect(script.contains("window.proseJumpMark?.(this, args) === true"))
    #expect(script.contains("window.proseMarkNextJump = mode =>"))
    #expect(script.contains("window.proseJumpMark = (impl, args) =>"))
    // Tinymist's own ring is hidden; the glow never takes clicks.
    #expect(script.contains(".typst-jump-ripple { display: none !important; }"))
    #expect(script.contains("pointer-events: none"))
    #expect(script.contains("prefers-reduced-motion: reduce"))
    #expect(script.contains(PreviewScripts.jumpGlowLight))
    #expect(script.contains(PreviewScripts.jumpGlowDark))
}

@Test func previewJumpMarksCallTheGuardedPageFunction() {
    #expect(PreviewJumpMark.glow.javaScript == "window.proseMarkNextJump?.('glow') ?? false")
    #expect(PreviewJumpMark.glowIfHidden.javaScript == "window.proseMarkNextJump?.('glowIfHidden') ?? false")
    #expect((28 ... 36).contains(PreviewScripts.jumpGlowSize))
}
