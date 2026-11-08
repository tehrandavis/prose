import Foundation
@testable import ProseCore
import Testing

@MainActor
private final class PreferenceFixtureCloud: PreferenceCloudStore {
    var values: [String: Data] = [:]
    var writes = 0
    var canSynchronize = true
    func data(forKey key: String) -> Data? {
        values[key]
    }

    func set(_ data: Data, forKey key: String) {
        values[key] = data
        writes += 1
    }

    func synchronize() -> Bool {
        canSynchronize
    }
}

@MainActor
@Test func libraryPreferencesStayLocalUntilOptInAndReconcileInitialCloudData() throws {
    let suite = "Prose.preferences.test." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cloud = PreferenceFixtureCloud()
    let preferences = LibraryPreferences(defaults: defaults, cloud: cloud, available: { true })
    var changes: [SyncedPreferences] = []
    preferences.onChange = { changes.append($0) }
    var local = preferences.values
    local.fontSize = 19
    preferences.update(local)
    #expect(cloud.writes == 0)
    #expect(preferences.syncState == .local)
    #expect(LibraryPreferences(defaults: defaults, cloud: cloud).values.fontSize == 19)
    let remote = SyncedPreferences(
        language: "zh-Hans",
        commandKey: "k",
        fontSize: 22,
        previewDark: true,
        appearance: "dark",
    )
    cloud.values[LibraryPreferences.storageKey] = try JSONEncoder().encode(remote)
    preferences.setSyncEnabled(true)
    #expect(preferences.values == remote)
    #expect(preferences.syncState == .active)
    #expect(cloud.writes == 0)
    var changed = remote
    changed.styledSource = false
    changed.appearance = "light"
    preferences.update(changed)
    #expect(cloud.writes == 1)
    #expect(changes.last == changed)
    #expect(LibraryPreferences(defaults: defaults, cloud: cloud).values.appearance == "light")
    preferences.setSyncEnabled(false)
    preferences.update(local)
    #expect(cloud.writes == 1)
    #expect(preferences.syncState == .local)
}

@MainActor
@Test func libraryPreferenceInitialSyncAccountQuotaAndUnavailableStates() throws {
    let suite = "Prose.preferences.test." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cloud = PreferenceFixtureCloud()
    let preferences = LibraryPreferences(defaults: defaults, cloud: cloud, available: { true })
    var states: [PreferenceSyncState] = []
    preferences.onSyncStateChange = { states.append($0) }
    preferences.setSyncEnabled(true)
    #expect(preferences.syncState == .waiting)
    #expect(cloud.writes == 0)
    preferences.receiveCloudChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
    #expect(cloud.writes == 1)
    #expect(preferences.syncState == .active)
    preferences.receiveCloudChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange)
    #expect(preferences.syncState == .quotaExceeded)
    preferences.receiveCloudChange(reason: NSUbiquitousKeyValueStoreAccountChange)
    #expect(preferences.syncState == .unavailable)
    preferences.update(SyncedPreferences(fontSize: 25))
    #expect(cloud.writes == 1)
    preferences.receiveCloudChange(reason: NSUbiquitousKeyValueStoreServerChange)
    #expect(preferences.values.fontSize == 25)
    cloud.canSynchronize = false
    preferences.setSyncEnabled(true)
    #expect(preferences.syncState == .unavailable)
    let unavailable = LibraryPreferences(defaults: defaults, cloud: cloud, available: { false })
    unavailable.setSyncEnabled(true)
    #expect(unavailable.syncState == .unavailable)
    #expect(unavailable.values.fontSize == 25)
    #expect(states.contains(.waiting))
    #expect(SyncedPreferences(language: "unknown", commandKey: "escape", fontSize: .infinity)
        .validated == SyncedPreferences())
    #expect(SyncedPreferences(fontSize: 50).validated.fontSize == 32)
    #expect(SyncedPreferences(fontSize: 2).validated.fontSize == 10)
    #expect(SyncedPreferences(documentTemplate: "codeNotes").validated.documentTemplate == "codeNotes")
    #expect(SyncedPreferences(documentTemplate: "unknown").validated.documentTemplate == nil)
    let legacy = Data(#"{"language":"en","commandKey":"j","fontSize":16,"previewDark":false,"styledSource":true}"#.utf8)
    #expect(try JSONDecoder().decode(SyncedPreferences.self, from: legacy).documentTemplate == nil)
    #expect(try JSONDecoder().decode(SyncedPreferences.self, from: legacy).appearance == nil)
    #expect(SyncedPreferences(appearance: "unknown").validated.appearance == nil)
    #expect(SyncedPreferences(appearance: "system").validated.appearance == "system")
}

@MainActor
@Test func libraryPreferencesMergeEditsMadeDuringInitialDownloadAndIndependentRemoteChanges() throws {
    let suite = "Prose.preferences.test." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cloud = PreferenceFixtureCloud()
    let preferences = LibraryPreferences(defaults: defaults, cloud: cloud, available: { true })
    preferences.setSyncEnabled(true)
    var local = preferences.values
    local.fontSize = 20
    local.appearance = "light"
    preferences.update(local)
    #expect(cloud.writes == 0, "Do not upload defaults before initial cloud reconciliation")
    var remote = SyncedPreferences(previewDark: true, appearance: "dark")
    cloud.values[LibraryPreferences.storageKey] = try JSONEncoder().encode(remote)
    preferences.receiveCloudChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
    #expect(preferences.values.fontSize == 20)
    #expect(preferences.values.appearance == "light")
    #expect(preferences.values.previewDark)
    remote.styledSource = false
    cloud.values[LibraryPreferences.storageKey] = try JSONEncoder().encode(remote)
    preferences.receiveCloudChange(reason: NSUbiquitousKeyValueStoreServerChange)
    #expect(preferences.values.fontSize == 20)
    #expect(preferences.values.appearance == "light")
    #expect(!preferences.values.styledSource)
    #expect(preferences.values.previewDark)
}
