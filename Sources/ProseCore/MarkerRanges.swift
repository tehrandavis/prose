import Foundation

/// The markup characters of an open block (Phase 6 decision 8): which
/// characters are markers, which are code, and, by elimination, which are
/// the writer's words.
///
/// **Markers** draw in the document's font and a faint colour:
///
/// - heading, list, enum and term markers (and a term item's colon);
/// - the `*` delimiters of strong text and the `_` delimiters of emphasis;
/// - for a call with a content block (`#emph[...]`, `#text(fill: red)[...]`):
///   the `#`, the callee's name and each content block's brackets. Its
///   parenthesised arguments are code;
/// - a reference marker (`@key`, key included) and a supplement's brackets;
/// - a label (`<name>`), an escape's backslash, a line break's backslash;
/// - comments.
///
/// **Code** keeps the editor's monospace font and Tinymist's colours:
/// equations and math (the `$` included), inline raw (its backticks
/// included), strings, code blocks and every other expression after `#`
/// (a call with no content block is code whole, `#` included), and the
/// parenthesised arguments of a call with a content block.
///
/// Everything else is words, including the words inside a content block.
/// Ranges are UTF-16, sorted and disjoint, and never overlap one another.
public enum MarkerRanges {
    public struct Result: Equatable, Sendable {
        public var markers: [NSRange]
        public var code: [NSRange]

        public init(markers: [NSRange] = [], code: [NSRange] = []) {
            self.markers = markers
            self.code = code
        }

        /// Both lists moved by `offset`.
        public func offset(by offset: Int) -> Result {
            Result(
                markers: markers.map { NSRange(location: $0.location + offset, length: $0.length) },
                code: code.map { NSRange(location: $0.location + offset, length: $0.length) },
            )
        }
    }

    /// Kinds whose whole range is code, with nothing inside counted again.
    static let codeKinds: Set<SyntaxKind> = [.equation, .math, .raw, .str, .codeBlock]
    /// Kinds whose whole range is a marker, with nothing inside counted again.
    static let markerKinds: Set<SyntaxKind> = [
        .headingMarker, .listMarker, .enumMarker, .termMarker, .refMarker, .label, .linebreak, .lineComment,
        .blockComment,
    ]

    /// The markers and code of `source` from `nodes`, a pre-order list as
    /// `SyntaxTree.nodes(in:)` returns it.
    public static func ranges(_ nodes: [SyntaxNode], source: NSString) -> Result {
        guard !nodes.isEmpty else {
            return Result()
        }
        let tree = SyntaxChildren(nodes)
        var markers: [NSRange] = [], code: [NSRange] = []
        // Nodes inside a range already counted.
        var covered = [Bool](repeating: false, count: nodes.count)
        func cover(_ index: Int) {
            covered[index] = true
            for child in tree.children[index] {
                cover(child)
            }
        }
        func delimiters(of index: Int, _ kind: SyntaxKind) {
            for child in tree.children[index] where nodes[child].kind == kind {
                markers.append(nodes[child].range)
                covered[child] = true
            }
        }
        // The brackets of a content block, as markers; its inside stays.
        func brackets(of block: Int) {
            delimiters(of: block, .leftBracket)
            delimiters(of: block, .rightBracket)
            covered[block] = true
        }
        // The content blocks trailing a call's arguments: `[...]` after the
        // parentheses, or alone.
        func contentBlocks(of call: Int) -> [Int] {
            guard nodes[call].kind == .funcCall, let args = tree.children[call].last, nodes[args].kind == .args
            else {
                return []
            }
            let parts = tree.children[args]
            let close = parts.last { nodes[$0].kind == .rightParen }.map { NSMaxRange(nodes[$0].range) } ?? 0
            return parts.filter { nodes[$0].kind == .contentBlock && nodes[$0].range.location >= close }
        }

        // What a markup `#` embeds: a call with content blocks gives
        // markers and code; any other expression is code with its `#`.
        func embedded(after hash: Int) {
            let next = hash + 1
            guard next < nodes.count, nodes[next].parent == nodes[hash].parent,
                  nodes[next].range.location == NSMaxRange(nodes[hash].range)
            else {
                markers.append(nodes[hash].range)
                return
            }
            let expression = nodes[next]
            let blocks = contentBlocks(of: next)
            guard expression.kind == .funcCall, !blocks.isEmpty, let args = tree.children[next].last else {
                code.append(NSUnionRange(nodes[hash].range, expression.range))
                covered[hash] = true
                cover(next)
                return
            }
            // `#name` (or `#module.name`) up to the arguments.
            markers.append(NSRange(
                location: nodes[hash].range.location,
                length: nodes[args].range.location - nodes[hash].range.location,
            ))
            covered[hash] = true
            for child in tree.children[next] where child != args {
                cover(child)
            }
            covered[next] = true
            covered[args] = true
            let parts = tree.children[args]
            if let open = parts.first(where: { nodes[$0].kind == .leftParen }),
               let close = parts.last(where: { nodes[$0].kind == .rightParen })
            {
                let arguments = NSUnionRange(nodes[open].range, nodes[close].range)
                code.append(arguments)
                for part in parts where NSMaxRange(nodes[part].range) <= NSMaxRange(arguments) {
                    cover(part)
                }
            }
            for block in blocks {
                brackets(of: block)
            }
        }

        for (index, node) in nodes.enumerated() {
            guard !covered[index] else {
                continue
            }
            switch node.kind {
            case _ where codeKinds.contains(node.kind):
                code.append(node.range)
                cover(index)
            case _ where markerKinds.contains(node.kind):
                markers.append(node.range)
                cover(index)
            case .escape:
                // `\*` keeps the escaped character as a word; a Unicode
                // escape (`\u{2014}`) is all marker.
                let first = NSRange(location: node.range.location, length: min(1, node.range.length))
                markers.append(node.range.length == 2 ? first : node.range)
                cover(index)
            case .strong:
                delimiters(of: index, .star)
            case .emph:
                delimiters(of: index, .underscore)
            case .termItem:
                delimiters(of: index, .colon)
            case .ref:
                for child in tree.children[index] where nodes[child].kind == .contentBlock {
                    brackets(of: child)
                }
            case .hash:
                embedded(after: index)
            default:
                continue
            }
        }

        return Result(markers: SpellCheckRanges.merged(markers), code: SpellCheckRanges.merged(code))
    }

    /// The markers and code of a block's text, parsed on its own. A block
    /// starts and ends at line boundaries, so its markup parses as it does in
    /// the document. Ranges are relative to the start of `text`.
    public static func ranges(ofBlock text: String) -> Result {
        guard let tree = SyntaxTree(text) else {
            return Result()
        }
        return ranges(tree.nodes() ?? [], source: text as NSString)
    }
}
