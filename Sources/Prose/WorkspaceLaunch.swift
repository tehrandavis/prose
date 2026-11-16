import Foundation
import ProseCore

/// Settings › General › "When Prose opens" (Phase 7, decision 1).
enum LaunchPage: String, CaseIterable {
    case blankPage
    case lastDocument
}

/// "When Prose opens", default Blank page. It is kept in this Mac's user
/// defaults, not in the synced preferences: like the recovery snapshot and
/// `blank-page.json` it reads, it belongs to the Mac rather than to the writing.
enum LaunchPreference {
    static let key = "launchPage"

    static func value(in defaults: UserDefaults = .standard) -> LaunchPage {
        defaults.string(forKey: key).flatMap(LaunchPage.init(rawValue:)) ?? .blankPage
    }

    static func set(_ page: LaunchPage, in defaults: UserDefaults = .standard) {
        defaults.set(page.rawValue, forKey: key)
    }
}

/// What launch shows (Phase 7, decision 1): a blank page, unless the recovery
/// snapshot holds unsaved work, this is the first launch (the Welcome guide),
/// or the setting is "Last document".
extension Workspace {
    /// The workspace the app launches with. `init` restores the snapshot when
    /// the setting or unsaved work asks for it; otherwise it waits with an
    /// empty page that cannot be typed in until `launch()` opens a blank page.
    static func launching(stateDirectory: URL? = nil, defaults: UserDefaults = .standard) -> Workspace {
        let workspace = Workspace(
            stateDirectory: stateDirectory,
            opening: LaunchPreference.value(in: defaults),
            defaults: defaults,
        )
        workspace.launchStartedAt = .now
        return workspace
    }

    /// Starts the library, then opens the blank page if launch is waiting for
    /// one. When the library cannot start (iCloud failed to resume) or cannot
    /// give a blank page, the window shows the home state with the error.
    func launch() async {
        let waiting = launchPending
        if !waiting {
            recordLaunchReady(waited: false)
        }
        await library.start()
        guard waiting, launchPending else {
            return
        }
        if library.isStarted {
            await showBlankPage()
        } else {
            recordOperation("library.blankPageUnavailable", ["error": library.error ?? ""])
            showLibraryHome()
            if let error = library.error {
                showMessage(error, persistent: true)
            }
        }
        recordLaunchReady(waited: true)
    }

    /// Records the time from the workspace's creation, the first thing the
    /// app does, to an editable page (or the home state).
    private func recordLaunchReady(waited: Bool) {
        guard let start = launchStartedAt else {
            return
        }
        launchStartedAt = nil
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 +
            Double(elapsed.components.attoseconds) / 1e15
        recordOperation("launch.ready", [
            "ms": String(format: "%.0f", milliseconds),
            "waitedForLibrary": String(waited),
            "blankPage": String(managedDocumentID.map(library.isUntouchedBlankPage) ?? false),
            "home": String(isLibraryHome),
        ])
    }
}
