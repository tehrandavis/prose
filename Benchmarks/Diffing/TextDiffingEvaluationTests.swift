import AppKit
import Foundation
import Testing
@testable import TextDiffing

@Suite(.serialized) struct ProseEvaluationTests {
    @Test func roundTripsWritingEdits() {
        let cases = [
            ("macOS 26 Fedora 44", "#macOS 26 #Fedora44"),
            ("#set text(size: 11pt)\n$alpha + beta$", "#set text(size: 12pt)\n$alpha - beta$"),
            ("思考和书写，中文😀", "思考与书写。中文👨‍👩‍👧‍👦"),
            ("a b a c", "a x b x a c"),
            ("a\n\nb", "a\nb"),
        ]
        for (old, new) in cases {
            let tokenizer = WordStringTokenizer()
            let parts = tokenizer.tokenize(new).diffSegments(comparingWith: tokenizer.tokenize(old))
            let recoveredOld = parts.filter { $0.type != .inserted }.map(\.element).joined()
            let recoveredNew = parts.filter { $0.type != .removed }.map(\.element).joined()
            #expect(recoveredOld == old)
            #expect(recoveredNew == new)
        }
    }

    @Test func writingWorkloads() {
        let style = TextDiffStyle(insertedBackground: .systemGreen, removedBackground: .systemRed)
        for count in [200, 1000, 4000] {
            let old = (0 ..< count).map { "alpha\($0)" }.joined(separator: " ")
            let new = (0 ..< count).map { "omega\($0)" }.joined(separator: " ")
            let start = ContinuousClock.now
            let result = TextDiffer.diff(old, and: new, style: style)
            print(
                "PROSE_DIFF rewritten bytes=\(old.utf8.count) duration=\(start.duration(to: .now)) changes=\(result.changeCount)",
            )
        }
        let book = (0 ..< 40000).map { "Line \($0): 思考与书写 $alpha + beta$.\n" }.joined()
        let edited = book.replacingOccurrences(of: "Line 20000:", with: "Edited 20000:")
        let start = ContinuousClock.now
        let result = TextDiffer.diff(book, and: edited, style: style)
        print(
            "PROSE_DIFF book bytes=\(book.utf8.count) duration=\(start.duration(to: .now)) changes=\(result.changeCount)",
        )
    }
}
