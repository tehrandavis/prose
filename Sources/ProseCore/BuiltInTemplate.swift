import Foundation

/// Small, offline starting points are available even without a Universe index.
public enum BuiltInTemplate: String, CaseIterable, Identifiable, Sendable {
    case welcome
    case blank
    public var id: String {
        rawValue
    }

    public var title: String {
        L10n.text(self == .welcome ? "Write in Typst" : "Blank page")
    }

    public var source: String {
        self == .welcome ? WelcomeDocument.source() : DocumentTemplate.blank.source
    }

    public func matches(_ query: String) -> Bool {
        let terms = self == .welcome
            ? "prose write typst welcome start guide tutorial writing math diagram code"
            : "blank empty page plain new"
        return query.lowercased().split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            (terms + " " + title.lowercased()).contains($0)
        }
    }
}
