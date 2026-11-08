//! A file's top level, split into blocks and context lines.

use std::ops::Range;

use typst::syntax::{SyntaxKind, SyntaxNode};

/// What a top-level block is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Heading,
    Equation,
    Paragraph,
}

impl BlockKind {
    /// The kind's code in the C ABI (`PR_BLOCK_*`).
    pub fn code(self) -> u32 {
        match self {
            Self::Heading => 1,
            Self::Equation => 2,
            Self::Paragraph => 3,
        }
    }
}

/// A block as a byte range of its file.
#[derive(Debug, Clone)]
pub struct Block {
    pub range: Range<usize>,
    pub kind: BlockKind,
}

/// A file's top level, split into rendered blocks and context lines
/// (`#set`, `#show`, `#let`, `#import`). Ranges are bytes.
#[derive(Debug, Default)]
pub struct Outline {
    pub blocks: Vec<Block>,
    pub context: Vec<Range<usize>>,
}

/// Splits source text. Parses it first; use `split_tree` with a tree you
/// already have.
pub fn split(text: &str) -> Outline {
    split_tree(&typst::syntax::parse(text), text)
}

/// Splits the top level of a parsed file at paragraph breaks. Headings end
/// their block, together with a trailing label. Context lines are not blocks;
/// an `#include` line is neither.
pub fn split_tree(root: &SyntaxNode, text: &str) -> Outline {
    let mut outline = Outline::default();
    let mut current: Option<(usize, usize, BlockKind)> = None;
    let mut offset = 0;
    let children: Vec<&SyntaxNode> = root.children().collect();
    let flush = |current: &mut Option<(usize, usize, BlockKind)>, outline: &mut Outline| {
        if let Some((start, end, kind)) = current.take() {
            if !text[start..end].trim().is_empty() {
                outline.blocks.push(Block {
                    range: start..end,
                    kind,
                });
            }
        }
    };
    let mut index = 0;
    while index < children.len() {
        let node = children[index];
        let start = offset;
        let end = start + node.len();
        let next = children.get(index + 1).copied();
        match node.kind() {
            SyntaxKind::Parbreak => flush(&mut current, &mut outline),
            SyntaxKind::Hash
                if next.is_some_and(|n| {
                    matches!(
                        n.kind(),
                        SyntaxKind::SetRule
                            | SyntaxKind::ShowRule
                            | SyntaxKind::LetBinding
                            | SyntaxKind::ModuleImport
                            | SyntaxKind::ModuleInclude
                    )
                }) =>
            {
                flush(&mut current, &mut outline);
                let expr = next.unwrap();
                if expr.kind() != SyntaxKind::ModuleInclude {
                    outline.context.push(start..end + expr.len());
                }
                offset = end + expr.len();
                index += 2;
                continue;
            }
            SyntaxKind::Heading => {
                flush(&mut current, &mut outline);
                let mut end = end;
                let mut skip = 1;
                while let Some(n) = children.get(index + skip) {
                    let inline_space =
                        n.kind() == SyntaxKind::Space && !text[end..end + n.len()].contains('\n');
                    if !inline_space && n.kind() != SyntaxKind::Label {
                        break;
                    }
                    end += n.len();
                    skip += 1;
                }
                current = Some((start, end, BlockKind::Heading));
                flush(&mut current, &mut outline);
                offset = end;
                index += skip;
                continue;
            }
            SyntaxKind::Space if current.is_none() => {}
            kind => {
                // A display equation has a space or newline after its opening `$`.
                let source = &text[start..end];
                let block = if kind == SyntaxKind::Equation
                    && source.len() > 2
                    && source[1..].starts_with(char::is_whitespace)
                {
                    BlockKind::Equation
                } else {
                    BlockKind::Paragraph
                };
                current = Some(match current {
                    Some((s, _, k)) => (s, end, k),
                    None => (start, end, block),
                });
            }
        }
        offset = end;
        index += 1;
    }
    flush(&mut current, &mut outline);
    outline
}

/// A label a block uses: its name, and whether it is an `@ref` (rather than a
/// `<label>` in code, such as `link(<x>)`).
pub(crate) struct LabelUse {
    pub(crate) name: String,
    pub(crate) is_ref: bool,
}

/// Labels a block refers to (`@x`, `<x>` in code) and labels it defines.
pub(crate) fn labels(text: &str) -> (Vec<LabelUse>, Vec<String>) {
    fn walk(
        node: &SyntaxNode,
        in_markup: bool,
        uses: &mut Vec<LabelUse>,
        defined: &mut Vec<String>,
    ) {
        match node.kind() {
            SyntaxKind::Ref => {
                let name = node
                    .children()
                    .find(|c| c.kind() == SyntaxKind::RefMarker)
                    .map(|m| m.leaf_text().trim_start_matches('@').to_string())
                    .unwrap_or_default();
                uses.push(LabelUse { name, is_ref: true });
            }
            SyntaxKind::Label => {
                let name = node
                    .leaf_text()
                    .trim_start_matches('<')
                    .trim_end_matches('>')
                    .to_string();
                if in_markup {
                    defined.push(name)
                } else {
                    uses.push(LabelUse {
                        name,
                        is_ref: false,
                    })
                }
            }
            _ => {}
        }
        let markup = matches!(node.kind(), SyntaxKind::Markup);
        let code = matches!(
            node.kind(),
            SyntaxKind::Code | SyntaxKind::Args | SyntaxKind::FuncCall | SyntaxKind::Array
        );
        for child in node.children() {
            walk(
                child,
                if markup {
                    true
                } else if code {
                    false
                } else {
                    in_markup
                },
                uses,
                defined,
            );
        }
    }
    let root = typst::syntax::parse(text);
    let mut uses = Vec::new();
    let mut defined = Vec::new();
    walk(&root, true, &mut uses, &mut defined);
    (uses, defined)
}
