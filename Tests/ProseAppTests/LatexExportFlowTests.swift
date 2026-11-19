import Foundation
@testable import ProseApp
import ProseCore
import Testing

extension WritingFlowTests {
    /// Export LaTeX… converts the editor's unsaved text with the built
    /// converter, writes the draft header first, and needs no typesetting service.
    @Test(.enabled(if: LatexExport.converterURL != nil, "Run scripts/build-tylax.sh first"))
    func latexExportWritesADraftFromTheEditorText() async throws {
        let app = try WritingFixture(text: "= LaTeX flow\n\nThe agent's \"quoted\" line.\n", startService: false)
        defer { app.close() }
        app.workspace.text += "\nUnsaved sentinel.\n"
        let output = app.root.appendingPathComponent("flow.tex")
        try await app.workspace.exportLaTeX(to: output)
        let latex = try String(contentsOf: output, encoding: .utf8)
        #expect(latex.hasPrefix("% Draft exported from Prose with Tylax 0.3.8. Check it before use.\n"))
        #expect(latex.contains("\\documentclass"))
        #expect(latex.contains("agent\u{2019}s"))
        #expect(latex.contains("Unsaved sentinel"))
        #expect(app.workspace.message?.hasPrefix("LaTeX draft exported: flow.tex. Check it before use.") == true)

        let missing = app.root.appendingPathComponent("no-converter")
        await #expect(throws: LatexExportError.missingConverter) {
            try await app.workspace.exportLaTeX(to: app.root.appendingPathComponent("missing.tex"), converter: missing)
        }
    }
}
