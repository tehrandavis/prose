import Foundation

/// The bundled guide that a new "Welcome" document starts from.
public enum WelcomeDocument {
    public static func source() -> String {
        guard let url = CoreResources.bundle.url(forResource: "Welcome", withExtension: "typ"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return DocumentTemplate.blank.source
        }
        return source
    }

    public static var thumbnailURL: URL? {
        CoreResources.bundle.url(forResource: "welcome-cover", withExtension: "png")
    }

    public static let markFilename = "prose-mark.png"

    public static func assets() throws -> [String: Data] {
        guard let url = CoreResources.bundle.url(forResource: "prose-mark", withExtension: "png") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try [markFilename: Data(contentsOf: url)]
    }

    /// First-launch drafts and exported project copies use an ordinary relative asset.
    /// An existing author-edited mark always wins over the bundled original.
    public static func prepareAssets(in directory: URL) throws {
        for (name, data) in try assets() {
            let destination = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .withoutOverwriting)
            }
        }
    }
}
