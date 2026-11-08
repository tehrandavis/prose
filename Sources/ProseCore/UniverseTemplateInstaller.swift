import Foundation

public struct UniverseTemplateProject: Sendable {
    public let directoryURL: URL
    public let mainFileURL: URL
}

public enum UniverseTemplateError: LocalizedError {
    case notTemplate
    case incompatible
    case invalidProject
    case projectTooLarge
    public var errorDescription: String? {
        switch self {
        case .notTemplate: L10n.text("This package does not contain a usable document template.")
        case .incompatible: L10n.text("This template needs a newer typesetting engine.")
        case .invalidProject: L10n.text("The template contains an invalid file or entry point.")
        case .projectTooLarge: L10n.text("This template is too large to import.")
        }
    }
}

/// Uses the bundled engine's official package resolver and TOML parser. Package code is not
/// evaluated to scaffold a document. Assets and subdirectories are preserved by initTemplate.
public enum UniverseTemplateInstaller {
    @MainActor
    public static func materialize(
        _ package: UniversePackage,
        using client: TinymistClient,
        in parentDirectory: URL,
        compilerVersion: String = "0.15.1",
    ) async throws -> UniverseTemplateProject {
        guard package.isValid, let template = package.template,
              template.isValid
        else {
            throw UniverseTemplateError.notTemplate
        }
        guard package.isCompatible(with: compilerVersion) else {
            throw UniverseTemplateError.incompatible
        }
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let directory = parentDirectory.appendingPathComponent("Template-" + UUID().uuidString, isDirectory: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? manager.removeItem(at: directory)
            }
        }
        let result = try await client.command("tinymist.doInitTemplate", arguments: [package.reference, directory.path])
        try Task.checkCancellation()
        guard let entry = result["entryPath"].string,
              entry == template.entrypoint
        else {
            throw UniverseTemplateError.invalidProject
        }
        // File enumeration and source validation can be expensive for asset-heavy templates.
        let project = try await Task.detached(priority: .userInitiated) {
            try validateProject(at: directory, entrypoint: entry)
        }.value
        try Task.checkCancellation()
        succeeded = true
        return project
    }

    /// Defense in depth before the managed library copies a downloaded project. No links,
    /// sockets, devices or paths outside the staging directory can become document assets.
    static func validateProject(at directory: URL, entrypoint: String) throws -> UniverseTemplateProject {
        guard UniverseTemplateMetadata.isRelativePath(entrypoint),
              (entrypoint as NSString).pathExtension.lowercased() == "typ"
        else {
            throw UniverseTemplateError.invalidProject
        }
        let manager = FileManager.default
        let requestedDirectory = directory.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let root = try requestedDirectory.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else {
            throw UniverseTemplateError.invalidProject
        }
        // Storage may live behind an ancestor link (for example, on an external
        // disk). Resolve that location after rejecting a linked project root;
        // every entry inside the project still has to be a real file/directory.
        let directory = requestedDirectory.resolvingSymlinksInPath()
        var enumerationFailed = false
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            errorHandler: { _, _ in enumerationFailed = true
                return false
            },
        ) else {
            throw UniverseTemplateError.invalidProject
        }
        var count = 0, bytes = 0
        for case let file as URL in enumerator {
            count += 1
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true,
                  file.standardizedFileURL.path.hasPrefix(directory.path + "/")
            else {
                throw UniverseTemplateError.invalidProject
            }
            bytes += values.fileSize ?? 0
            guard count <= 10000, bytes <= 128 * 1024 * 1024 else {
                throw UniverseTemplateError.projectTooLarge
            }
        }
        guard !enumerationFailed else {
            throw UniverseTemplateError.invalidProject
        }
        let main = directory.appendingPathComponent(entrypoint)
        guard try main.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            throw UniverseTemplateError.invalidProject
        }
        _ = try DocumentStorage.read(main)
        return UniverseTemplateProject(directoryURL: directory, mainFileURL: main)
    }
}
