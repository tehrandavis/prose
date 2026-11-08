import AppKit
import ProseCore

struct ResourcePasteboard {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    static func containsResources(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { types.contains($0) }
    }

    let inputs: [DocumentResourceInput]
    let kind: DocumentResourceKind

    init?(_ pasteboard: NSPasteboard) {
        // Finder also supplies text containing paths. Files must win over text
        // and over a Finder-generated icon/thumbnail representation.
        let urls = pasteboard.types?.contains(.fileURL) == true ?
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] : nil
        if let urls, !urls.isEmpty {
            inputs = urls.map(DocumentResourceInput.file)
            let extensions = Set(urls.map { $0.pathExtension.lowercased() })
            if extensions.isSubset(of: Set(DocumentResourceKind.bibliography.extensions)) {
                kind = .bibliography
            } else if extensions == ["typ"] {
                kind = .document
            } else {
                kind = .image
            }
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            inputs = [.image(data)]
            kind = .image
        } else {
            return nil
        }
    }
}
