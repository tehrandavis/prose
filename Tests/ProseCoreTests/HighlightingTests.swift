import Foundation
@testable import ProseCore
import Testing

@Test func semanticTokensDecodeUnicodeAndRejectInvalidRanges() {
    let text = "中文😀\r\n#let x = 12\n"
    let tokens = SemanticHighlighting.decode(
        [0, 0, 4, 0, 0, 1, 1, 3, 1, 1, 0, 8, 2, 2, 0],
        source: text,
        types: ["text", "keyword", "number"],
        modifiers: ["strong"],
    )
    #expect(tokens.map { (text as NSString).substring(with: $0.range) } == ["中文😀", "let", "12"])
    #expect(tokens[1].modifiers == ["strong"])
    for invalid in [[0], [-1, 0, 1, 0, 0], [0, 0, Int.max, 0, 0], [5, 0, 1, 0, 0], [0, 0, 1, 99, 0], [0, 3, 1, 0, 0]] {
        #expect(SemanticHighlighting.decode(invalid, source: text, types: ["text"], modifiers: []).isEmpty)
    }
}

@Test func bundledCodeGrammarsHighlightWithoutExecutingSource() async {
    let highlighter = CodeBlockHighlighting()
    let source = """
    = 中文😀
    ```python
    # A comment
    total = sum(range(1, 11))
    print("<safe> & 中文😀")
    ```
    ```swift
    let value = 42
    ```
    ```unknown-language
    let plain = 42
    ```
    """
    let tokens = await highlighter.tokens(in: source)
    func has(_ text: String, _ kind: String) -> Bool {
        tokens.contains { (source as NSString).substring(with: $0.range) == text && $0.kind.contains(kind) }
    }
    #expect(has("sum", "built_in"))
    #expect(has("1", "number"))
    #expect(has("# A comment", "comment"))
    #expect(has("\"<safe> & 中文😀\"", "string"))
    #expect(has("let", "keyword"))
    let unknown = (source as NSString).range(of: "let plain")
    #expect(!tokens.contains { NSIntersectionRange($0.range, unknown).length > 0 })
    #expect(await highlighter.tokens(in: source) == tokens, "Cached tokens must preserve offsets")
    #expect(
        await highlighter.tokens(in: "```python\nprint(42)").isEmpty == false,
        "An unfinished fence should still highlight",
    )
    #expect(await highlighter.tokens(in: "// ```python\nplain prose").isEmpty)
    #expect(await highlighter.tokens(in: "```python\n" + String(repeating: "x", count: 32001)).isEmpty)
}

@Test func schemeBookHighlightsPastTheFirstEightyBlocks() async {
    let source = String(repeating: "```scheme\n(define (square x) (* x x)) ; 中文😀\n```\n\n", count: 1100)
    let highlighter = CodeBlockHighlighting()
    let tokens = await highlighter.tokens(in: source)
    let ns = source as NSString
    let definitions = tokens.filter { $0.kind.contains("built_in") && ns.substring(with: $0.range) == "define" }
    #expect(definitions.count == 1100)
    #expect(definitions.last?.range.location ?? 0 > ns.length - 100)
    #expect(await highlighter.tokens(in: source) == tokens)
}
