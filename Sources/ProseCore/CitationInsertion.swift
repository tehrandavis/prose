import Foundation

/// The text the citation picker inserts (citations note, decision 4), and the
/// checks around it. Pure functions of the source, so the rules are tested
/// without a window.
public enum CitationInsertion {
    /// The citation of `key`: `@key`, or `@key[supplement]` with a page or
    /// section exactly as typed. A key Typst's `@` syntax cannot hold (a
    /// space, a slash, a trailing `.` or `:`) is cited as
    /// `#cite(label("key"))`, with the supplement as content.
    public static func citation(_ key: String, supplement: String? = nil) -> String {
        let supplement = supplement.flatMap { $0.isEmpty ? nil : $0 }
        if isReferenceKey(key) {
            return "@\(key)" + (supplement.map { "[\($0)]" } ?? "")
        }
        let quoted = "\"" + key.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return "#cite(label(\(quoted))" + (supplement.map { ", supplement: [\($0)]" } ?? "") + ")"
    }

    /// Whether `@key` parses as one reference to `key`: Typst reads letters,
    /// digits, `_`, `-`, `.` and `:` after `@`, and drops a trailing `.` or `:`.
    public static func isReferenceKey(_ key: String) -> Bool {
        guard let last = key.last, last != ".", last != ":" else {
            return false
        }
        return key.allSatisfy { isKeyCharacter($0) }
    }

    /// The text to insert at `location` of `source` to cite `key`: the
    /// citation, after a space when the caret follows a letter, a digit or an
    /// existing citation with no space between, and before a space when the
    /// next character would join the citation (a letter, a digit, `_`, `-` or
    /// `[`, which would read as a supplement).
    public static func text(
        citing key: String,
        in source: NSString,
        at location: Int,
        supplement: String? = nil,
    ) -> String {
        let citation = citation(key, supplement: supplement)
        var before = ""
        if location > 0, location <= source.length {
            let previous = source.rangeOfComposedCharacterSequence(at: location - 1)
            let character = Character(source.substring(with: previous))
            if character.isLetter || character.isNumber || followsCitation(source, at: location) {
                before = " "
            }
        }
        var after = ""
        if location < source.length {
            let next = Character(source.substring(with: source.rangeOfComposedCharacterSequence(at: location)))
            if next.isLetter || next.isNumber || "_-[".contains(next) {
                after = " "
            }
        }
        return before + citation + after
    }

    /// Whether the text just before `location` ends a citation: `@key` or
    /// `@key[...]`. An `@` after a letter or digit is part of an address, not
    /// a citation.
    public static func followsCitation(_ source: NSString, at location: Int) -> Bool {
        var cursor = location
        if cursor > 0, source.character(at: cursor - 1) == 0x5D { // ]
            var depth = 0
            while cursor > 0 {
                cursor -= 1
                let unit = source.character(at: cursor)
                if unit == 0x5D {
                    depth += 1
                } else if unit == 0x5B {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                } else if unit == 0x0A, depth > 0, cursor > 0, source.character(at: cursor - 1) == 0x0A {
                    return false
                }
            }
            guard depth == 0 else {
                return false
            }
        }
        let end = cursor
        while cursor > 0 {
            let range = source.rangeOfComposedCharacterSequence(at: cursor - 1)
            guard isKeyCharacter(Character(source.substring(with: range))) else {
                break
            }
            cursor = range.location
        }
        guard cursor < end, cursor > 0, source.character(at: cursor - 1) == 0x40 else { // @
            return false
        }
        guard cursor - 1 > 0 else {
            return true
        }
        let before = Character(source.substring(with: source.rangeOfComposedCharacterSequence(at: cursor - 2)))
        return !(before.isLetter || before.isNumber)
    }

    /// Whether an edit may have changed a `#bibliography(...)` call or the
    /// files it names: the edited line, before or after, mentions
    /// `bibliography` or a bibliography file extension. `old` is the text
    /// before `change`, whose range is in `old`.
    public static func mayChangeBibliography(_ old: NSString, _ change: TextReplacement) -> Bool {
        guard change.range.location >= 0, NSMaxRange(change.range) <= old.length else {
            return true
        }
        let line = old.lineRange(for: change.range)
        let prefix = old.substring(with: NSRange(
            location: line.location,
            length: change.range.location - line.location,
        ))
        let suffix = old.substring(with: NSRange(
            location: NSMaxRange(change.range),
            length: NSMaxRange(line) - NSMaxRange(change.range),
        ))
        let before = old.substring(with: line)
        let after = prefix + change.text + suffix
        return [before, after].contains { text in
            ["bibliography", ".bib", ".yml", ".yaml"].contains { text.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_-.:".contains(character)
    }
}

public extension BibliographyEntry {
    /// The first author's family name, with "et al." when there are more:
    /// "Smith", "Smith et al."; empty when the entry names no one.
    var leadAuthor: String {
        guard let first = authors.first else {
            return ""
        }
        return authors.count > 1 ? first.family + " " + L10n.text("et al.") : first.family
    }
}

public extension BibliographyContents {
    /// One short line per file whose entries could not all be read, for the
    /// picker: "refs.bib: 1 entry could not be read, line 42". Problems of a
    /// file that is not linked and lists no entry from a `.yml` or `.yaml`
    /// file are left out: without a `#bibliography` call every YAML file in
    /// the project is read, and most are not bibliographies.
    var problemSummaries: [String] {
        var order: [String] = []
        var byFile: [String: [BibliographyIssue]] = [:]
        for issue in errors {
            if let file = files.first(where: { $0.path == issue.file }), !file.linked, file.entries == 0,
               ["yml", "yaml"].contains((issue.file as NSString).pathExtension.lowercased())
            {
                continue
            }
            if byFile[issue.file] == nil {
                order.append(issue.file)
            }
            byFile[issue.file, default: []].append(issue)
        }
        return order.map { file in
            let issues = byFile[file] ?? []
            let lines = issues.map(\.line).filter { $0 > 0 }
            guard !lines.isEmpty else {
                return "\(file): \(issues.first?.message ?? L10n.text("could not be read"))"
            }
            let count = issues.count == 1 ? L10n.text("1 entry could not be read") :
                L10n.format("%@ entries could not be read", String(issues.count))
            let shown = lines.prefix(3).map(String.init).joined(separator: ", ")
            let place = lines.count == 1 ? L10n.format("line %@", shown) :
                L10n.format("lines %@", shown + (lines.count > 3 ? "…" : ""))
            return "\(file): \(count), \(place)"
        }
    }
}
