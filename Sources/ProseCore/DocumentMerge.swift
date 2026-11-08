import Foundation

/// A conservative three-way merge for independently edited paragraphs. Changes
/// touching the same source range remain a conflict; neither side is discarded.
public enum DocumentMerge {
    public struct Result: Sendable {
        public let text: String
        public let selection: NSRange
    }

    private struct Change {
        let range: NSRange
        let text: String
    }

    public static func merge(base: String, local: String, remote: String, selection: NSRange) -> Result? {
        if local == remote || remote == base {
            return Result(text: local, selection: selection)
        }
        let localChanges = changes(from: base, to: local)
        let remoteChanges = changes(from: base, to: remote)
        var additions: [Change] = []
        for remote in remoteChanges {
            if localChanges.contains(where: { $0.range == remote.range && $0.text == remote.text }) {
                continue
            }
            guard !localChanges.contains(where: { overlap($0.range, remote.range) }) else {
                return nil
            }
            let shift = localChanges.filter { NSMaxRange($0.range) <= remote.range.location }
                .reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
            additions.append(Change(
                range: NSRange(location: remote.range.location + shift, length: remote.range.length),
                text: remote.text,
            ))
        }
        var text = local
        var start = selection.location, end = NSMaxRange(selection)
        for change in additions.sorted(by: { $0.range.location > $1.range.location }) {
            text = (text as NSString).replacingCharacters(in: change.range, with: change.text)
            start = moved(start, through: change)
            end = moved(end, through: change)
        }
        return Result(
            text: text,
            selection: NSRange(
                location: min(start, text.utf16.count),
                length: max(0, min(end, text.utf16.count) - start),
            ),
        )
    }

    private static func moved(_ offset: Int, through change: Change) -> Int {
        if offset < change.range.location {
            return offset
        }
        if offset >= NSMaxRange(change.range) {
            return offset + change.text.utf16.count - change.range.length
        }
        return change.range.location + min(offset - change.range.location, change.text.utf16.count)
    }

    private static func overlap(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 || b.length == 0 {
            return a.location <= NSMaxRange(b) && b.location <= NSMaxRange(a)
        }
        return NSIntersectionRange(a, b).length > 0
    }

    private static func lines(_ text: String) -> [String] {
        let source = text as NSString
        var result: [String] = [], offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            result.append(source.substring(with: range))
            offset = NSMaxRange(range)
        }
        return result
    }

    private static func changes(from base: String, to edited: String) -> [Change] {
        let original = lines(base), replacement = lines(edited)
        let diff = replacement.difference(from: original)
        var removed = Set<Int>(), inserted: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, element, _): inserted[offset] = element
            }
        }
        var old = 0, new = 0, utf16 = 0, result: [Change] = []
        while old < original.count || new < replacement.count {
            if removed.contains(old) || inserted[new] != nil {
                let start = utf16
                var deleted: [String] = [], added: [String] = []
                while removed
                    .contains(old)
                {
                    deleted.append(original[old])
                    utf16 += original[old].utf16.count
                    old += 1
                }
                while let line = inserted[new] {
                    added.append(line)
                    new += 1
                }
                // Adjacent line replacements can include an identical edit made
                // on both devices. Keep their boundaries so it is deduplicated.
                if deleted.count == added.count {
                    var offset = start
                    for (before, after) in zip(deleted, added) {
                        result.append(Change(range: NSRange(location: offset, length: before.utf16.count), text: after))
                        offset += before.utf16.count
                    }
                } else {
                    result.append(Change(range: NSRange(location: start, length: utf16 - start), text: added.joined()))
                }
            } else {
                guard old < original.count, new < replacement.count else {
                    break
                }
                utf16 += original[old].utf16.count
                old += 1
                new += 1
            }
        }
        return result
    }
}
