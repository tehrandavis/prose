import Foundation
@testable import ProseCore
import Testing

@Test func bundledLanguagesResolveWithoutChangingSystemSettings() throws {
    #expect(AppLanguage.resolve(.system, preferredLanguages: ["en-GB"]) == .english)
    #expect(AppLanguage.resolve(.system, preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
    #expect(AppLanguage.resolve(.system, preferredLanguages: ["fr-FR"]) == .english)
    #expect(AppLanguage.resolve(.english, preferredLanguages: ["zh-Hans"]) == .english)
    #expect(L10n.text("Table", language: .english) == "Table")
    #expect(L10n.text("Table", language: .simplifiedChinese) == "表格")
    #expect(L10n.text("An untranslated future label", language: .simplifiedChinese) == "An untranslated future label")
    #expect(WelcomeDocument.source(language: .english).contains("= Write in Typst"))
    #expect(WelcomeDocument.source(language: .simplifiedChinese).contains("= Prose"))
    #expect(L10n.text("Prose", language: .english) == "Prose")
    #expect(L10n.text("Prose", language: .simplifiedChinese) == "Prose")
    #expect(L10n.text("Write in Typst", language: .simplifiedChinese) == "用 Typst 写作")
    let english = try TypstInsertion.make("table", values: ["columns": "2", "rows": "1"], language: .english)
    let chinese = try TypstInsertion.make("table", values: ["columns": "2", "rows": "1"], language: .simplifiedChinese)
    #expect(english.selections.count == chinese.selections.count)
    #expect((english.text as NSString).substring(with: english.selections[0]) == "Heading 1")
    #expect((chinese.text as NSString).substring(with: chinese.selections[0]) == "标题 1")
    for language in [AppLanguage.english, .simplifiedChinese] {
        let literal = "My title 中文😀"
        #expect(try TypstInsertion.make("heading", selection: literal, language: language).text == "= " + literal)
        #expect(try TypstInsertion.make("contents", language: language).text.contains("#outline(title:"))
    }
}
