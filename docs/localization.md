# App localization

Prose is English only (decided 2026-11-09, Phase 4 step A). The product name is **Prose**, with the tagline **Write in Typst**. The interface has no language setting. LeftBlank's Simplified Chinese interface, its language picker, its Chinese welcome guide and its bundled Noto Sans SC font were removed. Documents can still contain any language: Typst's font fallback finds CJK and other scripts among the macOS system fonts, in Writing mode, in the preview and in exported PDFs.

## Native resources

Interface text goes through `L10n` and Foundation `Bundle.localizedString`, with no localization dependency or global `AppleLanguages` override. English is the package's development localization and its only localization. `Resources/en.lproj/InfoPlist.strings` holds the bundle display name for Finder and system app information. `Sources/ProseCore/Resources/en.lproj/Localizable.strings` holds the interface strings; the application build includes its generated resource bundle.

English source strings are the lookup keys, and today every value equals its key. `L10n.text("Save")` looks the key up in `en.lproj` and falls back to the key when an entry is missing. Use `L10n.format("Version %@", version)` for parameterized messages. The lookup stays so that a label can be reworded in one place without changing its call sites. Identifiers, paths, package names and user-authored text are never looked up.

Command search, Universe discovery, the template gallery and the sample book search match English titles, keywords and descriptions. Spell check follows the system's spelling language, as in other Mac apps.

Preferences saved by earlier builds may still contain a `language` field; it is ignored when they load.

Tests cover English lookup, missing-key fallback, insertion placeholders and English command search.

References: [Apple localized resources](https://developer.apple.com/documentation/foundation/localizedstringresource), [localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources), [Bundle string lookup](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:)).
