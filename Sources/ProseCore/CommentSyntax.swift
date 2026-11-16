import Foundation

/// The text form of a comment (Phase 8 note, decisions 1 and 3): the start
/// marker and the end marker in the text, and one record line per entry in
/// the store at the end of the file.
///
/// ```typst
/// The /*<k3f9x2*/quick brown fox/*k3f9x2>*/ jumps.
///
/// // prose:comments 1
/// // prose:comment k3f9x2 | Tehran Davis | 2026-11-15T14:02:11Z | Is "quick" right?
/// // prose:reply k3f9x2 | Ada Park | 2026-11-15T15:10:40Z | Yes.\nA second paragraph.
/// // prose:resolve k3f9x2 | Tehran Davis | 2026-11-16T10:00:03Z
/// ```
///
/// Pure functions of strings, so every rule is tested without a document.
public enum CommentSyntax {
    /// The characters of an id: no `i`, `l`, `o`, `0` or `1`.
    public static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let idLength = 6
    /// The length of a start marker and of an end marker, in UTF-16 units.
    public static let markerLength = 11
    /// The format version Prose writes and reads in full.
    public static let formatVersion = 1
    /// Prose writes at most this many characters of text per entry.
    public static let maximumTextLength = 4000
    /// Prose writes at most this many replies per comment.
    public static let maximumReplies = 200
    /// An author name holds at most this many characters.
    public static let maximumAuthorLength = 64
    /// Every record line and the header start with this.
    public static let recordPrefix = "// prose:"
    /// The first line of a store.
    public static let header = "// prose:comments \(formatVersion)"

    private static let alphabetUnits = Set(alphabet.compactMap(\.utf16.first))

    // MARK: Ids and markers

    /// Whether `text` is an id: six characters of the alphabet, the first a letter.
    public static func isID(_ text: some StringProtocol) -> Bool {
        let units = Array(text.utf16)
        return units.count == idLength && units.allSatisfy { alphabetUnits.contains($0) } && units[0] >= 0x61
    }

