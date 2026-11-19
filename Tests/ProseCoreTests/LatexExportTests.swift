import Foundation
@testable import ProseCore
import Testing

@Test func latexExportTurnsMarkupQuotesTypographic() {
    #expect(LatexExport.typographicQuotes("The agent's line") == "The agent\u{2019}s line")
    #expect(
        LatexExport.typographicQuotes("She said \"hello\" twice.")
            == "She said \u{201C}hello\u{201D} twice.",
    )
    #expect(LatexExport.typographicQuotes("\"Start\" here") == "\u{201C}Start\u{201D} here")
    #expect(LatexExport.typographicQuotes("('quoted')") == "(\u{2018}quoted\u{2019})")
    #expect(LatexExport.typographicQuotes("a -'word'") == "a -\u{2018}word\u{2019}")
    #expect(LatexExport.typographicQuotes("rock 'n' roll in the '90s") ==
        "rock \u{2018}n\u{2019} roll in the \u{2018}90s")
    #expect(LatexExport.typographicQuotes("\"'Nested' quotes\"") ==
        "\u{201C}\u{2018}Nested\u{2019} quotes\u{201D}")
    #expect(LatexExport.typographicQuotes("Typographic ’ “ ” stay") == "Typographic ’ “ ” stay")
}

@Test func latexExportLeavesQuotesOutsideMarkupAlone() {
    let math = "Prime $f'(x) = \"text\"$ here's"
    #expect(LatexExport.typographicQuotes(math) == "Prime $f'(x) = \"text\"$ here\u{2019}s")
    let raw = "Code `it's \"raw\"` and it's"
    #expect(LatexExport.typographicQuotes(raw) == "Code `it's \"raw\"` and it\u{2019}s")
    let string = "#text(\"it's\") and it's"
    #expect(LatexExport.typographicQuotes(string) == "#text(\"it's\") and it\u{2019}s")
    let block = "```\nlet s = \"x\"\n```\n"
    #expect(LatexExport.typographicQuotes(block) == block)
    let comment = "// it's \"a\" comment\nText"
    #expect(LatexExport.typographicQuotes(comment) == comment)
}

@Test func latexExportReadsTylaxWarnings() {
    let stderr = "\n\u{1B}[33mConversion Warnings (2):\u{1B}[0m\n\n"
        + "  \u{1B}[36m[other]\u{1B}[0m file not found: @preview/cetz:0.3.0\n"
        + "  \u{1B}[36m[unsupported]\u{1B}[0m grid columns ignored\n\n"
    #expect(LatexExport.warnings(fromStandardError: stderr) == [
        "[other] file not found: @preview/cetz:0.3.0",
        "[unsupported] grid columns ignored",
    ])
    #expect(LatexExport.warnings(fromStandardError: "").isEmpty)
    #expect(LatexExport.warnings(fromStandardError: "something else\n").isEmpty)
}

@Test func latexExportHeaderMarksTheDraftAndListsWarnings() {
    let header = LatexExport.header(warnings: ["one", "two\nlines"])
    let lines = header.components(separatedBy: "\n")
    #expect(lines[0] == "% Draft exported from Prose with Tylax 0.3.8. Check it before use.")
    #expect(lines[1] == "% warning: one")
    #expect(lines[2] == "% warning: two lines")
    #expect(header.hasSuffix("\n\n"))
    #expect(LatexExport.header(warnings: []).components(separatedBy: "\n").count == 3)
}

@Test func latexExportNoticesLocalIncludesButNotPackages() {
    #expect(LatexExport.referencesLocalFiles("#include \"chapter.typ\""))
    #expect(LatexExport.referencesLocalFiles("#import \"defs.typ\": *"))
    #expect(!LatexExport.referencesLocalFiles("#import \"@preview/cetz:0.3.0\": canvas"))
    #expect(!LatexExport.referencesLocalFiles("Plain text"))
}

@Test func latexExportSummaryCountsWarningsAndIncludes() {
    #expect(LatexExport.summary(fileName: "a.tex", warnings: 0, referencesLocalFiles: false)
        == "LaTeX draft exported: a.tex. Check it before use.")
    #expect(LatexExport.summary(fileName: "a.tex", warnings: 1, referencesLocalFiles: false)
        .hasSuffix("Tylax reported 1 warning; it is listed at the top of the file."))
    #expect(LatexExport.summary(fileName: "a.tex", warnings: 3, referencesLocalFiles: true)
        .hasSuffix(
            "Tylax reported 3 warnings; they are listed at the top of the file. Included files are not converted.",
        ))
}

@Test(.enabled(if: LatexExport.converterURL != nil, "Run scripts/build-tylax.sh first"))
func latexExportConvertsWithTheBuiltConverterAndKeepsQuotes() throws {
    let converter = try #require(LatexExport.converterURL)
    let source = "= Title\n\nThe agent's line and \"quoted\" text.\n/*<abc123*/marked/*abc123>*/\n// prose:comment abc123\n"
    let result = try LatexExport.convert(
        source,
        converter: converter,
        directory: FileManager.default.temporaryDirectory,
    )
    #expect(result.latex.hasPrefix("% Draft exported from Prose with Tylax 0.3.8. Check it before use.\n"))
    #expect(result.latex.contains("\\documentclass"))
    #expect(result.latex.contains("agent\u{2019}s"))
    #expect(result.latex.contains("\u{201C}quoted\u{201D}"))
    #expect(!result.latex.contains("prose:comment"))
    #expect(!result.latex.contains("abc123"))
}
