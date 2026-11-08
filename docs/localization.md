# App localization

The public repository and documentation use English. The English product name is **Prose**, with the tagline **Write in Typst**; Simplified Chinese uses **Prose** and **用 Typst 写作**. Brand assets include sharing cards for both languages. The app supports **Follow System**, **English** and **Simplified Chinese**, with immediate switching in Settings. Documents retain their original language and content.

## Native resources

Prose uses Foundation `Bundle.localizedString` and Swift Package Manager resources, with no localization dependency or global `AppleLanguages` override. English is the package's development localization. `Resources/en.lproj/InfoPlist.strings` and `Resources/zh-Hans.lproj/InfoPlist.strings` localize the bundle display name for Finder and system app information using macOS language preferences. App menus, window titles and About use the selected in-app language immediately. The executable, bundle identifier and storage paths remain stable across languages. Resources live in `Sources/ProseCore/Resources/en.lproj` and `zh-Hans.lproj`; the application build includes their generated resource bundle.

English source strings are stable lookup keys. `L10n.text("Save")` resolves the selected language and falls back to the English key when an entry is missing. Use `L10n.format("Version %@", version)` for parameterized messages; translations must preserve format placeholders. Identifiers, paths, package names and user-authored text are not translated.

`AppLanguage.resolve` chooses from supported languages using Foundation's preferred-localization matching. `L10n.setLanguage` stores the explicit app preference and posts `proseLanguageChanged`. `AppLocalization` makes this observable to SwiftUI. Native menus and toolbar labels must refresh on the same notification. Updating language must not replace an editor instance or its document, selection or undo history.

Command titles, descriptions and field labels resolve when read. The search index includes both languages regardless of the selected interface language, so an existing query remains useful after a switch. Generated command examples are cached separately for each language. Inserted placeholders follow the app language; existing document content is never rewritten.

## Adding a language

1. Add an `AppLanguage` case and include it in supported-bundle lookup and system matching.
2. Add a matching `.lproj/Localizable.strings` resource with English keys and translated values.
3. Keep all `%@` placeholders intact, and verify parameter order and punctuation.
4. Exercise Settings, command search, parameters, errors and native menus in the running app.
5. Verify that switching preserves source content, selection and undo, and that missing keys fall back predictably.

Tests cover language matching, bundle loading, fallback, multilingual snippet ranges and a native editing flow that switches language while keeping the same document and cached command objects.

References: [Apple localized resources](https://developer.apple.com/documentation/foundation/localizedstringresource), [localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources), [Bundle string lookup](https://developer.apple.com/documentation/foundation/bundle/localizedstring(forkey:value:table:)).
