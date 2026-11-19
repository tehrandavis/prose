import Foundation

/// Pure helpers for File > Export LaTeX…, which converts one Typst source with
/// the bundled Tylax converter (`t2l`). The result is a draft the writer checks.
public enum LatexExport {
    /// The Tylax release Prose bundles (scripts/build-tylax.sh).
    public static let tylaxVersion = "0.3.8"

    /// Arguments for `t2l`: a full LaTeX document from Typst on standard input.
    public static let arguments = ["-f", "-d", "t2l"]

    /// Tylax drops straight quotes, so every Typst smart quote in markup becomes
    /// its typographic character first. Quotes in math, raw text, strings and
    /// code are not smart-quote nodes and stay as they are. Returns `source`
    /// unchanged when no parser is available.
    public static func typographicQuotes(_ source: String) -> String {
        guard let nodes = SyntaxTree(source)?.nodes() else {
            return source
        }
        let text = source as NSString
        var replacements: [(range: NSRange, character: String)] = []
        for node in nodes where node.kind == .smartQuote && node.range.length == 1 {
            let quote = text.character(at: node.range.location)
            guard quote == 0x27 || quote == 0x22 else {
                continue
            }
            // A quote directly after a converted one sees that conversion, so
            // "'nested' quotes" open twice.
            let before: Character? = if let last = replacements.last,
                                        NSMaxRange(last.range) == node.range.location
            {
                last.character.first
            } else {
                character(before: node.range.location, in: text)
            }
            let opens = opensQuote(after: before)
            let character = quote == 0x27 ? (opens ? "\u{2018}" : "\u{2019}") : (opens ? "\u{201C}" : "\u{201D}")
            replacements.append((node.range, character))
        }
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.character)
        }
        return result as String
    }

    /// A quote opens at the start of text or after whitespace, an opening
    /// bracket, a dash or an opening quote; otherwise it closes. An apostrophe
    /// after a letter or digit therefore always closes.
    static func opensQuote(after before: Character?) -> Bool {
        guard let before else {
            return true
        }
        return before.isWhitespace || "([{-\u{2013}\u{2014}\u{2018}\u{201C}".contains(before)
    }

    private static func character(before location: Int, in text: NSString) -> Character? {
        guard location > 0 else {
            return nil
        }
        let range = text.rangeOfComposedCharacterSequence(at: location - 1)
        return text.substring(with: range).first
    }

    /// Tylax's warnings from its standard error: the lines after
    /// "Conversion Warnings (N):", with terminal colour codes removed.
    public static func warnings(fromStandardError output: String) -> [String] {
        var lines = withoutColourCodes(output).components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.contains("Conversion Warnings") }) else {
            return []
        }
        lines.removeSubrange(...start)
        return lines.compactMap { line in
            var warning = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "• ", "* "] where warning.hasPrefix(bullet) {
                warning = String(warning.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            }
            return warning.isEmpty ? nil : warning
        }
    }

    static func withoutColourCodes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// The LaTeX comment lines written before Tylax's output.
    public static func header(warnings: [String]) -> String {
        var lines = [
            "% " + L10n.format(
                "Draft exported from Prose with Tylax %@. Check it before use.",
                tylaxVersion,
            ),
        ]
        lines += warnings.map { "% warning: " + $0.replacingOccurrences(of: "\n", with: " ") }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Whether the source includes or imports a local file, which Tylax does
    /// not follow. Package imports (`@preview/…`) do not count.
    public static func referencesLocalFiles(_ source: String) -> Bool {
        source.range(
            of: #"#(include|import)\s*"(?!@)"#,
            options: .regularExpression,
        ) != nil
    }

    /// The bundled converter, or in development and tests the one built by
    /// scripts/build-tylax.sh. `PROSE_T2L` overrides both.
    public static var converterURL: URL? {
        if let override = ProcessInfo.processInfo.environment["PROSE_T2L"],
           FileManager.default.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/t2l"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tools/t2l"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Converts `source` with `converter` and returns the LaTeX with its draft
    /// header, and Tylax's warnings. Blocks until the converter exits: call it
    /// off the main actor. `directory` is the converter's working directory,
    /// the folder of the exported document.
    public static func convert(
        _ source: String,
        converter: URL,
        directory: URL,
    ) throws -> (latex: String, warnings: [String]) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("prose-latex-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Files, not pipes, carry the three streams: no stream can fill and
        // stall the converter while another is being read.
        let input = scratch.appendingPathComponent("input.typ")
        let output = scratch.appendingPathComponent("output.tex")
        let errors = scratch.appendingPathComponent("errors.txt")
        try Data(typographicQuotes(source).utf8).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = converter
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        process.waitUntilExit()
        let standardError = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = warnings(fromStandardError: standardError).last
                ?? withoutColourCodes(standardError).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LatexExportError.failed(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
        }
        let latex = try String(contentsOf: output, encoding: .utf8)
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LatexExportError.noOutput
        }
        let found = warnings(fromStandardError: standardError)
        return (header(warnings: found) + latex, found)
    }

    /// The message shown after a successful export.
    public static func summary(fileName: String, warnings: Int, referencesLocalFiles: Bool) -> String {
        var parts = [L10n.format("LaTeX draft exported: %@. Check it before use.", fileName)]
        if warnings == 1 {
            parts.append(L10n.text("Tylax reported 1 warning; it is listed at the top of the file."))
        } else if warnings > 1 {
            parts.append(L10n.format(
                "Tylax reported %@ warnings; they are listed at the top of the file.",
                String(warnings),
            ))
        }
        if referencesLocalFiles {
            parts.append(L10n.text("Included files are not converted."))
        }
        return parts.joined(separator: " ")
    }
}

public enum LatexExportError: LocalizedError, Equatable {
    case missingConverter
    case failed(String)
    case noOutput

    public var errorDescription: String? {
        switch self {
        case .missingConverter: L10n.text("Prose cannot export LaTeX: its converter (t2l) is missing from the app.")
        case let .failed(detail): L10n.format("The LaTeX converter failed: %@", detail)
        case .noOutput: L10n.text("The LaTeX converter produced no output.")
        }
    }
}
