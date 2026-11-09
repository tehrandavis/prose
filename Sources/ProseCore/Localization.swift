import Foundation

/// Prose is English only. Interface text goes through `en.lproj/Localizable.strings`, whose keys are the
/// English text itself, so a label can be reworded in one place without changing its call sites.
public enum L10n {
    private static let bundle: Bundle? = {
        // SwiftPM's native builder lowercases locale directories; the Xcode
        // builder preserves their spelling. Bundle lookup is case-sensitive.
        let identifier = CoreResources.bundle.localizations.first {
            $0.caseInsensitiveCompare("en") == .orderedSame
        } ?? "en"
        return CoreResources.bundle.path(forResource: identifier, ofType: "lproj").flatMap(Bundle.init(path:))
    }()

    private static let locale = Locale(identifier: "en")

    public static func text(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
