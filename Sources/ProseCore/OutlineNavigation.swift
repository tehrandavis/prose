import Foundation

/// A flattened heading tree. Identity follows the heading's ancestry and title,
/// so inserting prose does not reset folds when LSP offsets change.
public struct OutlineNavigation: Sendable {
    public struct Expansion: Codable, Sendable {
        public var expanded: Set<String>
    }

    public let items: [OutlineItem]
    public let keys: [String]
    public let parents: [Int?]
    public let branches: Set<Int>
    public private(set) var expansion: Expansion

    public init(items: [OutlineItem] = [], expansion: Expansion? = nil, anchor: Int = 0) {
        self.items = items
        var keys: [String] = [], parents: [Int?] = [], stack: [Int] = []
        var occurrences: [String: Int] = [:], branches: Set<Int> = []
        for (index, item) in items.enumerated() {
            while let last = stack.last, items[last].level >= item.level {
                stack.removeLast()
            }
            let parent = stack.last
            parents.append(parent)
            if let parent {
                branches.insert(parent)
            }
            let path = (parent.map { keys[$0] } ?? "") + "/\(item.title.utf8.count):\(item.title)"
            let occurrence = occurrences[path, default: 0]
            occurrences[path] = occurrence + 1
            keys.append(path + "#\(occurrence)")
            stack.append(index)
        }
        self.keys = keys
        self.parents = parents
        self.branches = branches
        if let expansion {
            self.expansion = expansion
        } else {
            // Short documents stay fully visible. Books start at the top level,
            // with only the current section's ancestry opened for orientation.
            var expanded = items.count <= 24 ? Set(branches.map { keys[$0] }) : []
            if items.count > 24, let current = items.lastIndex(where: { $0.offset <= anchor }) {
                var parent = parents[current]
                while let index = parent {
                    expanded.insert(keys[index])
                    parent = parents[index]
                }
            }
            self.expansion = Expansion(expanded: expanded)
        }
    }

    public func index(at offset: Int) -> Int? {
        var low = 0, high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle].offset <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    public func isExpanded(_ index: Int) -> Bool {
        expansion.expanded.contains(keys[index])
    }

    public mutating func toggle(_ index: Int) {
        guard branches.contains(index) else {
            return
        }
        if !expansion.expanded.insert(keys[index]).inserted {
            expansion.expanded.remove(keys[index])
        }
    }

    public mutating func setAll(expanded: Bool) {
        expansion.expanded = expanded ? Set(branches.map { keys[$0] }) : []
    }

    public var visibleIndices: [Int] {
        var visible: [Int] = [], hiddenLevel: Int?
        for index in items.indices {
            if let level = hiddenLevel, items[index].level > level {
                continue
            }
            hiddenLevel = nil
            visible.append(index)
            if branches.contains(index), !isExpanded(index) {
                hiddenLevel = items[index].level
            }
        }
        return visible
    }

    /// The enclosing visible row remains highlighted when its children are folded.
    public func visibleAncestor(of index: Int) -> Int {
        var result = index, parent = parents[index]
        while let next = parent {
            if !isExpanded(next) {
                result = next
            }
            parent = parents[next]
        }
        return result
    }

    /// Evenly sized buckets represent the entire document, not its first headings.
    public func minimapBuckets(limit: Int = 18) -> [Range<Int>] {
        let count = min(max(1, limit), items.count)
        guard count > 0 else {
            return []
        }
        return (0 ..< count).map { ($0 * items.count / count) ..< (($0 + 1) * items.count / count) }
    }
}
