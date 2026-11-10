import AppKit
import Foundation
import ObjectiveC
@testable import ProseApp
import ProseCore
import Testing

/// Puts a test window in the bottom-right corner of the visible area of the
/// screen with the menu bar, out of the way of the writer's work. Setting
/// `PROSE_TEST_SCREEN` to a number (1 is the menu bar's screen, as
/// `NSScreen.screens` orders them) picks another screen. Several pixel tests
/// assume a 2x screen: on a 1x screen the engine's images are resampled, and
/// `focusModeDimsEveryBlockButTheFocusBlocks` fails its contrast check.
@MainActor
func placeOnTestScreen(_ window: NSWindow) {
    let screens = NSScreen.screens
    let chosen = ProcessInfo.processInfo.environment["PROSE_TEST_SCREEN"].flatMap(Int.init) ?? 1
    guard let screen = screens.indices.contains(chosen - 1) ? screens[chosen - 1] : screens.first else {
        return
    }
    let visible = screen.visibleFrame
    let size = window.frame.size
    window.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - size.width), y: visible.minY))
}

/// Fixture text and helpers shared by the Writing mode pointer, selection and
/// keyboard tests (`WritingSelectionFlowTests.swift`,
/// `WritingKeyboardFlowTests.swift`).
let selectionFiller = (1 ... 30)
    .map { "Filler paragraph \($0), plain text that fills the column so the document scrolls.\n\n" }
    .joined()

let selectionSource = """
#set heading(numbering: "1.")
#set par(justify: false)

= Numbered heading

A short paragraph of one line.

A paragraph with inline math $a^2 + b^2 = c^2$ on its first source line, long enough
that Typst wraps it, then continues on a second source line with more words for the
engine to set, and ends on a third source line.

$ integral_0^1 x^2 dif x = 1/3 $

```py
def raw(): return 1
```

// A comment on its own.

Plain paragraph after the code.

\(selectionFiller)The last paragraph.

"""

/// Opens `selectionSource` in Writing mode, light, scrolled to the top, with
/// the caret in the raw block (always source), so every other block renders.
@MainActor
func openSelectionDocument(_ app: WritingFixture) async throws
    -> (ManuscriptTextView, NSTextLayoutManager, WritingLayout)
{
    app.window.appearance = NSAppearance(named: .aqua)
    app.window.orderFront(nil)
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let manager = try #require(editor.textLayoutManager)
    park(editor)
    let model = try await enterWritingMode(app)
    writingScrollToTop(editor)
    await app.layout()
    writingScrollToTop(editor)
    // Under load the fixture's first renders can still be in flight here, and
    // tests read their glyph boxes at once. Wait for the blocks that render.
    let text = editor.string as NSString
    let blocks = ["= Numbered heading", "A short paragraph", "A paragraph with inline math", "$ integral"]
        .map { text.range(of: $0).location }
        .filter { $0 != NSNotFound }
    try await app.wait {
        writingScrollToTop(editor)
        return blocks.allSatisfy { renderedBlock(manager, at: $0) != nil }
    }
    return (editor, manager, model)
}

/// Puts the caret in the raw block; the block it leaves renders again.
@MainActor
func park(_ editor: ManuscriptTextView) {
    let raw = (editor.string as NSString).range(of: "def raw()").location
    editor.setSelectedRange(NSRange(location: raw + 2, length: 0))
    editor.prepareForPointerInteraction()
}

@MainActor
func role(_ model: WritingLayout, _ text: NSString, _ offset: Int) -> WritingRole {
    model.role(forParagraph: text.paragraphRange(for: NSRange(location: offset, length: 0)))
}

struct RenderedBlockInfo {
    let info: WritingFragmentInfo
    let rendering: WritingRendering
    let block: NSRange
}

@MainActor
func renderedBlock(_ manager: NSTextLayoutManager, at offset: Int) -> RenderedBlockInfo? {
    guard let info = writingFragments(manager).first(where: { $0.offset == offset }),
          case let .rendered(rendering, block) = info.role
    else {
        return nil
    }
    return RenderedBlockInfo(info: info, rendering: rendering, block: block)
}

struct GlyphBox {
    /// In container coordinates.
    let box: CGRect
    /// Nil for generated text and sources outside the block.
    let offset: Int?
}

/// The block's glyph boxes on screen, from the engine's geometry: 1.3 times
/// from the fragment's origin, the image's top at the fragment's top.
func glyphBoxes(_ shown: RenderedBlockInfo) -> [GlyphBox] {
    let rendering = shown.rendering, frame = shown.info.frame, scale = rendering.scale
    return rendering.glyphs.compactMap { glyph in
        guard glyph.rect.width > 0.5, glyph.rect.height > 0.5 else {
            return nil
        }
        let box = CGRect(
            x: frame.minX + glyph.rect.minX * scale,
            y: frame.minY + (glyph.rect.minY - rendering.drawnRect.minY) * scale,
            width: glyph.rect.width * scale,
            height: glyph.rect.height * scale,
        )
        let offset = rendering.offset(of: glyph, blockAt: shown.block.location)
            .flatMap { NSLocationInRange($0, shown.block) ? $0 : nil }
        return GlyphBox(box: box, offset: offset)
    }
}

