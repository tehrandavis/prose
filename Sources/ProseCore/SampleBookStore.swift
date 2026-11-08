import CryptoKit
import Foundation
import ZIPFoundation

public enum SampleBook: String, Sendable {
    case sicp

    public var title: String {
        "Structure and Interpretation of Computer Programs"
    }

    public var sha256: String {
        "4000daf0000ac5b92586fa111e08e6bd10c7f303f022170cdc5704a1fe18bd85"
    }

    public var archiveName: String {
        "sicp-" + sha256.prefix(12) + ".zip"
    }

    public var downloadURL: URL {
        guard let base =
            URL(string: "https://raw.githubusercontent.com/tehrandavis/prose/main/Examples/Books/SICP/")
        else {
            preconditionFailure("Invalid sample book base URL")
        }
        return base.appendingPathComponent(archiveName)
    }

    public var downloadBytes: Int {
        1_864_400
    }

    public var sourceURL: URL {
        URL(string: "https://github.com/sarabander/sicp")!
    }

    public func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let keywords = "sicp structure interpretation computer programs scheme book example 计算机 程序 构造 解释 范本 书籍"
        return terms.allSatisfy { keywords.contains($0) }
    }
}

public enum SampleBookError: LocalizedError {
    case invalidDownload
    case extractionFailed
    public var errorDescription: String? {
        L10n.text("The example could not be downloaded or verified. Please try again.")
    }
}

/// Only explicitly requested, digest-pinned examples are downloaded. The cached ZIP is
/// immutable; each addition extracts a new staging directory for an independent copy.
public actor SampleBookStore {
    public typealias Transport = @Sendable (URLRequest) async throws -> UniverseHTTPResponse
    private let cacheURL: URL
    private let transport: Transport
    private let manager = FileManager.default

    public init(cacheURL: URL, transport: @escaping Transport = SampleBookStore.download) {
        self.cacheURL = cacheURL
        self.transport = transport
    }

    public func materialize(_ book: SampleBook, in parent: URL) async throws -> UniverseTemplateProject {
        try Task.checkCancellation()
        let archive = cacheURL.appendingPathComponent(book.archiveName)
        if !isVerifiedArchive(archive, book: book) {
            var request = URLRequest(url: book.downloadURL)
            request.timeoutInterval = 60
            let response = try await transport(request)
            try Task.checkCancellation()
            guard response.statusCode == 200,
                  verify(response.data, book: book)
            else {
                throw SampleBookError.invalidDownload
            }
            try manager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
            try response.data.write(to: archive, options: .atomic)
        }
        try Task.checkCancellation()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = parent.appendingPathComponent("Example-" + UUID().uuidString, isDirectory: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? manager.removeItem(at: directory)
            }
        }
        // The archive digest identifies reviewed bytes produced by package-sicp.py.
        // Never extract arbitrary downloaded archives before this verification.
        do {
            try manager.unzipItem(at: archive, to: directory)
        } catch {
            throw SampleBookError.extractionFailed
        }
        try Task.checkCancellation()
        let result = try UniverseTemplateInstaller.validateProject(at: directory, entrypoint: "main.typ")
        succeeded = true
        return result
    }

    private func isVerifiedArchive(_ url: URL, book: SampleBook) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == book.downloadBytes,
              let data = try? Data(contentsOf: url)
        else {
            return false
        }
        return verify(data, book: book)
    }

    private func verify(_ data: Data, book: SampleBook) -> Bool {
        data.count == book.downloadBytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == book
            .sha256
    }

    public static func download(_ request: URLRequest) async throws -> UniverseHTTPResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 8 * 1024 * 1024
        else {
            throw SampleBookError.invalidDownload
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else {
                throw SampleBookError.invalidDownload
            }
            data.append(byte)
        }
        return UniverseHTTPResponse(data: data, statusCode: response.statusCode)
    }
}
