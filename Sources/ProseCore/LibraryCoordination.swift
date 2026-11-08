import Foundation

/// Keeps baseline comparison and replacement in one coordinated write transaction.
public enum CoordinatedFileAccess {
    public static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw CocoaError(.fileReadUnknown)
        }
        return try result.get()
    }

    public static func write<T>(
        _ url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        _ body: (URL) throws -> T,
    ) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: options,
            error: &coordinationError,
        ) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try result.get()
    }
}

/// Retain while a library is open and call stop() before release or root replacement.
/// Callbacks arrive on a serial background queue.
public final class LibraryFileMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void
    private let registrationLock = NSLock()
    private var registered = true

    public init(rootURL: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = rootURL
        self.onChange = onChange
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.qualityOfService = .utility
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    public func stop() {
        registrationLock.withLock {
            guard registered else {
                return
            }
            registered = false
            NSFileCoordinator.removeFilePresenter(self)
        }
    }

    public func presentedItemDidChange() {
        onChange()
    }

    public func presentedSubitemDidChange(at url: URL) {
        onChange()
    }

    public func presentedSubitemDidAppear(at url: URL) {
        onChange()
    }

    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        onChange()
    }

    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: ((any Error)?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}
