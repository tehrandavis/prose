//! A file's top level, split into blocks and context lines.

use std::ops::Range;

use typst::syntax::{SyntaxKind, SyntaxNode};

/// What a top-level block is. Every top-level piece of a file is one block,
/// so the blocks cover every character of the file that is not whitespace
/// between them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Heading,
    /// A display equation (`$ x $`, with a space or newline after the `$`).
    Equation,
    Paragraph,
    /// A `#set`, `#show`, `#let` or `#import` line. Its text is also in
    /// `Outline::context`, and it is not meant to be rendered alone.
    Context,
    /// An `#include` line. Not meant to be rendered alone.
    Include,
    /// A single fenced raw block (```` ``` ````), with an optional label.
    Raw,
    /// Only bullet, numbered and term list items.
    List,
    /// Only comments: nothing to render.
    Comment,
}

impl BlockKind {
    /// The kind's code in the C ABI (`PR_BLOCK_*`).
    pub fn code(self) -> u32 {
        match self {
            Self::Heading => 1,
            Self::Equation => 2,
            Self::Paragraph => 3,
            Self::Context => 4,
            Self::Include => 5,
            Self::Raw => 6,
            Self::List => 7,
            Self::Comment => 8,
        }
    }

    /// Whether the editor draws blocks of this kind from a render. Context,
    /// include and comment blocks draw as pills; the others render (raw blocks
    /// render too, though Writing mode shows them as source).
    pub fn renders(self) -> bool {
        !matches!(self, Self::Context | Self::Include | Self::Comment)
    }
}

/// A block as a byte range of its file.
#[derive(Debug, Clone)]
pub struct Block {
    pub range: Range<usize>,
    pub kind: BlockKind,
}

/// A file's top level: every block in order, and the context lines (`#set`,
/// `#show`, `#let`, `#import`) that each block document starts with. Ranges
/// are bytes. A context line is a block too, of kind `Context`.
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

fn is_comment(kind: SyntaxKind) -> bool {
    matches!(kind, SyntaxKind::LineComment | SyntaxKind::BlockComment)
}

fn is_item(kind: SyntaxKind) -> bool {
    matches!(
        kind,
        SyntaxKind::ListItem | SyntaxKind::EnumItem | SyntaxKind::TermItem
    )
}

/// Whether a paragraph break at `children[index]` lies inside one list, as
/// Typst groups it: items of one kind (bullet, numbered or term) with only
/// spaces and paragraph breaks between them form one list (typst-realize's
/// list grouping), and comments leave no content at all. Anything else
/// between them, an item of another kind included, ends the list. Splitting
/// a loose list there would restart its numbering.
fn inside_list(run: Option<&Run>, children: &[&SyntaxNode], index: usize) -> bool {
    let Some(last) = run
        .and_then(|run| run.significant.last())
        .map(|(kind, _)| *kind)
    else {
        return false;
    };
    if !is_item(last) {
        return false;
    }
    children[index + 1..]
        .iter()
        .map(|node| node.kind())
        .find(|kind| {
            !matches!(kind, SyntaxKind::Space | SyntaxKind::Parbreak) && !is_comment(*kind)
        })
        == Some(last)
}

/// Whether a node is a space within one line.
fn inline_space(node: &SyntaxNode, text: &str) -> bool {
    node.kind() == SyntaxKind::Space && !text.contains('\n')
}

/// A block being collected: its byte range and its top-level nodes other
/// than spaces and comments, which decide its kind.
struct Run {
    start: usize,
    end: usize,
    significant: Vec<(SyntaxKind, Range<usize>)>,
}

/// The kind of a collected run, or None if it holds only whitespace.
fn classify(run: &Run, text: &str) -> Option<BlockKind> {
    if text[run.start..run.end].trim().is_empty() {
        return None;
    }
    let Some((first, range)) = run.significant.first() else {
        return Some(BlockKind::Comment);
    };
    let source = &text[range.clone()];
    let unlabelled: Vec<SyntaxKind> = run
        .significant
        .iter()
        .map(|(kind, _)| *kind)
        .filter(|kind| *kind != SyntaxKind::Label)
        .collect();
    let kind = if *first == SyntaxKind::Equation
        && source.len() > 2
        && source[1..].starts_with(char::is_whitespace)
    {
        // A display equation has a space or newline after its opening `$`.
        BlockKind::Equation
    } else if unlabelled == [SyntaxKind::Raw] && source.starts_with("```") {
        BlockKind::Raw
    } else if run.significant.iter().all(|(kind, _)| is_item(*kind)) {
        BlockKind::List
    } else {
        BlockKind::Paragraph
    };
    Some(kind)
}

/// Splits the top level of a parsed file at paragraph breaks, except inside a
/// loose list. Headings end their block, together with a trailing label. Context lines and `#include`
/// lines are blocks of their own, together with a comment on the same line.
/// A block's range ends at its last character that is not whitespace.
pub fn split_tree(root: &SyntaxNode, text: &str) -> Outline {
    let mut outline = Outline::default();
    let mut current: Option<Run> = None;
    let mut offset = 0;
    let children: Vec<&SyntaxNode> = root.children().collect();
    let push = |outline: &mut Outline, range: Range<usize>, kind: BlockKind| {
        let end = range.start + text[range.clone()].trim_end().len();
        outline.blocks.push(Block {
            range: range.start..end,
            kind,
        });
    };
    let flush = |current: &mut Option<Run>, outline: &mut Outline| {
        if let Some(run) = current.take() {
            if let Some(kind) = classify(&run, text) {
                push(outline, run.start..run.end, kind);
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
            SyntaxKind::Parbreak if inside_list(current.as_ref(), &children, index) => {}
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
                let line_end = end + expr.len();
                let kind = if expr.kind() == SyntaxKind::ModuleInclude {
                    BlockKind::Include
                } else {
                    outline.context.push(start..line_end);
                    BlockKind::Context
                };
                // A comment after the line, on the same line, belongs to it.
                let mut block_end = line_end;
                let mut skip = 2;
                let mut at = line_end;
                while let Some(n) = children.get(index + skip) {
                    if is_comment(n.kind()) {
                        block_end = at + n.len();
                        skip += 1;
                        break;
                    }
                    if !inline_space(n, &text[at..at + n.len()]) {
                        break;
                    }
                    at += n.len();
                    skip += 1;
                }
                if block_end == line_end {
                    skip = 2;
                }
                push(&mut outline, start..block_end, kind);
                offset = block_end;
                index += skip;
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
                push(&mut outline, start..end, BlockKind::Heading);
                offset = end;
                index += skip;
                continue;
            }
            SyntaxKind::Space if current.is_none() => {}
            kind => {
                let run = current.get_or_insert(Run {
                    start,
                    end,
                    significant: vec![],
                });
                run.end = end;
                if kind != SyntaxKind::Space && !is_comment(kind) {
                    run.significant.push((kind, start..end));
                }
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
