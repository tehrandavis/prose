import AppKit
import Foundation

/// Drawing-only colours for a TextKit 2 view. NSTextLayoutManager rendering
/// attributes are slow to read back and pay for every run after a changed
/// one, so a mirror of the whole document answers the styler's reads and
/// only changed spans are pushed. The mirror follows each character edit the
/// way TextKit moves rendering attributes: inserted text has none.
///
/// `.spellingState` is drawn too: TextKit 2 draws the system's spelling
/// underline for it as a rendering attribute (Phase 4, step F). Spelling is
/// not a syntax colour, so `removeAll()` keeps it unless asked not to.
@MainActor
public final class RenderingAttributes {
    private static let drawn: [NSAttributedString.Key] = [.foregroundColor, .backgroundColor, .spellingState]
    /// More separate changes than this are cheaper as one ordered rebuild.
    private static let rebuildThreshold = 256
    private let manager: NSTextLayoutManager
    private var mirror = NSMutableAttributedString()
    private var changes: [NSRange] = []
    private var rebuild = false

    /// The open block's colours (Phase 6 decision 8): over `range`, words
    /// draw in `text`, markers in `faint`, and code keeps the semantic
    /// colours. Outside it every character draws its semantic colour.
    public struct Overlay: Equatable {
        public var range: NSRange
        public var markers: [NSRange]
        public var code: [NSRange]
        public var text: PlatformColor
        public var faint: PlatformColor

        public init(range: NSRange, markers: [NSRange], code: [NSRange], text: PlatformColor, faint: PlatformColor) {
            self.range = range
            self.markers = markers
            self.code = code
            self.text = text
            self.faint = faint
        }
    }

    public private(set) var overlay: Overlay?
    /// The semantic colours under `overlay.range`, as `setColors` last set
    /// them, so the block gets them back when it closes.
    private var underlay = NSMutableAttributedString()
    /// Every range a drawn attribute was written to, for tests (off unless
    /// `logsWrites`).
    public var logsWrites = false
    public private(set) var writeLog: [NSRange] = []

    public func resetWriteLog() {
        writeLog = []
    }

    public init(manager: NSTextLayoutManager, length: Int) {
        self.manager = manager
        mirror = NSMutableAttributedString(string: String(repeating: " ", count: length))
    }

    public func value(_ key: NSAttributedString.Key, at index: Int, effectiveRange: inout NSRange) -> Any? {
        guard index < mirror.length else {
            effectiveRange = NSRange(location: index, length: 0)
            return nil
        }
        return mirror.attribute(key, at: index, effectiveRange: &effectiveRange)
    }

    public func set(_ key: NSAttributedString.Key, value: Any?, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= mirror.length else {
            return
        }
        if let value {
            mirror.addAttribute(key, value: value, range: range)
        } else {
            mirror.removeAttribute(key, range: range)
        }
        if Self.drawn.contains(key) {
            if logsWrites {
                writeLog.append(range)
            }
            changes.append(range)
            rebuild = rebuild || changes.count > Self.rebuildThreshold
        }
    }

