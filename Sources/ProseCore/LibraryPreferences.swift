import Foundation

public enum AppAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

/// Only these small UI preferences may leave the device. Paths, document text and logs never enter KVS.
public struct SyncedPreferences: Codable, Equatable, Sendable {
    public var language: String
    public var commandKey: String
    public var fontSize: Double
    public var previewDark: Bool
    public var styledSource: Bool
    public var documentTemplate: String?
    public var historyInterval: String?
    public var appearance: String?

    public init(
        language: String = "system",
        commandKey: String = "j",
        fontSize: Double = 16,
        previewDark: Bool = false,
        styledSource: Bool = true,
        documentTemplate: String? = nil,
        historyInterval: String? = nil,
        appearance: String? = nil,
    ) {
        self.language = language
        self.commandKey = commandKey
        self.fontSize = fontSize
        self.previewDark = previewDark
        self.styledSource = styledSource
        self.documentTemplate = documentTemplate
        self.historyInterval = historyInterval
        self.appearance = appearance
    }

    public var validated: Self {
        Self(
            language: ["system", "en", "zh-Hans"].contains(language) ? language : "system",
            commandKey: ["j", "k"].contains(commandKey) ? commandKey : "j",
            fontSize: fontSize.isFinite ? min(32, max(10, fontSize)) : 16,
            previewDark: previewDark,
            styledSource: styledSource,
            documentTemplate: ["blank", "codeNotes"].contains(documentTemplate ?? "blank") ? documentTemplate : nil,
            historyInterval: historyInterval.flatMap { HistoryInterval(rawValue: $0)?.rawValue },
            appearance: appearance.flatMap { AppAppearance(rawValue: $0)?.rawValue },
        )
    }
}

/// An injectable boundary keeps integration tests entirely outside the user's real iCloud account.
@MainActor
public protocol PreferenceCloudStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func synchronize() -> Bool
}

@MainActor
public final class NativePreferenceCloudStore: PreferenceCloudStore {
    private let store: NSUbiquitousKeyValueStore
    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    public func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    public func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    public func synchronize() -> Bool {
        store.synchronize()
    }
}

public enum PreferenceSyncState: Sendable, Equatable { case local, waiting, active, unavailable, quotaExceeded }

/// Local changes persist immediately. Cloud delivery is asynchronous and is never reported as complete.
@MainActor
public final class LibraryPreferences {
    public static let storageKey = "Prose.preferences.v1"
    public private(set) var values: SyncedPreferences
    public private(set) var syncState: PreferenceSyncState = .local
    public var onChange: ((SyncedPreferences) -> Void)?
    public var onSyncStateChange: ((PreferenceSyncState) -> Void)?
    private let defaults: UserDefaults
    private var cloud: (any PreferenceCloudStore)?
    private let available: () -> Bool
    private var observer: PreferenceObservation?
    private var enabled = false
    private var cloudBase: SyncedPreferences?

    public init(
        defaults: UserDefaults = .standard,
        cloud: (any PreferenceCloudStore)? = nil,
        available: @escaping () -> Bool = LibraryCloudEnvironment.preferenceSyncAvailable,
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.available = available
        if let data = defaults.data(forKey: Self.storageKey), let saved = try? JSONDecoder().decode(
            SyncedPreferences.self,
            from: data,
        ) {
            values = saved.validated
        } else {
            values = SyncedPreferences(
                language: defaults.string(forKey: L10n.preferenceKey) ?? "system",
                commandKey: defaults.string(forKey: "commandKey") ?? "j",
            ).validated
        }
        observer = PreferenceObservation(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let reason = notification
                .userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int ?? NSUbiquitousKeyValueStoreServerChange
            Task { @MainActor [weak self] in self?.receiveCloudChange(reason: reason) }
        })
    }

    public func update(_ value: SyncedPreferences) {
        values = value.validated
        persist()
        if enabled, available(), syncState == .active, let data = try? JSONEncoder().encode(values) {
            cloud?.set(
                data,
                forKey: Self.storageKey,
            )
        }
        onChange?(values)
    }

    public func setSyncEnabled(_ value: Bool) {
        enabled = value
        cloudBase = value ? values : nil
        guard value else {
            changeState(.local)
            return
        }
        guard available() else {
            changeState(.unavailable)
            return
        }
        if cloud == nil {
            cloud = NativePreferenceCloudStore()
        }
        guard cloud?.synchronize() == true else {
            enabled = false
            changeState(.unavailable)
            return
        }
        // Do not upload local defaults before initial cloud reconciliation; they may overwrite another device.
        changeState(.waiting)
        if let data = cloud?.data(forKey: Self.storageKey), let remote = try? JSONDecoder().decode(
            SyncedPreferences.self,
            from: data,
        ) {
            apply(remote)
            changeState(.active)
        }
    }

    public func receiveCloudChange(reason: Int) {
        guard enabled else {
            return
        }
        guard reason != NSUbiquitousKeyValueStoreQuotaViolationChange else {
            changeState(.quotaExceeded)
            return
        }
        guard reason != NSUbiquitousKeyValueStoreAccountChange,
              available()
        else {
            enabled = false
            changeState(.unavailable)
            return
        }
        if let data = cloud?.data(forKey: Self.storageKey), let remote = try? JSONDecoder().decode(
            SyncedPreferences.self,
            from: data,
        ) {
            apply(remote)
        } else if reason == NSUbiquitousKeyValueStoreInitialSyncChange, let data = try? JSONEncoder().encode(values) {
            cloud?.set(data, forKey: Self.storageKey)
            cloudBase = values
        }
        changeState(.active)
    }

    private func apply(_ preferences: SyncedPreferences) {
        let remote = preferences.validated
        let base = cloudBase ?? values
        // Merge independent settings against the last observed cloud snapshot.
        // Explicit local choices win same-field races; initial defaults do not.
        func merge<Value: Equatable>(_ key: KeyPath<SyncedPreferences, Value>) -> Value {
            values[keyPath: key] == base[keyPath: key] ? remote[keyPath: key] : values[keyPath: key]
        }
        values = SyncedPreferences(
            language: merge(\.language),
            commandKey: merge(\.commandKey),
            fontSize: merge(\.fontSize),
            previewDark: merge(\.previewDark),
            styledSource: merge(\.styledSource),
            documentTemplate: merge(\.documentTemplate),
            historyInterval: merge(\.historyInterval),
            appearance: merge(\.appearance),
        )
        cloudBase = remote
        persist()
        onChange?(values)
        if values != remote, let data = try? JSONEncoder().encode(values) {
            cloud?.set(data, forKey: Self.storageKey)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.storageKey)
        }
        defaults.set(values.language, forKey: L10n.preferenceKey)
        defaults.set(values.commandKey, forKey: "commandKey")
    }

    private func changeState(_ state: PreferenceSyncState) {
        syncState = state
        onSyncStateChange?(state)
    }
}

/// NotificationCenter removal is thread-safe; the immutable token needs no actor isolation.
private final class PreferenceObservation: @unchecked Sendable {
    let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
