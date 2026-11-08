import Foundation
import PDFKit
@testable import ProseCore
import ProseTestSupport
import Testing

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_INTEGRATION"] == "1"))
func realTinymistRoundTrip() async throws {
    let executable = try #require(TinymistClient.binaryURL)
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    let root = TestPaths.temporaryDirectory.appendingPathComponent("Prose-integration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let client = TinymistClient()
    var diagnosticEvents: [JSONValue] = []
    var statuses: [String] = []
    client.onNotification = { method, params in
        if method == "textDocument/publishDiagnostics" {
            diagnosticEvents.append(params)
        }
        if method == "tinymist/compileStatus", let status = params["status"].string {
            statuses.append(status)
        }
    }
    defer { client.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let file = root.appendingPathComponent("中文 文稿.typ")
    try Data("= Saved sentinel\n".utf8).write(to: file)
    try Data("Included content.".utf8).write(to: root.appendingPathComponent("section.typ"))
    let source = """
    #set text(font: "Noto Sans SC")
    = Unsaved 文稿
    中文😀 Body
    $ x^2 $
    ```rust
    let x = 1;
    ```
    #let foo = 1
    #include "section.typ"
    """
    try await client.start(root: root, outputDirectory: root)
    try client.open(file, text: source, version: 1)
    let preview = try await client.startPreview(file)
    let semantic = try await client.request(
        "textDocument/semanticTokens/full",
        ["textDocument": ["uri": file.absoluteString]],
    )
    let tokens = SemanticHighlighting.decode(
        semantic["data"].array.compactMap(\.int),
        source: source,
        types: client.semanticTokenTypes,
        modifiers: client.semanticTokenModifiers,
    )
    #expect(tokens.contains { $0.kind == "heading" })
    #expect(tokens.contains { $0.modifiers.contains("math") })
    #expect(tokens.contains { (source as NSString).substring(with: $0.range) == "let" && $0.kind == "keyword" })
    #expect(preview.host == "127.0.0.1")
    let (html, response) = try await URLSession.shared.data(from: preview)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(html.count > 100_000)
    let result = try await client.command("tinymist.exportPdf", arguments: [file.path])
    let pdf = try #require(result["path"].string)
    let rendered = try #require(PDFDocument(url: URL(fileURLWithPath: pdf))?.string)
    #expect(rendered.contains("Unsaved"))
    #expect(rendered.contains("文稿"))
    #expect(rendered.contains("Included content"))
    #expect(!diagnosticEvents.contains {
        $0["diagnostics"].array.contains { $0["message"].string == "unknown font family: noto sans sc" }
    })
    #expect(!rendered.contains("Saved sentinel"))
    #expect(try String(contentsOf: file, encoding: .utf8) == "= Saved sentinel\n")

    let positions = [(2, 7), (3, 3), (5, 5), (7, 8)]
    let queries: [[String: Any]] = positions.map { ["kind": "modeAt", "position": ["line": $0.0, "character": $0.1]] }
    let context = try await client.command(
        "tinymist.interactCodeContext",
        arguments: [["textDocument": ["uri": file.absoluteString], "query": queries]],
    )
    #expect(context.array.compactMap { $0["mode"].string } == ["markup", "math", "raw", "code"])
    let symbols = try await client.request(
        "textDocument/documentSymbol",
        ["textDocument": ["uri": file.absoluteString]],
    )
    #expect(symbols.array.contains { $0["name"].string == "Unsaved 文稿" })
    _ = try await client.command(
        "tinymist.scrollPreview",
        arguments: ["prose", ["event": "panelScrollTo", "filepath": file.path, "line": 2, "character": 11]],
    )

    try client.change(file, text: "#te", version: 2)
    let completion = try await client.request(
        "textDocument/completion",
        ["textDocument": ["uri": file.absoluteString], "position": ["line": 0, "character": 3]],
    )
    let items = completion.array.isEmpty ? completion["items"].array : completion.array
    #expect(items.contains { $0["label"].string == "text" })

    try client.change(file, text: "#unknown-function()", version: 3)
    var failed = false
    do { _ = try await client.command("tinymist.exportPdf", arguments: [file.path]) }
    catch { failed = true }
    #expect(failed, "Invalid input must fail instead of exporting the last valid PDF")
    for _ in 0 ..< 100 {
        if diagnosticEvents.contains(where: { $0["diagnostics"].array.contains { $0["severity"].int == 1 } }) {
            break
        }
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(diagnosticEvents.contains { $0["diagnostics"].array.contains { $0["severity"].int == 1 } })

    #expect(statuses.contains("compileSuccess"))
    #expect(statuses.contains("compileError"))

    client.stop()
    #expect(!client.initialized)
    try await client.start(root: root, outputDirectory: root)
    try client.open(file, text: "= Recovered content\n", version: 4)
    _ = try await client.startPreview(file)
    let restored = try await client.command("tinymist.exportPdf", arguments: [file.path])
    let restoredPath = try #require(restored["path"].string)
    #expect(PDFDocument(url: URL(fileURLWithPath: restoredPath))?.string?.contains("Recovered content") == true)
    #expect(try String(contentsOf: file, encoding: .utf8) == "= Saved sentinel\n")
    let child = root.appendingPathComponent("section.typ")
    client.stop()
    try await client.start(root: root, outputDirectory: root)
    try client.open(child, text: "Child initial", version: 1)
    try client.open(file, text: "#include \"section.typ\"\n", version: 1)
    _ = try await client.startPreview(file)
    // Export immediately after each included-source edit, without a sleep or
    // waiting for preview compilation; the PDF must contain that exact revision.
    for edit in 2 ... 21 {
        let expected = "Child unsaved edit \(edit)"
        try client.change(child, text: expected, version: edit)
        let multiFile = try await client.command("tinymist.exportPdf", arguments: [file.path])
        let multiPath = try #require(multiFile["path"].string)
        let data = try Data(contentsOf: URL(fileURLWithPath: multiPath))
        let multiText = PDFDocument(data: data)?.string ?? "<no PDF>"
        #expect(multiText.contains(expected), "Rendered: \(multiText); expected: \(expected)")
    }
    #expect(try String(contentsOf: child, encoding: .utf8) == "Included content.")
}
