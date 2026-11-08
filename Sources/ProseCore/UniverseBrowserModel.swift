import Combine
import Foundation

@MainActor
public final class UniverseBrowserModel: ObservableObject {
    @Published public private(set) var snapshot: UniverseCatalogSnapshot? {
        didSet { updateResults() }
    }

    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var previewGeneration = 0
    @Published public var query = "" {
        didSet {
            if query != oldValue {
                selectedID = nil
            }
            updateResults()
        }
    }

    @Published public var mode: UniverseDiscoveryMode {
        didSet {
            if mode != oldValue {
                selectedID = nil
            }
            updateResults()
        }
    }

    @Published public var group = "" {
        didSet {
            if group != oldValue {
                selectedID = nil
            }
            updateResults()
        }
    }

    @Published public var selectedID: String?
    private let store: UniverseCatalogStore

    public init(store: UniverseCatalogStore, mode: UniverseDiscoveryMode = .packages) {
        self.store = store
        self.mode = mode
    }

    @Published public private(set) var results: [UniversePackage] = []
    private func updateResults() {
        results = snapshot?.discover(query, mode: mode, group: group) ?? []
        if let selectedID, !results.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    public var selected: UniversePackage? {
        results.first { $0.id == selectedID }
    }

    public func changeMode(_ mode: UniverseDiscoveryMode) {
        self.mode = mode
        group = ""
        selectedID = nil
    }

    public func load(forceRefresh: Bool = false) async {
        guard !isLoading else {
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        if forceRefresh {
            await UniversePreviewLoader.shared.allowRetry()
            previewGeneration += 1
        }
        if snapshot == nil {
            snapshot = await store.cached()
            if snapshot == nil {
                snapshot = await store.bundled()
            }
        }
        do { snapshot = try await store.load(forceRefresh: forceRefresh) }
        catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }

    public var statusText: String {
        if snapshot?.source == .bundled {
            return L10n
                .text(error == nil ? "Browsing the included catalog · Checking for updates…" :
                    "Offline · Browsing the included catalog")
        }
        if let error {
            return error
        }
        guard let snapshot else {
            return L10n.text("Connecting to the catalog…")
        }
        if snapshot.source == .offlineCache {
            return L10n.text("Offline · Browsing the saved catalog")
        }
        return L10n.format("%d results · Search by name or what you want to make", results.count)
    }
}
