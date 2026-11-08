import Foundation
@testable import ProseCore
import Testing

struct DocumentMergeTests {
    @Test func remoteParagraphArrivesWithoutLosingLocalTypingOrCaret() throws {
        let base = "= Shared\n\nFirst paragraph\n\nSecond paragraph\n"
        let local = base.replacingOccurrences(of: "Second", with: "My second")
        let remote = base.replacingOccurrences(of: "First", with: "Their first")
        let result = try #require(DocumentMerge.merge(
            base: base,
            local: local,
            remote: remote,
            selection: NSRange(location: local.utf16.count, length: 0),
        ))
        #expect(result.text.contains("Their first paragraph"))
        #expect(result.text.contains("My second paragraph"))
        #expect(result.selection.location == result.text.utf16.count)
        #expect(DocumentMerge.merge(
            base: base,
            local: local,
            remote: base.replacingOccurrences(of: "Second", with: "Their second"),
            selection: .init(location: 0, length: 0),
        ) == nil)
    }

    @Test func identicalChangesUnicodeAndMultipleHunks() throws {
        let base = "一😀\n二\n三\n四\n五\n"
        let local = "One😀\n二\n三\nFour\n五\n"
        let remote = "One😀\nTwo\n三\n四\nFive\n"
        let result = try #require(DocumentMerge.merge(
            base: base,
            local: local,
            remote: remote,
            selection: NSRange(location: 0, length: local.utf16.count),
        ))
        #expect(result.text == "One😀\nTwo\n三\nFour\nFive\n")
        #expect(result.selection.length == result.text.utf16.count)
        #expect(DocumentMerge.merge(base: "", local: "A", remote: "B", selection: .init(location: 0, length: 0)) == nil)
        #expect(DocumentMerge.merge(base: base, local: base, remote: "", selection: .init(location: 2, length: 0))?
            .text.isEmpty == true)
        #expect(DocumentMerge.merge(base: base, local: local, remote: local, selection: .init(location: 1, length: 0))?
            .text == local)
        #expect(DocumentMerge.merge(base: base, local: local, remote: base, selection: .init(location: 1, length: 0))?
            .text == local)
    }
}
