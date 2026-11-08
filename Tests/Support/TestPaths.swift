import Foundation

public enum TestPaths {
    /// Local fixtures live inside the checkout even when Xcode overrides TMPDIR.
    /// Keep the checkout path short: Darwin limits Unix socket paths to 104 bytes.
    public static let temporaryDirectory: URL = {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = checkout.appendingPathComponent("build/test-tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()
}
