import CoreText
import Darwin
import Foundation
import ProseCore

@MainActor
final class EmbeddedTinymist: TinymistTransport {
    private let incoming = Pipe()
    private let outgoing = Pipe()
    private var started = false
    private(set) var isRunning = false
    var onExit: (@MainActor (Int32) -> Void)?
    var input: FileHandle {
        incoming.fileHandleForWriting
    }

    var output: FileHandle {
        outgoing.fileHandleForReading
    }

    var errorOutput: FileHandle? {
        nil
    }

    func start(root: URL) throws {
        guard !started else {
            throw ServiceError.disconnected
        }
        let readFD = dup(incoming.fileHandleForReading.fileDescriptor)
        let writeFD = dup(outgoing.fileHandleForWriting.fileDescriptor)
        guard readFD >= 0, writeFD >= 0 else {
            if readFD >= 0 {
                Darwin.close(readFD)
            }
            if writeFD >= 0 {
                Darwin.close(writeFD)
            }
            throw POSIXError(.EMFILE)
        }
        // The worker may still write while the reader closes during a document switch.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        started = true
        isRunning = true
        try? incoming.fileHandleForReading.close()
        try? outgoing.fileHandleForWriting.close()
        // The blocking LSP loop exchanges work with Rust's default-priority threads.
        // UI requests use asynchronous continuations; the main thread never joins this worker.
        DispatchQueue.global(qos: .default).async(qos: .default, flags: .enforceQoS) { [weak self] in
            let fonts = Self.fontDirectory()
            let status = fonts.path.withCString { prose_tinymist_run(readFD, writeFD, $0) }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                isRunning = false
                onExit?(status)
            }
        }
    }

    func stop() {
        isRunning = false
        // Closing the input delivers EOF to the in-process worker. The Rust
        // bridge owns its duplicated descriptors and drains/shuts down itself.
        try? input.close()
        output.readabilityHandler = nil
        try? output.close()
    }

    nonisolated static var fontCacheURL: URL {
        AppDistribution.defaultStateDirectory.appendingPathComponent("Fonts")
    }

    private nonisolated static func fontDirectory() -> URL {
        // CoreText exposes readable font file URLs on iPadOS. Cache those same
        // system fonts so Tinymist can resolve New York / PingFang as on Mac.
        let directory = fontCacheURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(
            CTFontCollectionCreateFromAvailableFonts(nil),
        ) as? [CTFontDescriptor] ?? []
        let urls = Set(descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL
        })
        for url in urls {
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }
        return directory
    }
}