/// The centre of the glyph box of the character at `offset` in the rendered
/// block that starts at `block`.
@MainActor
func glyphCentre(_ manager: NSTextLayoutManager, block: Int, offset: Int) throws -> CGPoint {
    let shown = try #require(renderedBlock(manager, at: block), "Block \(block) is not rendered")
    let boxes = glyphBoxes(shown)
    let glyph = try #require(
        boxes.first { $0.offset == offset },
        "No glyph for \(offset) in block \(shown.block): sources \(boxes.compactMap(\.offset))",
    )
    return CGPoint(x: glyph.box.midX, y: glyph.box.midY)
}

/// Presses at `point` (container coordinates) through `mouseDown(with:)`,
/// drags through `path` and lets go at its end. Prose's tracking loop reads
/// the drags and the release from `pointerEvents`; `record` sees the
/// selection each time the loop asks for its next event.
@MainActor
func writingPress(
    _ editor: ManuscriptTextView,
    at point: CGPoint,
    clicks: Int = 1,
    modifiers: NSEvent.ModifierFlags = [],
    through path: [CGPoint] = [],
    record: ((NSRange) -> Void)? = nil,
) throws {
    let window = try #require(editor.window)
    let origin = editor.textContainerOrigin
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: editor.convert(CGPoint(x: point.x + origin.x, y: point.y + origin.y), to: nil),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1,
        ))
    }
    var script = try path.map { try event(.leftMouseDragged, $0) } + [event(.leftMouseUp, path.last ?? point)]
    editor.pointerEvents = {
        record?(editor.selectedRange())
        return script.isEmpty ? nil : script.removeFirst()
    }
    defer { editor.pointerEvents = nil }
    let unhandled = editor.unhandledScriptedClicks
    try editor.mouseDown(with: event(.leftMouseDown, point))
    #expect(editor.unhandledScriptedClicks == unhandled, "The press at \(point) went to AppKit's tracking")
    #expect(script.isEmpty, "Prose's loop did not read every scripted event")
}

/// An empty selection lies in a paragraph drawn as source, and the caret's
/// rectangle lies in that paragraph's fragment. Since Phase 6 the caret may
/// also rest on a closed fold's first character, drawn on its row or by its
/// mark (`WritingController.foldCaretRect`).
@MainActor
func expectCaretInSource(_ editor: ManuscriptTextView, _ manager: NSTextLayoutManager, _ model: WritingLayout) {
    let caret = editor.selectedRange()
    guard caret.length == 0 else {
        return
    }
    let text = editor.string as NSString
    if let fold = model.fold(holding: caret.location), !fold.isOpen, fold.restingPosition == caret.location {
        let rect = TextKit2Geometry.caretRect(at: caret.location, in: manager)
        let resting = editor.writing.foldCaretRect(at: caret.location, width: rect?.width ?? 0)
        #expect(
            rect != nil && rect == resting,
            "The caret \(caret.location) at a resting position is \(String(describing: rect))",
        )
        return
    }
    let paragraph = text.paragraphRange(for: NSRange(location: caret.location, length: 0))
    #expect(model.role(forParagraph: paragraph) == .source, "The caret \(caret.location) is in a rendered paragraph")
    guard let rect = TextKit2Geometry.caretRect(at: caret.location, in: manager),
          let location = TextKit2Geometry.location(paragraph.location, in: manager),
          let fragment = manager.textLayoutFragment(for: location)
    else {
        Issue.record("No caret rectangle at \(caret.location)")
        return
    }
    let frame = fragment.layoutFragmentFrame
    #expect(rect.midY >= frame.minY && rect.midY <= frame.maxY, "Caret \(rect) outside its paragraph \(frame)")
}

/// The window `giveKeyAppearance` makes draw as key.
private nonisolated(unsafe) weak var keyAppearanceWindow: NSWindow?

/// Makes `window` draw as the key window, as NSTextView sees it, and returns
/// a closure that undoes it. The test process cannot become active, so its
/// windows never become key. `-[NSTextView _selectionBackgroundColor]` reads
/// AppKit's `-[NSWindow hasKeyAppearance]`, and Writing mode reads
/// `isKeyWindow`: `WritingWindow` gets both at run time, answering true for
/// `window` and as NSWindow does for every other window. Then it does what
/// AppKit does when a window's key state changes: tells the window's views
/// (`-[NSWindow _sendForcedWindowChangedKeyState]`, which redraws
/// NSTextView's selection) and posts the key notifications.
@MainActor
func giveKeyAppearance(_ window: WritingWindow) -> () -> Void {
    installKeyAppearanceOverrides
    keyAppearanceWindow = window
    keyStateChanged(window, became: true)
    return {
        keyAppearanceWindow = nil
        keyStateChanged(window, became: false)
    }
}

@MainActor
private func keyStateChanged(_ window: NSWindow, became: Bool) {
    let send = NSSelectorFromString("_sendForcedWindowChangedKeyState")
    if window.responds(to: send) {
        window.perform(send)
    }
    let name = became ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification
    NotificationCenter.default.post(name: name, object: window)
}

private let installKeyAppearanceOverrides: Void = {
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    for name in ["isKeyWindow", "hasKeyAppearance"] {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
            preconditionFailure("NSWindow has no \(name)")
        }
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let answer: @convention(block) (AnyObject) -> Bool = { window in
            window === keyAppearanceWindow || original(window, selector)
        }
        class_addMethod(
            WritingWindow.self,
            selector,
            imp_implementationWithBlock(answer),
            method_getTypeEncoding(method),
        )
    }
}()
