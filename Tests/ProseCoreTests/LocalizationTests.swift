import Foundation
@testable import ProseCore
import Testing

@Test func interfaceTextIsEnglishAndInsertionsKeepTheirPlaceholders() throws {
    #expect(L10n.text("Table") == "Table")
    #expect(L10n.text("An unlisted future label") == "An unlisted future label")
    #expect(L10n.format("%@ commands", "106") == "106 commands")
    // An incremental build can keep a deleted `.lproj` folder; a clean build of the bundle removes it.
    #expect(
        CoreResources.bundle.localizations.allSatisfy { $0.lowercased() == "en" || $0 == "Base" },
        "\(CoreResources.bundle.localizations)",
    )
    #expect(WelcomeDocument.source().contains("= Write in Typst"))
    let table = try TypstInsertion.make("table", values: ["columns": "2", "rows": "1"])
    #expect(table.selections.count == 4)
    #expect((table.text as NSString).substring(with: table.selections[0]) == "Heading 1")
    let literal = "My title 中文😀"
    #expect(try TypstInsertion.make("heading", selection: literal).text == "= " + literal)
    #expect(try TypstInsertion.make("contents").text.contains("#outline(title:"))
    #expect(try TypstInsertion.make("language").text == "#set text(lang: \"en\")\n")
}

@Test func commandSearchMatchesEnglishTitlesKeywordsAndDetails() {
    #expect(WritingCommand.search("table").contains { $0.id == "table" })
    #expect(WritingCommand.search("fraction").contains { $0.id == "fraction" })
    #expect(WritingCommand.search("first line indent").contains { $0.id == "firstLineIndent" })
    #expect(WritingCommand.search("plugin").contains { $0.id == "universe" })
    #expect(WritingCommand.all.allSatisfy { command in
        command.keywords.unicodeScalars.allSatisfy(\.isASCII)
    })
}
