import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DocumentResourceKind: Sendable {
    case image
    case bibliography
    case document
    case module

    public var extensions: [String] {
        switch self {
        case .image: ["png", "jpg", "jpeg", "gif", "svg", "pdf", "webp"]
        case .bibliography: ["bib", "yaml", "yml"]
        case .document, .module: ["typ"]
        }
    }
}

public enum DocumentResourceInput: Sendable {
    case file(URL)
    case image(Data)
}

public struct DocumentResource: Identifiable, Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let name: String
    public var id: String {
        relativePath
    }

    public init(url: URL, relativeTo document: URL, name: String? = nil) {
        let base = document.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let common = zip(base, target).prefix { $0 == $1 }.count
        let path = Array(repeating: "..", count: base.count - common) + target.dropFirst(common)
        self.url = url
        relativePath = path.joined(separator: "/")
        self.name = name ?? url.lastPathComponent
    }
}

public enum DocumentResourceError: LocalizedError {
    case unsupported
    case invalidLocation
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            L10n
                .text(
                    "Choose an image, a bibliography file, or a Typst document. Audio and video cannot be embedded in a typeset page.",
                )
        case .invalidLocation:
            L10n.text("This document's resources are unavailable. Reopen the document and try again.")
        case .invalidImage:
            L10n.text("This image could not be read. Choose another image.")
        }
    }
}

/// Imported resources belong to the document project, so moving, syncing and
/// exporting the project preserves them. Unique folders never overwrite a file.
public actor DocumentResourceStore {
    private let manager = FileManager.default

    public init() {}

    public func list(kind: DocumentResourceKind, in root: URL, relativeTo document: URL) throws -> [DocumentResource] {
        let root = try validatedRoot(root, document: document)
        guard let files = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else {
            return []
        }
        var resources: [DocumentResource] = []
        for case let url as URL in files {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if properties.isSymbolicLink == true {
                continue
            }
            guard properties.isRegularFile == true, kind.extensions.contains(url.pathExtension.lowercased()),
                  url != document.resolvingSymlinksInPath().standardizedFileURL
            else {
                continue
            }
            resources.append(DocumentResource(url: url, relativeTo: document))
        }
        return resources.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public func importResources(
        _ inputs: [DocumentResourceInput],
        kind: DocumentResourceKind,
        in root: URL,
        relativeTo document: URL,
    ) throws -> [DocumentResource] {
        guard !inputs.isEmpty else {
            return []
        }
        let root = try validatedRoot(root, document: document)
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        // Foundation can drop a directory URL's trailing slash while resolving
        // a path that does not exist yet. Compare filesystem paths, not URL hints.
        guard directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents == directory.pathComponents else {
            throw DocumentResourceError.invalidLocation
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let batch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: batch, withIntermediateDirectories: false)
        do {
            return try inputs.enumerated().map { index, input in
                try Task.checkCancellation()
                var name: String
                var data: Data
                switch input {
                case let .file(url):
                    guard url.isFileURL else {
                        throw DocumentResourceError.unsupported
                    }
                    let access = url.startAccessingSecurityScopedResource()
                    defer {
                        if access {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    data = try CoordinatedFileAccess.read(url) { source in
                        let properties = try source.resourceValues(forKeys: [.isRegularFileKey])
                        guard properties.isRegularFile == true else {
                            throw DocumentResourceError.unsupported
                        }
                        return try Data(contentsOf: source)
                    }
                    name = url.lastPathComponent
                    if !kind.extensions.contains(url.pathExtension.lowercased()) {
                        guard kind == .image,
                              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                        else {
                            throw DocumentResourceError.unsupported
                        }
                        data = try png(data)
                        name = url.deletingPathExtension().lastPathComponent + ".png"
                    }
                case let .image(image):
                    guard kind == .image else {
                        throw DocumentResourceError.unsupported
                    }
                    data = try png(image)
                    name = L10n.text("Pasted image") + ".png"
                }
                let itemDirectory = batch.appendingPathComponent(String(index + 1), isDirectory: true)
                try manager.createDirectory(at: itemDirectory, withIntermediateDirectories: false)
                let destination = itemDirectory.appendingPathComponent(name)
                try CoordinatedFileAccess.write(destination) { try data.write(to: $0, options: .atomic) }
                return DocumentResource(url: destination, relativeTo: document, name: name)
            }
        } catch {
            try? manager.removeItem(at: batch)
            throw error
        }
    }

    /// Only call for a new batch that was cancelled before its references entered
    /// the editor. Successful imports stay available to undo/redo and history.
    public func discardImport(_ resources: [DocumentResource]) throws {
        guard let first = resources.first else {
            return
        }
        try manager.removeItem(at: first.url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func validatedRoot(_ root: URL, document: URL) throws -> URL {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard document.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw DocumentResourceError.invalidLocation
        }
        return root
    }

    private func png(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary)
        else {
            throw DocumentResourceError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else {
            throw DocumentResourceError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DocumentResourceError.invalidImage
        }
        return output as Data
    }
}
