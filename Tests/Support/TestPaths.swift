import Foundation

public enum TestPaths {
    /// Local fixtures live inside the checkout even when Xcode overrides TMPDIR.
    /// Keep the checkout path short: Darwin limits Unix socket paths to 104 bytes.
    public static let temporaryDirectory: URL = {
        #if os(iOS)
            // Device tests can write only inside their application sandbox.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "leftblank-tests",
                isDirectory: true,
            )
        #else
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let root = checkout.appendingPathComponent("build/test-tmp", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()
}
