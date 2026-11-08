import Foundation
import Security

public enum LibraryCloudState: String, Sendable {
    case local
    case waitingForDownload
    case uploading
    case waitingForUpload
    case uploaded
    case conflict
}

public enum LibraryCloudEnvironment {
    public static let containerIdentifier = "iCloud.com.tehrandavis.prose"

    /// Read only the running process's code-signing entitlements; no account credentials are accessed.
    public static func signedEntitlements() -> [String: Any] {
        #if os(macOS)
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(
                      staticCode,
                      SecCSFlags(rawValue: kSecCSSigningInformation),
                      &information,
                  ) ==
                  errSecSuccess,
                  let dictionary = information as? [String: Any]
            else {
                return [:]
            }
            return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        #else
            [:]
        #endif
    }

    public static func containerURL(identifier: String = containerIdentifier) throws -> URL {
        #if os(macOS)
            let entitlements = signedEntitlements()
            let containers = entitlements["com.apple.developer.ubiquity-container-identifiers"] as? [String] ?? []
            guard containers.contains(identifier) else {
                throw LibraryError.cloudNotConfigured
            }
        #endif
        guard FileManager.default.ubiquityIdentityToken != nil else {
            throw LibraryError.cloudAccountUnavailable
        }
        guard let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        else {
            throw LibraryError.cloudUnavailable
        }
        return url
    }

    public static func preferenceSyncAvailable() -> Bool {
        #if os(macOS)
            let value = signedEntitlements()["com.apple.developer.ubiquity-kvstore-identifier"] as? String
            return value?.isEmpty == false && FileManager.default.ubiquityIdentityToken != nil
        #else
            (try? containerURL()) != nil
        #endif
    }

    public static func state(of url: URL) -> LibraryCloudState {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                             .ubiquitousItemIsUploadingKey,
                                                             .ubiquitousItemIsUploadedKey,
                                                             .ubiquitousItemHasUnresolvedConflictsKey]),
            values.isUbiquitousItem == true
        else {
            return .local
        }
        if values.ubiquitousItemHasUnresolvedConflicts == true {
            return .conflict
        }
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return .waitingForDownload
        }
        if values.ubiquitousItemIsUploading == true {
            return .uploading
        }
        return values.ubiquitousItemIsUploaded == true ? .uploaded : .waitingForUpload
    }

    public static func requestDownloadIfNeeded(_ url: URL) throws {
        if state(of: url) == .waitingForDownload {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw LibraryError.downloadPending
        }
    }
}

/// Account changes never switch libraries implicitly. The caller keeps its open buffer/recovery data.
public final class LibraryAccountMonitor: @unchecked Sendable {
    private let token: any NSObjectProtocol
    public init(onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default
            .addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: nil) { _ in onChange() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

/// The query discovers remote placeholders that are not yet visible to a directory enumeration.
/// NSMetadataQuery notifications and result access are serialized on the main operation queue.
public final class LibraryCloudQuery: @unchecked Sendable {
    private let query: NSMetadataQuery
    private let rootURL: URL
    private let onChange: @Sendable () -> Void
    private var tokens: [any NSObjectProtocol] = []

    @MainActor
    public init(rootURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.rootURL = rootURL.standardizedFileURL
        self.onChange = onChange
        query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value: true)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            tokens
                .append(NotificationCenter.default
                    .addObserver(forName: name, object: query, queue: .main) { [weak self] _ in self?.update() })
        }
        query.start()
    }

    deinit {
        query.stop()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func update() {
        query.disableUpdates()
        let urls = query.results
            .compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL }
            .filter { $0.standardizedFileURL.path.hasPrefix(rootURL.path + "/") }
        query.enableUpdates()
        // Only source and metadata are prefetched for searching. Large assets remain on demand.
        Task.detached(priority: .utility) { [onChange] in
            for url in urls where url.lastPathComponent == "document.json" || url.pathExtension == "typ" {
                try? LibraryCloudEnvironment.requestDownloadIfNeeded(url)
            }
            onChange()
        }
    }
}
