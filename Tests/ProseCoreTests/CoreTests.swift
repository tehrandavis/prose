import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

@Test func framingHandlesEveryByteBoundary() throws {
    let first = try JSONRPCFramer.encode(["jsonrpc": "2.0", "id": 1, "result": "中文😀"])
    let second = try JSONRPCFramer.encode(["id": 2, "result": true])
    let combined = first + second
    for split in 0 ... combined.count {
        var framer = JSONRPCFramer()
        let frames = try framer.append(Data(combined.prefix(split))) + framer.append(Data(combined.dropFirst(split)))
        #expect(frames.count == 2)
        #expect(try JSONDecoder().decode(JSONValue.self, from: frames[0])["result"].string == "中文😀")
    }
}

@Test func framingRejectsMalformedInput() {
    for header in [
        "Content-Length:\r\n\r\n",
        "Content-Length: -1\r\n\r\n",
        "Content-Length: 999999999\r\n\r\n",
        "Invalid: x\r\n\r\n",
    ] {
        var framer = JSONRPCFramer()
        #expect(throws: (any Error).self) { try framer.append(Data(header.utf8)) }
    }
}

@Test func unicodePositionsRoundTrip() {
    let source = "中文😀\r\nsecond é\n最后"
    for index in source.indices {
        let offset = index.utf16Offset(in: source)
        if source[index] != "\r\n" {
            #expect(TextPosition(offset: offset, in: source).offset(in: source) == offset)
        }
    }
    #expect(TextPosition(line: 0, character: 4).utf8Column(in: source) == 10)
    #expect(TextPosition(line: 20, character: 9).offset(in: source) == source.utf16.count)
    #expect(TextPosition(line: 0, character: 99).offset(in: source) == 4)
}

@Test func snippetsPreserveLiteralGuillemetsAndUnicode() throws {
    let value = "«中文😀»"
    let bold = try TypstInsertion.make("bold", selection: value)
    #expect(bold.text == "*«中文😀»*")
    #expect(bold.selections.isEmpty)
    let list = try TypstInsertion.make("bullet", selection: value, language: .simplifiedChinese)
    #expect((list.text as NSString).substring(with: list.selections[0]) == "第二项")
    let image = try TypstInsertion.make("image", values: ["path": "图«一».png", "caption": "«说明»"])
    #expect(image.text.contains("图«一».png"))
    #expect(image.text.contains("«说明»"))
    #expect(image.selections.isEmpty)
}

@Test func tableFieldsAndUnsafeInput() throws {
    let table = try TypstInsertion.make("table", values: ["columns": "2", "rows": "3"])
    #expect(table.selections.count == 8)
    for range in table.selections {
        #expect(!(table.text as NSString).substring(with: range).isEmpty)
    }
    #expect(throws: (any Error).self) { try TypstInsertion.make("table", values: ["rows": "-1"]) }
    #expect(throws: (any Error).self) { try TypstInsertion.make("reference", values: ["name": "oops> #panic()"]) }
    #expect(TypstInsertion.quoted("a\"b\\c\n") == "\"a\\\"b\\\\c\\n\"")
    let code = try TypstInsertion.make("code", selection: "````")
    #expect(code.text.hasPrefix("`````rust"))
}

@Test func settingsComeAfterExistingRules() throws {
    let text = "// A note\n#set page(paper: \"a4\", margin: (x: 20mm))\n#set text(\n size: 11pt,\n)\n\n= Title\nBody"
    let command = try #require(WritingCommand.all.first { $0.id == "margin" })
    let plan = try InsertionPlan(
        command: command,
        snippet: TypstInsertion.make("margin"),
        text: text,
        selection: NSRange(location: text.utf16.count, length: 0),
    )
    let updated = (text as NSString).replacingCharacters(in: plan.range, with: plan.snippet.text)
    #expect(try #require(updated.range(of: "margin: 24mm")?.lowerBound) >
        (try #require(updated.range(of: "size: 11pt"))).upperBound)
    #expect(try #require(updated.range(of: "margin: 24mm")?.upperBound) < (try #require(updated.range(of: "= Title")))
        .lowerBound)
}

@Test func blockInsertionDoesNotMergeWithParagraph() throws {
    let command = try #require(WritingCommand.all.first { $0.id == "heading" })
    let plan = try InsertionPlan(
        command: command,
        snippet: TypstInsertion.make("heading", language: .simplifiedChinese),
        text: "beforeafter",
        selection: NSRange(location: 6, length: 0),
    )
    #expect(plan.snippet.text == "\n\n= 标题\n\n")
    #expect((plan.snippet.text as NSString).substring(with: plan.snippet.selections[0]) == "标题")
}

@Test func storageProtectsExternalEditsAndDeletion() throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("Prose-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("中文 文稿.typ")
    let original = try DocumentStorage.write("initial", to: file, baseline: nil)
    let saved = try DocumentStorage.write("编辑😀", to: file, baseline: original)
    #expect(try DocumentStorage.read(file).0 == "编辑😀")
    try Data("external".utf8).write(to: file)
    #expect(throws: (any Error).self) { try DocumentStorage.write("local", to: file, baseline: saved) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "external")
    try FileManager.default.removeItem(at: file)
    #expect(throws: (any Error).self) { try DocumentStorage.write("local", to: file, baseline: saved) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func commandKeysAreUnambiguous() {
    for group in CommandGroup.all {
        let keys = WritingCommand.all.filter { $0.group == group.id }.map(\.key)
        #expect(Set(keys).count == keys.count)
    }
    #expect(WritingCommand.search("公式").contains { $0.id == "equation" })
    #expect(WritingCommand.search("export pdf").contains { $0.id == "export" })
}

@Test func recoveryPreservesDraftAndMainFile() throws {
    let main = TestPaths.temporaryDirectory.appendingPathComponent("main.typ")
    let child = main.deletingLastPathComponent().appendingPathComponent("章节.typ")
    let snapshot = RecoverySnapshot(fileURL: child, text: "未保存😀", savedText: "旧内容", selection: 5, mainFileURL: main)
    let restored = try JSONDecoder().decode(RecoverySnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(restored.text == "未保存😀")
    #expect(restored.savedText == "旧内容")
    #expect(restored.mainFileURL == main)
    let old = Data(#"{"text":"draft","selection":0}"#.utf8)
    #expect(try JSONDecoder().decode(RecoverySnapshot.self, from: old).mainFileURL == nil)
}