    /// A new id that is not in `used`, made from `generator`.
    public static func newID(avoiding used: Set<String>, using generator: inout some RandomNumberGenerator) -> String {
        let letters = alphabet.filter(\.isLetter)
        while true {
            var id = String(letters[Int.random(in: 0 ..< letters.count, using: &generator)])
            for _ in 1 ..< idLength {
                id.append(alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)])
            }
            if !used.contains(id) {
                return id
            }
        }
    }

    public enum MarkerKind: Equatable, Sendable {
        case start
        case end
    }

    /// `/*<id*/`
    public static func startMarker(_ id: String) -> String {
        "/*<" + id + "*/"
    }

    /// `/*id>*/`
    public static func endMarker(_ id: String) -> String {
        "/*" + id + ">*/"
    }

    /// The kind and id of the marker at `range` of `source`; nil when the
    /// text there is not exactly a start marker or an end marker.
    public static func marker(in source: NSString, at range: NSRange) -> (kind: MarkerKind, id: String)? {
        guard range.length == markerLength, range.location >= 0, NSMaxRange(range) <= source.length else {
            return nil
        }
        var units = [unichar](repeating: 0, count: markerLength)
        source.getCharacters(&units, range: range)
        guard units[0] == 0x2F, units[1] == 0x2A, units[9] == 0x2A, units[10] == 0x2F else { // /* */
            return nil
        }
        let start = units[2] == 0x3C // <
        let end = units[8] == 0x3E // >
        guard start != end else {
            return nil
        }
        let idUnits = start ? units[3 ..< 9] : units[2 ..< 8]
        guard idUnits.allSatisfy({ alphabetUnits.contains($0) }), let first = idUnits.first, first >= 0x61 else {
            return nil
        }
        return (start ? .start : .end, String(utf16CodeUnits: Array(idUnits), count: idLength))
    }

    /// The kind and id of a marker whose first nine characters are at
    /// `location` (`/*<id` or `/*id>`), whatever follows; for a block comment
    /// that lost its `*/`.
    static func markerPrefix(in source: NSString, at location: Int) -> (kind: MarkerKind, id: String)? {
        guard location >= 0, location + 9 <= source.length else {
            return nil
        }
        var units = [unichar](repeating: 0, count: 9)
        source.getCharacters(&units, range: NSRange(location: location, length: 9))
        guard units[0] == 0x2F, units[1] == 0x2A else {
            return nil
        }
        let kind: MarkerKind
        let idUnits: ArraySlice<unichar>
        if units[2] == 0x3C {
            (kind, idUnits) = (.start, units[3 ..< 9])
        } else if units[8] == 0x3E {
            (kind, idUnits) = (.end, units[2 ..< 8])
        } else {
            return nil
        }
        guard idUnits.allSatisfy({ alphabetUnits.contains($0) }), let first = idUnits.first, first >= 0x61 else {
            return nil
        }
        return (kind, String(utf16CodeUnits: Array(idUnits), count: idLength))
    }

    // MARK: Records

    public enum RecordKind: String, Equatable, Sendable, CaseIterable {
        /// The first entry of a comment.
        case comment
        case reply
        /// A resolve event; it has no text.
        case resolve
    }

    /// One record: the first entry, a reply or a resolve event.
    public struct Record: Equatable, Sendable {
        public var kind: RecordKind
        public var id: String
        public var author: String
        /// UTC, ISO 8601, to the second: `2026-11-15T14:02:11Z`.
        public var date: String
        /// The decoded text; empty for a resolve event.
        public var text: String

        public init(kind: RecordKind, id: String, author: String, date: String, text: String = "") {
            self.kind = kind
            self.id = id
            self.author = author
            self.date = date
            self.text = text
        }
    }

    /// What one line comment holds.
    public enum Line: Equatable, Sendable {
        case header(version: Int)
        case record(Record)
        /// It starts with `// prose:` and does not parse.
        case unreadable
    }

    /// The record line of `record`: one line, with the text escaped and its
    /// trailing whitespace trimmed, and the author made valid.
    public static func line(_ record: Record) -> String {
        let author = author(record.author) ?? ""
        var line = recordPrefix + record.kind.rawValue + " " + record.id + " | " + author + " | " + record.date
        if record.kind != .resolve {
            line += " | " + escape(trimmedText(record.text))
        }
        return line
    }

    /// What `line` holds, or nil when it does not start with `// prose:`.
    /// Whitespace at the end of the line is ignored.
    public static func parseLine(_ line: some StringProtocol) -> Line? {
        guard line.hasPrefix(recordPrefix) else {
            return nil
        }
        var rest = Substring(line).dropFirst(recordPrefix.count)
        while let last = rest.last, last == " " || last == "\t" {
            rest.removeLast()
        }
        guard let space = rest.firstIndex(of: " ") else {
            return .unreadable
        }
        let keyword = rest[..<space]
        let fields = rest[rest.index(after: space)...]
        if keyword == "comments" {
            guard !fields.isEmpty, fields.allSatisfy({ $0.isASCII && $0.isNumber }), let version = Int(fields),
                  version >= 1
            else {
                return .unreadable
            }
            return .header(version: version)
        }
        guard let kind = RecordKind(rawValue: String(keyword)) else {
            return .unreadable
        }
        guard let idEnd = fields.range(of: " | "), isID(fields[..<idEnd.lowerBound]) else {
            return .unreadable
        }
        let id = String(fields[..<idEnd.lowerBound])
        let afterID = fields[idEnd.upperBound...]
        guard let authorEnd = afterID.range(of: " | ") else {
            return .unreadable
        }
        let author = String(afterID[..<authorEnd.lowerBound])
        let afterAuthor = afterID[authorEnd.upperBound...]
        let date: Substring, escaped: Substring
        if kind == .resolve {
            (date, escaped) = (afterAuthor, "")
        } else if let dateEnd = afterAuthor.range(of: " | ") {
            (date, escaped) = (afterAuthor[..<dateEnd.lowerBound], afterAuthor[dateEnd.upperBound...])
        } else if afterAuthor.hasSuffix(" |") {
            // An empty text whose last space an editor trimmed.
            (date, escaped) = (afterAuthor.dropLast(2), "")
        } else {
            return .unreadable
        }
        guard isTimestamp(date), let text = unescape(escaped) else {
            return .unreadable
        }
        return .record(Record(kind: kind, id: id, author: author, date: String(date), text: text))
    }

    // MARK: Text

    /// The characters Typst reads as the end of a line comment (fact 3).
    public static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// A UTF-16 unit that is one of `isNewline`'s characters.
    static func isNewline(unit: unichar) -> Bool {
        Unicode.Scalar(unit).map(isNewline) ?? false
    }

    /// The text of a record: a backslash as `\\`, a line feed and CR LF as
    /// `\n`, and every other newline character as `\u{…}`. The result holds
    /// no newline, so it stays on one line.
    public static func escape(_ text: String) -> String {
        var result = ""
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar.value {
            case 0x5C:
                result += "\\\\"
            case 0x0A:
                result += "\\n"
            case 0x0D where pending?.value == 0x0A:
                result += "\\n"
                pending = scalars.next()
            case _ where isNewline(scalar):
                result += "\\u{" + String(scalar.value, radix: 16) + "}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The text `escape` wrote; nil for a backslash before any character
    /// other than `\`, `n` or a valid `u{…}`.
    public static func unescape(_ text: some StringProtocol) -> String? {
        guard text.contains("\\") else {
            return String(text)
        }
        var result = ""
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\\" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.popFirst() {
            case "\\": result += "\\"
            case "n": result += "\n"
            case "u":
                guard scalars.popFirst() == "{", let close = scalars.firstIndex(of: "}") else {
                    return nil
                }
                let digits = String(String.UnicodeScalarView(scalars[..<close]))
                guard (1 ... 6).contains(digits.count), digits.allSatisfy(\.isHexDigit),
                      let value = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(value)
                else {
                    return nil
                }
                result.unicodeScalars.append(decoded)
                scalars = scalars[scalars.index(after: close)...]
            default:
                return nil
            }
        }
        return result
    }

    /// `text` without whitespace and newlines at its end, which many editors
    /// strip from line ends.
    public static func trimmedText(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, last.properties.isWhitespace || isNewline(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    /// A valid author: one line, no bar, whitespace trimmed, at most 64
    /// characters. Newlines become spaces and bars are removed; nil when
    /// nothing is left.
    public static func author(_ name: String) -> String? {
        var cleaned = ""
        for scalar in name.unicodeScalars where scalar != "|" {
            cleaned.unicodeScalars.append(isNewline(scalar) ? " " : scalar)
        }
        let trimmed = String(cleaned.trimmingCharacters(in: .whitespaces).prefix(maximumAuthorLength))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Dates

    /// `date` in UTC, ISO 8601, to the second.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// The date of a timestamp; nil for any other form.
    public static func date(_ timestamp: String) -> Date? {
        guard isTimestamp(timestamp) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    /// Whether `text` has the form `2026-11-15T14:02:11Z`.
    static func isTimestamp(_ text: some StringProtocol) -> Bool {
        let units = Array(text.utf8)
        guard units.count == 20 else {
            return false
        }
        let pattern = Array("dddd-dd-ddTdd:dd:ddZ".utf8)
        return zip(units, pattern).allSatisfy { unit, expected in
            expected == UInt8(ascii: "d") ? (0x30 ... 0x39).contains(unit) : unit == expected
        }
    }
}
