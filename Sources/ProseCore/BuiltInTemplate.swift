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
            ? "prose write typst 用 Typst 写作 welcome start guide tutorial writing math diagram code 欢迎 入门 教程 写作 公式 图解 代码"
            : "blank empty page plain new 空白 页面 新建"
        return query.lowercased().split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            (terms + " " + title.lowercased()).contains($0)
        }
    }
}
