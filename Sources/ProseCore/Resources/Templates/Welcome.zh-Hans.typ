// A Prose original. Keep, change or remove any part of this document.
// These pinned packages are included with Prose; this example works offline.
#import "@preview/cetz:0.5.2": canvas, draw
#import "@preview/codly:1.3.0": codly, codly-init

#let ink = rgb("253238")
#let muted = rgb("66736d")
#let sage = rgb("dbe6df")
#set document(title: "Prose", author: "Prose")
#set page(paper: "a4", margin: (x: 25mm, y: 22mm), numbering: "01", number-align: center)
#set text(font: ("Libertinus Serif", "PingFang SC", "Noto Sans SC"), size: 11pt, fill: ink)
#set par(leading: 0.85em)
#set text(lang: "zh")
#set heading(numbering: none)
#show heading.where(level: 1): set text(size: 32pt, weight: "regular")
#show heading.where(level: 2): set text(size: 18pt, weight: "regular")
#show: codly-init.with()
#codly(display-name: false, display-icon: false, zebra-fill: none)

#grid(columns: (10mm, 1fr), align: (left, horizon),
  image("prose-mark.svg", width: 9mm),
  text(size: 9pt, tracking: 3pt, fill: muted)[留 白   /   写作手记],
)
#v(9mm)
= Prose

#text(size: 15pt, fill: muted)[用 Typst 写作]
#v(7mm)

一句话、一张草图、一种暂时说不清的联系。Prose让文字留在眼前，让工具触手可及，给尚未成形的想法一个落脚的地方。

这份文稿属于你。改一个词，看看页面如何回应。留下喜欢的段落，替换一个示例，或者从空白页重新开始。

== 顺着思路写下去

标题帮你理清思路，不必事先安排好一切。文章脉络跟随章节展开，文稿库把每篇作品放在一起。按 *⌘O* 返回文稿库，按 *⌘N* 寻找新的起点。

#figure(
  canvas(length: 1cm, {
    import draw: *
    let centers = (0, 4.4, 8.8)
    for (x, label) in centers.zip(([观察], [联系], [表达])) {
      rect((x, 0), (x + 3.2, 1.05), radius: 0.13, fill: sage, stroke: none)
      content((x + 1.6, 0.525), text(size: 11pt, label))
    }
    line((3.35, 0.525), (4.2, 0.525), stroke: muted + 0.65pt, mark: (end: ">"))
    line((7.75, 0.525), (8.6, 0.525), stroke: muted + 0.65pt, mark: (end: ">"))
  }),
  caption: [当联系变得可见，想法也变得清晰。],
)

#v(3mm)
== 让好奇心带路

按 *⌘J* 发现命令，沿分类探索，或者直接搜索想做的事。标题、表格、公式等工具随手可用。把鼠标放在控件上，边写边熟悉快捷键。

#block(inset: (x: 14pt, y: 11pt), fill: sage.lighten(55%), radius: 3pt, width: 100%)[
  _好的工具，会为你自己的思考方式留出空间。_
]

#pagebreak()
#text(size: 9pt, tracking: 3pt, fill: muted)[留 白   /   想法的不同形状]
#v(7mm)
== 让关系有形可见

有些想法，用公式表达更加清晰。黄金比例描述了整体与局部之间相同的比例关系：

$ phi = (1 + sqrt(5)) / 2 approx 1.618 $

公式可以安静地待在一句话中，比如 $a^2 + b^2 = c^2$，也可以独占一行。给图表加上标签，就能在后文引用它。

== 把细节说明白

#table(
  columns: (1fr, 1.65fr),
  inset: 9pt,
  stroke: (x: none, y: 0.4pt + sage),
  fill: (x, y) => if y == 0 { sage.lighten(35%) },
  table.header([*当你想要……*], [*可以试试……*]),
  [梳理想法], [标题和文章脉络],
  [看看排版效果], [并排预览，*⌘2*],
  [用图解说明], [模板 → 扩展包 → 图解与图表],
  [分享写好的内容], [导出 PDF，*⇧⌘E*],
)

== 展示推理的过程

代码和文字一样，也能把过程说清楚。行号让一个小实验更便于讨论。这里的代码仅作展示，不会自动运行。

```python
observations = [2, 3, 5, 8]
connections = sum(observations)
print(connections)
```

#text(size: 9pt, fill: muted)[图解使用 CeTZ 0.5.2，代码块使用 Codly 1.3.0。文稿开头的导入语句可以保留，也可以删去。在「扩展包」中发现更多工具。]

#v(2mm)
== 写成你自己的样子

Prose会自动保存你的文字。放心修改，随时撤销，也可以导出源文件，把作品带到别处。一篇文稿可以包含本地样式和插图，在文稿库里仍然是完整的一篇作品。

想进一步了解页面背后的写法，可以阅读 #link("https://typst.app/docs/tutorial/")[Typst 教程]。想看看社区的创意，可以探索 #link("https://typst.app/universe/package/cetz/")[CeTZ] 和 #link("https://typst.app/universe/package/codly/")[Codly].

#v(3mm)
_接下来，你想认真想一想什么？_
