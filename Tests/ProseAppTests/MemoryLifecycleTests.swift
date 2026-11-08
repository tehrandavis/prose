import AppKit
@testable import ProseApp
import Testing

extension WritingFlowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_MEMORY_CHECKS"] == "1"))
    func repeatedWindowLifecycleReleasesOwnedObjects() async throws {
        // Warm up AppKit/SwiftUI once so system startup allocations have a baseline.
        for cycle in -1 ..< 10 {
            let released = try await exerciseWindowLifecycle()
            let deadline = ContinuousClock.now + .seconds(10)
            while !released.isReleased, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
                autoreleasepool { NSApp.updateWindows() }
            }
            try #require(released.workspace == nil, "Workspace retained after close, cycle \(cycle)")
            try #require(released.editor == nil, "Editor retained after close, cycle \(cycle)")
            try #require(released.window == nil, "Window retained after close, cycle \(cycle)")
            if cycle == -1 {
                try captureMemoryGraph(named: "baseline")
            }
        }
        try captureMemoryGraph(named: "lifecycle")
        print("PROSE MEMORY: completed 10 window lifecycles")
    }
}

@MainActor
private func exerciseWindowLifecycle() async throws -> ReleasedWritingObjects {
    let app = try WritingFixture(
        text: String(repeating: "= Chapter\n\nMemory check 中文😀\n\n", count: 100),
        startService: false,
    )
    defer { app.close() }
    await app.layout()
    let editor = try #require(app.workspace.editor)
    let released = ReleasedWritingObjects(workspace: app.workspace, editor: editor, window: app.window)
    app.workspace.togglePalette()
    app.workspace.query = "table"
    await app.layout()
    app.workspace.closePalette()
    editor.insertText("Edited 中文😀", replacementRange: editor.selectedRange())
    editor.undoManager?.undo()
    editor.undoManager?.redo()
    return released
}

@MainActor
private final class ReleasedWritingObjects {
    weak var workspace: Workspace?
    weak var editor: ManuscriptTextView?
    weak var window: WritingWindow?

    var isReleased: Bool {
        workspace == nil && editor == nil && window == nil
    }

    init(workspace: Workspace, editor: ManuscriptTextView, window: WritingWindow) {
        self.workspace = workspace
        self.editor = editor
        self.window = window
    }
}

@MainActor
private func captureMemoryGraph(named name: String) throws {
    let directory = try #require(ProcessInfo.processInfo.environment["PROSE_MEMORY_REPORT_DIR"])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
    process.arguments = [
        "--outputGraph=\(directory)/\(name).memgraph",
        String(ProcessInfo.processInfo.processIdentifier),
    ]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationReason == .exit && process.terminationStatus == 0, "Memory graph capture failed")
}
