import Foundation
@testable import ProseCore
import ProseTestSupport
import Testing

struct DistributionIsolationTests {
    @Test func previewAndProductionKeepIndependentLocalLibrariesAndPreferences() async throws {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("distribution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stable = DocumentLibrary(rootURL: AppDistribution.standard.stateDirectory(applicationSupport: root)
            .appendingPathComponent("Library"))
        let preview = DocumentLibrary(rootURL: AppDistribution.preview.stateDirectory(applicationSupport: root)
            .appendingPathComponent("Library"))
        let original = try await stable.create(title: "Writing", text: "Keep the original")
        let copy = try await preview.create(title: "Writing", text: "Try an experiment")
        #expect(try await stable.list().map(\.id) == [original.id])
        #expect(try await preview.list().map(\.id) == [copy.id])
        #expect(try await stable.read(original.id).text == "Keep the original")
        #expect(try await preview.read(copy.id).text == "Try an experiment")
        let suffix = ".test." + UUID().uuidString
        let stableDomain = AppDistribution.standard.bundleIdentifier + suffix
        let previewDomain = AppDistribution.preview.bundleIdentifier + suffix
        let stableDefaults = try #require(UserDefaults(suiteName: stableDomain))
        let previewDefaults = try #require(UserDefaults(suiteName: previewDomain))
        defer {
            stableDefaults.removePersistentDomain(forName: stableDomain)
            previewDefaults.removePersistentDomain(forName: previewDomain)
        }
        stableDefaults.set("dark", forKey: "appearance")
        previewDefaults.set("light", forKey: "appearance")
        #expect(stableDefaults.string(forKey: "appearance") == "dark")
        #expect(previewDefaults.string(forKey: "appearance") == "light")
        #expect(L10n.text("Prose Preview") == "Prose Preview")
    }
}