    /// Replaces the drawn syntax colours with `runs`, which may nest (later
    /// runs win). Only spans that differ from what is drawn are written, so an
    /// identical reply writes nothing. Over the open block's `overlay` the
    /// runs are kept for when it closes, and the overlay's colours are drawn,
    /// in the same comparison.
    public func setColors(_ runs: [(range: NSRange, color: PlatformColor)]) {
        let whole = NSRange(location: 0, length: mirror.length)
        let desired = NSMutableAttributedString(string: String(repeating: " ", count: whole.length))
        for run in runs where run.range.location >= 0 && run.range.length > 0 && NSMaxRange(run.range) <= whole.length {
            desired.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        if let overlay {
            underlay = NSMutableAttributedString(attributedString: desired.attributedSubstring(from: overlay.range))
            paint(overlay, into: desired, at: 0)
        }
        for (range, value) in differences(desired, at: 0, in: whole) {
            set(.foregroundColor, value: value, range: range)
        }
        commit()
    }

    /// Draws the open block's colours over `overlay.range`, or none. Writes
    /// only inside the range of the overlay it replaces (which gets its
    /// semantic colours back) and the new one's. Call `commit()` after.
    public func setOverlay(_ overlay: Overlay?) {
        let whole = NSRange(location: 0, length: mirror.length)
        let overlay = overlay.flatMap { overlay -> Overlay? in
            NSMaxRange(overlay.range) <= whole.length && overlay.range.length > 0 ? overlay : nil
        }
        guard overlay != self.overlay else {
            return
        }
        if let old = self.overlay, NSMaxRange(old.range) <= whole.length, underlay.length == old.range.length {
            for (range, value) in differences(underlay, at: old.range.location, in: old.range) {
                set(.foregroundColor, value: value, range: range)
            }
        }
        self.overlay = overlay
        guard let overlay else {
            underlay = NSMutableAttributedString()
            return
        }
        // The mirror holds the semantic colours everywhere outside an overlay.
        underlay = NSMutableAttributedString(string: String(repeating: " ", count: overlay.range.length))
        mirror.enumerateAttribute(.foregroundColor, in: overlay.range) { value, span, _ in
            if let value {
                underlay.addAttribute(
                    .foregroundColor,
                    value: value,
                    range: NSRange(location: span.location - overlay.range.location, length: span.length),
                )
            }
        }
        let desired = NSMutableAttributedString(attributedString: underlay)
        paint(overlay, into: desired, at: overlay.range.location)
        for (range, value) in differences(desired, at: overlay.range.location, in: overlay.range) {
            set(.foregroundColor, value: value, range: range)
        }
    }

    /// The overlay's colours in `desired`, which starts at document offset
    /// `origin`: text over the range, faint over markers, and the semantic
    /// colours `desired` already holds over code.
    private func paint(_ overlay: Overlay, into desired: NSMutableAttributedString, at origin: Int) {
        let semantic = NSAttributedString(attributedString: desired)
        func local(_ range: NSRange) -> NSRange? {
            let piece = NSIntersectionRange(range, overlay.range)
            return piece.length > 0 ? NSRange(location: piece.location - origin, length: piece.length) : nil
        }
        if let all = local(overlay.range) {
            desired.addAttribute(.foregroundColor, value: overlay.text, range: all)
        }
        for marker in overlay.markers {
            if let range = local(marker) {
                desired.addAttribute(.foregroundColor, value: overlay.faint, range: range)
            }
        }
        for code in overlay.code {
            guard let range = local(code) else {
                continue
            }
            desired.removeAttribute(.foregroundColor, range: range)
            semantic.enumerateAttribute(.foregroundColor, in: range) { value, span, _ in
                if let value {
                    desired.addAttribute(.foregroundColor, value: value, range: span)
                }
            }
        }
    }

    /// The spans of `range` (document offsets) where `desired`, which starts
    /// at offset `origin`, differs from the mirror's colours, with the
    /// colour to write.
    private func differences(_ desired: NSAttributedString, at origin: Int, in range: NSRange) -> [(NSRange, Any?)] {
        var changes: [(NSRange, Any?)] = []
        let local = NSRange(location: range.location - origin, length: range.length)
        desired.enumerateAttribute(.foregroundColor, in: local) { value, span, _ in
            var cursor = span.location + origin
            let end = NSMaxRange(span) + origin
            while cursor < end {
                var current = NSRange()
                let drawn = mirror.attribute(.foregroundColor, at: cursor, effectiveRange: &current)
                let next = min(end, NSMaxRange(current))
                guard next > cursor else {
                    break
                }
                if (drawn as? NSObject)?.isEqual(value) != true, drawn != nil || value != nil {
                    changes.append((NSRange(location: cursor, length: next - cursor), value))
                }
                cursor = next
            }
        }
        return changes
    }

    /// Makes `.spellingState` with `value` cover exactly `misspellings`
    /// inside `range`, and nothing else there. Only spans that differ from
    /// what is drawn are written, so the same misspellings again write
    /// nothing. Call `commit()` after.
    public func setSpelling(_ misspellings: [NSRange], in range: NSRange, value: Int) {
        let whole = NSRange(location: 0, length: mirror.length)
        let range = NSIntersectionRange(range, whole)
        guard range.length > 0 else {
            return
        }
        let desired = NSMutableAttributedString(string: String(repeating: " ", count: range.length))
        for misspelling in misspellings {
            let piece = NSIntersectionRange(misspelling, range)
            if piece.length > 0 {
                desired.addAttribute(
                    .spellingState,
                    value: value,
                    range: NSRange(location: piece.location - range.location, length: piece.length),
                )
            }
        }
        var changes: [(NSRange, Any?)] = []
        desired.enumerateAttribute(.spellingState, in: NSRange(location: 0, length: range.length)) { wanted, span, _ in
            var cursor = range.location + span.location
            let end = range.location + NSMaxRange(span)
            while cursor < end {
                var current = NSRange()
                let drawn = mirror.attribute(.spellingState, at: cursor, effectiveRange: &current)
                let next = min(end, NSMaxRange(current))
                guard next > cursor else {
                    break
                }
                if (drawn as? NSObject)?.isEqual(wanted) != true, drawn != nil || wanted != nil {
                    changes.append((NSRange(location: cursor, length: next - cursor), wanted))
                }
                cursor = next
            }
        }
        for (span, wanted) in changes {
            set(.spellingState, value: wanted, range: span)
        }
    }

    /// Number of UTF-16 units the mirror covers (the text length).
    public var length: Int {
        mirror.length
    }

    /// Clears every drawn attribute; the spelling state stays, drawn again,
    /// unless `keepingSpelling` is false (the text was replaced).
    public func removeAll(keepingSpelling: Bool = true) {
        let whole = NSRange(location: 0, length: mirror.length)
        let kept = NSMutableAttributedString(string: String(repeating: " ", count: mirror.length))
        if keepingSpelling {
            mirror.enumerateAttribute(.spellingState, in: whole) { value, span, _ in
                if let value {
                    kept.addAttribute(.spellingState, value: value, range: span)
                }
            }
        }
        mirror = kept
        changes = []
        rebuild = false
        manager.setRenderingAttributes([:], for: manager.documentRange)
        if keepingSpelling, let overlay {
            // The same text: the open block keeps its colours, over no
            // semantic ones until they are set again.
            underlay = NSMutableAttributedString(string: String(repeating: " ", count: overlay.range.length))
            paint(overlay, into: mirror, at: 0)
        } else {
            overlay = nil
            underlay = NSMutableAttributedString()
        }
        if keepingSpelling {
            push(whole, clear: false)
        }
    }

    public func replaceCharacters(in range: NSRange, length: Int) {
        guard NSMaxRange(range) <= mirror.length else {
            return
        }
        mirror.replaceCharacters(in: range, with: NSAttributedString(string: String(repeating: " ", count: length)))
        guard var overlay else {
            return
        }
        // The overlay moves with the text; its markers and code are stale
        // until the editor sets it again.
        let delta = length - range.length
        let old = overlay.range
        overlay.range = OpenBlockStyle.rebase(old, editing: range, delta: delta)
        overlay.markers = overlay.markers.map { SourceStyling.rebase($0, editing: range, delta: delta) }
        overlay.code = overlay.code.map { SourceStyling.rebase($0, editing: range, delta: delta) }
        if range.location >= old.location, NSMaxRange(range) <= NSMaxRange(old), underlay.length == old.length {
            underlay.replaceCharacters(
                in: NSRange(location: range.location - old.location, length: range.length),
                with: NSAttributedString(string: String(repeating: " ", count: length)),
            )
        } else {
            // An edit across the block's edge: its semantic colours come
            // back with the next reply.
            underlay = NSMutableAttributedString(string: String(repeating: " ", count: overlay.range.length))
        }
        self.overlay = overlay.range.length > 0 ? overlay : nil
    }

    public func commit() {
        defer { changes = []
            rebuild = false
        }
        if rebuild {
            // Clearing is one operation; appending runs in order never shifts
            // existing ones. Deleting or inserting runs one by one in a book
            // costs O(runs) each (3 s for 100,000 removals in War and Peace).
            manager.setRenderingAttributes([:], for: manager.documentRange)
            push(NSRange(location: 0, length: mirror.length), clear: false)
            return
        }
        // Later spans first, so earlier writes never shift runs still to come.
        for range in merged(changes).reversed() {
            push(range, clear: true)
        }
    }

    private func push(_ range: NSRange, clear: Bool) {
        guard range.length > 0, let start = TextKit2Geometry.location(range.location, in: manager),
              let whole = TextKit2Geometry.textRange(range, in: manager)
        else {
            return
        }
        if clear {
            for key in Self.drawn {
                manager.removeRenderingAttribute(key, for: whole)
            }
        }
        var cursor = start, cursorOffset = range.location
        mirror.enumerateAttributes(in: range) { attributes, span, _ in
            let values = Self.drawn.compactMap { key in attributes[key].map { (key, $0) } }
            guard !values.isEmpty,
                  let from = manager.location(cursor, offsetBy: span.location - cursorOffset),
                  let to = manager.location(from, offsetBy: span.length),
                  let textRange = NSTextRange(location: from, end: to)
            else {
                return
            }
            for (key, value) in values {
                manager.addRenderingAttribute(key, value: value, for: textRange)
            }
            cursor = to
            cursorOffset = NSMaxRange(span)
        }
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
