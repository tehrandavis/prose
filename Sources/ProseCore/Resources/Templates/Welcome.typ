// A Prose original. Keep, change or remove any part of this document.
// These pinned packages are included with Prose; this example works offline.
#import "@preview/cetz:0.5.2": canvas, draw
#import "@preview/codly:1.3.0": codly, codly-init

#let ink = rgb("253238")
#let muted = rgb("66736d")
#let sage = rgb("dbe6df")
#set document(title: "Write in Typst", author: "Prose")
#set page(paper: "a4", margin: (x: 25mm, y: 22mm), numbering: "01", number-align: center)
#set text(font: ("Libertinus Serif", "PingFang SC", "Noto Sans SC"), size: 11pt, fill: ink)
#set par(leading: 0.75em)
#set heading(numbering: none)
#show heading.where(level: 1): set text(size: 32pt, weight: "regular")
#show heading.where(level: 2): set text(size: 18pt, weight: "regular")
#show: codly-init.with()
#codly(display-name: false, display-icon: false, zebra-fill: none)

#grid(columns: (10mm, 1fr), align: (left, horizon),
  image("prose-mark.svg", width: 9mm),
  text(size: 9pt, tracking: 3pt, fill: muted)[P R O S E   /   A FIELD GUIDE],
)
#v(9mm)
= Write in Typst

#text(size: 15pt, fill: muted)[Begin with a thought. Give it room to grow.]
#v(7mm)

A sentence, a sketch, a relationship you cannot quite explain yet. Prose keeps your writing close and its tools within reach, so that an unfinished idea has somewhere to go.

This document is yours. Change a word and watch the page respond. Keep a passage you like, replace an example, or start fresh with a blank page.

== Follow the thread

Headings give an idea shape without deciding everything in advance. The outline follows your sections; the library keeps each piece of writing together. Use *⌘O* to return to your writing and *⌘N* to find a new starting point.

#figure(
  canvas(length: 1cm, {
    import draw: *
    let centers = (0, 4.4, 8.8)
    for (x, label) in centers.zip(([Notice], [Connect], [Express])) {
      rect((x, 0), (x + 3.2, 1.05), radius: 0.13, fill: sage, stroke: none)
      content((x + 1.6, 0.525), text(size: 11pt, label))
    }
    line((3.35, 0.525), (4.2, 0.525), stroke: muted + 0.65pt, mark: (end: ">"))
    line((7.75, 0.525), (8.6, 0.525), stroke: muted + 0.65pt, mark: (end: ">"))
  }),
  caption: [A thought becomes clearer when its connections become visible.],
)

#v(3mm)
== Let curiosity lead

Press *⌘J* to discover commands, then follow a category or search for what you want to do. Headings, tables, equations and more are close at hand. Hover over controls to learn their shortcuts as you write.

#block(inset: (x: 14pt, y: 11pt), fill: sage.lighten(55%), radius: 3pt, width: 100%)[
  _The best tool is the one that leaves room for your own way of thinking._
]

#pagebreak()
#text(size: 9pt, tracking: 3pt, fill: muted)[P R O S E   /   IDEAS IN MANY FORMS]
#v(7mm)
== Give a relationship a shape

Some ideas are easier to see as an equation. The golden ratio describes a whole and its parts sharing the same proportion:

$ phi = (1 + sqrt(5)) / 2 approx 1.618 $

An equation can sit quietly inside a sentence, like $a^2 + b^2 = c^2$, or have a line of its own. Add a label when you want to refer back to a figure or table.

== Make room for a detail

#table(
  columns: (1fr, 1.65fr),
  inset: 9pt,
  stroke: (x: none, y: 0.4pt + sage),
  fill: (x, y) => if y == 0 { sage.lighten(35%) },
  table.header([*When you want to…*], [*Try…*]),
  [Find the shape of an idea], [A heading and the outline],
  [See how it will read], [Side-by-side preview, *⌘2*],
  [Add a visual explanation], [Templates → Packages → Diagrams & charts],
  [Share the finished thought], [Export a PDF, *⇧⌘E*],
)

== Show the reasoning

Code can explain a process as clearly as prose. Here the numbered lines make a small experiment easy to discuss. This example is displayed, never run automatically.

```python
observations = [2, 3, 5, 8]
connections = sum(observations)
print(connections)
```

#text(size: 9pt, fill: muted)[The diagram uses CeTZ 0.5.2; the code block uses Codly 1.3.0. Their explicit imports at the top are yours to keep or remove. Find more tools in Packages.]

#v(2mm)
== Make it your own

Prose saves your writing as you go. Edit freely, undo a change, or export the source when you want to take it elsewhere. A document can include local styles and illustrations while staying one piece of writing in your library.

For a closer look at the page's language, explore the #link("https://typst.app/docs/tutorial/")[Typst tutorial]. For community ideas, visit #link("https://typst.app/universe/package/cetz/")[CeTZ] and #link("https://typst.app/universe/package/codly/")[Codly].

#v(3mm)
_What would you like to think through next?_
