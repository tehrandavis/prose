import Foundation

/// The rules for the writer's edits near a comment's markers (Phase 8
/// decision 4). The editor's gate for text changes asks `plan` for every
/// edit the writer makes (typing, Delete, cut, paste over a selection, a
/// drop), but not while text is marked, during undo or redo, for a change
/// from the disk, or for an edit a comment action makes.
///
/// - An edit that removes the start marker and the end marker of a comment
///   also removes that comment's records.
/// - An edit that removes one of the two keeps it at the place of the
///   removal, so the anchor shrinks: a kept end marker goes before the new
///   text and a kept start marker after it, so new text is outside the
///   anchor.
/// - Backspace or Forward Delete directly beside a marker, with no
///   selection, passes over it and removes the next character of text.
/// - Removing all the text between the two, but neither, leaves the comment
///   with an empty anchor: no rule.
///
/// Only markers of attached comments count. A marker the edit only cuts
/// into counts as removed whole, so no marker is ever left broken.
public enum CommentEditRules {
    public struct Plan: Equatable, Sendable {
        /// The edit to make instead, as replacements in the text before it:
        /// sorted, never overlapping or touching. Empty when the edit makes
        /// no change (Backspace at the very start of the text, beside a
        /// marker).
        public let replacements: [TextReplacement]
        /// The selection after the replacements.
        public let selection: NSRange
    }

    /// What to do instead of replacing `range` of `source` with `text`, when
    /// a rule applies; nil when the edit stands. `selection` is the
    /// selection before the edit and `index` the index of `source`.
    public static func plan(
        replacing range: NSRange,
        with text: String,
        selection: NSRange,
        index: CommentIndex,
        source: NSString,
    ) -> Plan? {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else {
            return nil
        }
        let anchors = index.anchors
        let markers = anchors.flatMap { [$0.startMarker, $0.endMarker] }
        guard markers.contains(where: { overlaps($0, range) }) else {
            return nil
        }
        // A single key's deletion lies inside one marker; a longer one (a
        // word, a line) removes the marker and follows the removal rules.
        if text.isEmpty, selection.length == 0, range.length > 0,
           markers.contains(where: { NSIntersectionRange($0, range) == range })
        {
            if NSMaxRange(range) == selection.location, let plan = passBackward(
                from: selection.location,
                markers,
                source,
            ) {
                return plan
            }
            if range.location == selection.location, let plan = passForward(from: selection.location, markers, source) {
                return plan
            }
        }
        return removal(replacing: range, with: text, anchors: anchors, index: index, source: source)
    }

    private static func overlaps(_ marker: NSRange, _ range: NSRange) -> Bool {
        range.length > 0 ? NSIntersectionRange(marker, range).length > 0 :
            marker.location < range.location && range.location < NSMaxRange(marker)
    }

    /// Backspace at `caret`, just after a marker or inside one: the
    /// character before the run of markers goes, and the caret stays on
    /// its side of them.
    private static func passBackward(from caret: Int, _ markers: [NSRange], _ source: NSString) -> Plan? {
        var position = caret
        while let marker = markers.first(where: { $0.location < position && position <= NSMaxRange($0) }) {
            position = marker.location
        }
        guard position < caret else {
            return nil
        }
        guard position > 0 else {
            return Plan(replacements: [], selection: NSRange(location: caret, length: 0))
        }
        let removed = source.rangeOfComposedCharacterSequence(at: position - 1)
        return Plan(
            replacements: [TextReplacement(range: removed, text: "")],
            selection: NSRange(location: caret - removed.length, length: 0),
        )
    }

    /// Forward Delete at `caret`, just before a marker or inside one: the
    /// character after the run of markers goes, and the caret stays.
    private static func passForward(from caret: Int, _ markers: [NSRange], _ source: NSString) -> Plan? {
        var position = caret
        while let marker = markers.first(where: { $0.location <= position && position < NSMaxRange($0) }) {
            position = NSMaxRange(marker)
        }
        guard position > caret else {
            return nil
        }
        guard position < source.length else {
            return Plan(replacements: [], selection: NSRange(location: caret, length: 0))
        }
        let removed = source.rangeOfComposedCharacterSequence(at: position)
        return Plan(
            replacements: [TextReplacement(range: removed, text: "")],
            selection: NSRange(location: caret, length: 0),
        )
    }

    /// An edit that removes markers: removed pairs take their records with
    /// them, and a lone marker stays where the removal was.
    private static func removal(
        replacing range: NSRange,
        with text: String,
        anchors: [CommentIndex.Anchor],
        index: CommentIndex,
        source: NSString,
    ) -> Plan? {
        var lower = range.location, upper = NSMaxRange(range)
        var keptStarts: [NSRange] = [], keptEnds: [NSRange] = [], removed: Set<String> = []
        for anchor in anchors {
            let start = overlaps(anchor.startMarker, range), end = overlaps(anchor.endMarker, range)
            guard start || end else {
                continue
            }
            for (marker, touched) in [(anchor.startMarker, start), (anchor.endMarker, end)] where touched {
                lower = min(lower, marker.location)
                upper = max(upper, NSMaxRange(marker))
            }
            // A marker the new text puts back is moved, not removed.
            let moved = text.contains(CommentSyntax.startMarker(anchor.id)) ||
                text.contains(CommentSyntax.endMarker(anchor.id))
            if start, end {
                if !moved {
                    removed.insert(anchor.id)
                }
            } else if start {
                keptStarts.append(anchor.startMarker)
            } else {
                keptEnds.append(anchor.endMarker)
            }
        }
        let widened = NSRange(location: lower, length: upper - lower)
        let ends = keptEnds.sorted { $0.location < $1.location }.map(source.substring(with:)).joined()
        let starts = keptStarts.sorted { $0.location < $1.location }.map(source.substring(with:)).joined()
        let main = TextReplacement(range: widened, text: ends + text + starts)
        let records = CommentEdits.deleteRecords(of: removed, index: index, source: source)
            .filter { NSIntersectionRange($0.range, widened).length == 0 }
        guard main != TextReplacement(range: range, text: text) || !records.isEmpty else {
            return nil
        }
        let replacements = CommentEdits.normalized([main] + records, source: source)
        // The caret goes after the new text, before any kept start marker.
        var caret = widened.location + (ends as NSString).length + (text as NSString).length
        for record in records where NSMaxRange(record.range) <= widened.location {
            caret += (record.text as NSString).length - record.range.length
        }
        return Plan(replacements: replacements, selection: NSRange(location: caret, length: 0))
    }
}
