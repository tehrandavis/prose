import Foundation

/// Distribution identity is compiled into the native apps.
/// Local state stays separate; both distributions can use the shared iCloud library.
public enum AppDistribution: Sendable {
    case standard
    case preview

    public static var current: Self {
        #if PROSE_PREVIEW
            .preview
        #else
            .standard
        #endif
    }

    public var bundleIdentifier: String {
        self == .preview ? "com.tehrandavis.prose.preview" : "com.tehrandavis.prose"
    }

    public var applicationName: String {
        self == .preview ? L10n.text("Prose Preview") : L10n.text("Prose")
    }

    public var stateFolderName: String {
        self == .preview ? "Prose Preview" : "Prose"
    }

    public func stateDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(stateFolderName, isDirectory: true)
    }

    public static var defaultStateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PROSE_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return current.stateDirectory(applicationSupport: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
        )[0])
    }
}
