import Foundation

/// Display-only ranges in the bounded history excerpts. Full documents never
/// enter a quadratic diff. Character detail has a separate, smaller work budget.
struct HistoryHighlights {
    var removed: [NSRange] = []
    var added: [NSRange] = []

    init(before: String, after: String) {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        func offsets(_ lines: [String]) -> [Int] {
            var result = [0]
            var offset = 0
            for line in lines {
                offset += line.utf16.count + 1
                result.append(offset)
            }
            return result
        }
        let oldOffsets = offsets(old), newOffsets = offsets(new)
        func lineRange(_ index: Int, _ offsets: [Int], _ length: Int) -> NSRange {
            NSRange(location: offsets[index], length: min(offsets[index + 1], length) - offsets[index])
        }
        let oldLength = before.utf16.count, newLength = after.utf16.count
        // For many short lines, show the changed span rather than spending an
        // unbounded amount of time finding the smallest possible edit script.
        guard old.count + new.count <= 512 else {
            var prefix = 0, suffix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
                prefix += 1
            }
            while suffix < min(old.count, new.count) - prefix,
                  old[old.count - suffix - 1] == new[new.count - suffix - 1]
            {
                suffix += 1
            }
            removed = (prefix ..< (old.count - suffix)).map { lineRange($0, oldOffsets, oldLength) }
            added = (prefix ..< (new.count - suffix)).map { lineRange($0, newOffsets, newLength) }
            removed = Self.coalesce(removed)
            added = Self.coalesce(added)
            return
        }
        var removedLines = Set<Int>(), addedLines = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removedLines.insert(offset)
            case let .insert(offset, _, _): addedLines.insert(offset)
            }
        }
        var i = 0, j = 0, detailBudget = 8192
        while i < old.count || j < new.count {
            let startOld = i, startNew = j
            while removedLines.contains(i) {
                i += 1
            }
            while addedLines.contains(j) {
                j += 1
            }
            let detailSize = i == startOld + 1 && j == startNew + 1
                ? old[startOld].utf16.count + new[startNew].utf16.count : Int.max
            if detailSize <= min(1024, detailBudget) {
                detailBudget -= detailSize
                let oldCharacters = Array(old[startOld]), newCharacters = Array(new[startNew])
                func characterOffsets(_ characters: [Character], start: Int) -> [Int] {
                    var result = [start]
                    var offset = start
                    for character in characters {
                        offset += String(character).utf16.count
                        result.append(offset)
                    }
                    return result
                }
                let oldPositions = characterOffsets(oldCharacters, start: oldOffsets[startOld])
                let newPositions = characterOffsets(newCharacters, start: newOffsets[startNew])
                for change in newCharacters.difference(from: oldCharacters) {
                    switch change {
                    case let .remove(offset, _, _):
                        removed.append(NSRange(
                            location: oldPositions[offset],
                            length: oldPositions[offset + 1] - oldPositions[offset],
                        ))
                    case let .insert(offset, _, _):
                        added.append(NSRange(
                            location: newPositions[offset],
                            length: newPositions[offset + 1] - newPositions[offset],
                        ))
                    }
                }
            } else {
                removed += (startOld ..< i).map { lineRange($0, oldOffsets, oldLength) }
                added += (startNew ..< j).map { lineRange($0, newOffsets, newLength) }
            }
            // Every unchanged pair is an anchor separating independent edits.
            if i < old.count, j < new.count {
                i += 1
                j += 1
            }
        }
        removed = Self.coalesce(removed)
        added = Self.coalesce(added)
    }

    private static func coalesce(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }
}
