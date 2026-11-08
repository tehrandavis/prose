import Foundation

public actor UniversePreviewLoader {
    public static let shared = UniversePreviewLoader()
    private struct Request {
        let task: Task<Void, Never>
        var readers: [UUID: CheckedContinuation<Data?, Never>]
    }

    private let transport: UniverseCatalogStore.Transport?
    private var sessions: [URL: URLSession] = [:]
    private var inflight: [URL: Request] = [:]
    private var failures: [URL: Date] = [:]

    public init(transport: UniverseCatalogStore.Transport? = nil) {
        self.transport = transport
    }

    public func allowRetry() {
        failures.removeAll()
    }

    public func data(for url: URL, cacheURL: URL) async -> Data? {
        guard url.scheme == "https", url.host == "packages.typst.org",
              url.path.hasPrefix("/preview/thumbnails/")
        else {
            return nil
        }
        if let failed = failures[url], Date().timeIntervalSince(failed) < 300 {
            return nil
        }
        let reader = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if inflight[url] != nil {
                    inflight[url]?.readers[reader] = continuation
                } else {
                    let task = Task {
                        let data = await fetch(url, cacheURL: cacheURL)
                        finish(url, data: data)
                    }
                    inflight[url] = Request(task: task, readers: [reader: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(reader, url: url) }
        }
    }

    private func cancel(_ reader: UUID, url: URL) {
        guard var request = inflight[url] else {
            return
        }
        request.readers.removeValue(forKey: reader)?.resume(returning: nil)
        if request.readers.isEmpty {
            inflight.removeValue(forKey: url)
            request.task.cancel()
        } else {
            inflight[url] = request
        }
    }

    private func finish(_ url: URL, data: Data?) {
        // A canceled offscreen request must not finish a newer request for the same URL.
        guard !Task.isCancelled, let request = inflight.removeValue(forKey: url) else {
            return
        }
        if data == nil {
            if failures.count >= 256 {
                failures = failures.filter { Date().timeIntervalSince($0.value) < 300 }
            }
            failures[url] = Date()
        }
        for reader in request.readers.values {
            reader.resume(returning: data)
        }
    }

    private func fetch(_ url: URL, cacheURL: URL) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        do {
            if let transport {
                let response = try await transport(request)
                return response.statusCode == 200 && response.data.count <= 5 * 1024 * 1024 ? response.data : nil
            }
            let session: URLSession
            if let existing = sessions[cacheURL] {
                session = existing
            } else {
                // A normal session honors the disk cache across app launches.
                // Ephemeral sessions can keep the same responses only in memory.
                let configuration = URLSessionConfiguration.default
                configuration.urlCache = URLCache(
                    memoryCapacity: 4 * 1024 * 1024,
                    diskCapacity: 48 * 1024 * 1024,
                    directory: cacheURL,
                )
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .returnCacheDataElseLoad
                configuration.httpMaximumConnectionsPerHost = 4
                configuration.timeoutIntervalForRequest = 12
                configuration.timeoutIntervalForResource = 20
                session = URLSession(configuration: configuration)
                if sessions.count >= 4, let oldest = sessions.keys.first {
                    sessions.removeValue(forKey: oldest)?.finishTasksAndInvalidate()
                }
                sessions[cacheURL] = session
            }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= 5 * 1024 * 1024
            else {
                return nil
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard data.count < 5 * 1024 * 1024 else {
                    return nil
                }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}
