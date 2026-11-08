@testable import ProseCore
import Testing

@Test func outlineDefaultsRevealCurrentAncestorsAndKeepDuplicateHeadingIdentity() {
    let items = (0 ..< 10).flatMap { chapter in
        [OutlineItem(title: "Chapter \(chapter)", level: 1, offset: chapter * 100),
         OutlineItem(title: "Examples", level: 2, offset: chapter * 100 + 10),
         OutlineItem(title: "Examples", level: 2, offset: chapter * 100 + 20)]
    }
    var tree = OutlineNavigation(items: items, anchor: 520)
    #expect(Set(tree.keys).count == items.count)
    #expect(tree.visibleIndices.count == 12)
    #expect(tree.visibleIndices.contains(17))
    #expect(tree.index(at: 520) == 17)
    #expect(tree.index(at: -1) == nil)
    tree.toggle(15)
    #expect(tree.visibleAncestor(of: 17) == 15)
    tree.setAll(expanded: true)
    #expect(tree.visibleIndices.count == 30)
    tree.setAll(expanded: false)
    #expect(tree.visibleIndices.count == 10)
    #expect(OutlineNavigation(items: Array(items.prefix(6))).visibleIndices.count == 6)
    #expect(OutlineNavigation().minimapBuckets().isEmpty)
}
