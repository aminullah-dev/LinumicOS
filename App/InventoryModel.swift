import Foundation
import LinumicCore
import Observation

/// Observable wrapper around the inventory store. Views read and mutate products
/// only through this type, and every mutation is persisted.
@MainActor
@Observable
final class InventoryModel {
    private(set) var products: [Product] = []
    /// Possible products, unresolved repositories and separate organizations found during discovery.
    private(set) var unresolved: [UnresolvedItem] = []
    private(set) var market = MarketIntelligence()
    private(set) var content: [ContentItem] = []
    /// Every repository under oversight ("from 0 to 100"), refreshed read-only from GitHub.
    private(set) var oversight: [OversightRepo] = []
    /// Seed revision of the current data. It has to be saved back, or every launch would look outdated.
    private var seedRevision = 1
    private(set) var isLoaded = false
    var errorMessage: String?
    /// One-time information for the user, e.g. that an older inventory file was archived.
    var notice: String?

    /// State of the read-only GitHub refresh.
    private(set) var isSyncingGitHub = false
    private(set) var lastGitHubSync: (at: Date, report: RepositorySync.Report)?

    /// State of the read-only oversight sweep across every repository.
    private(set) var isSyncingOversight = false
    private(set) var lastOversightSync: (at: Date, report: OversightSync.Report)?

    /// State of the local working-copy scan.
    private(set) var isScanningLocal = false
    var workspacePath: String? { WorkspaceStore.displayPath }
    var hasWorkspace: Bool { WorkspaceStore.hasWorkspace }

    // Oversight automatic sweep + change feed.
    static let autoRefreshOversightKey = "LCCAutoRefreshOversight"
    static let notifyOversightKey = "LCCNotifyOversightChanges"
    private static let lastOversightAutoRefreshKey = "LCCLastOversightAutoRefresh"
    private static let recentOversightChangesKey = "LCCRecentOversightChanges"

    /// Oversight changes noticed on this device, newest first. A per-device convenience in
    /// UserDefaults; the register itself lives in the inventory.
    private(set) var recentOversightChanges: [OversightChange] = {
        guard let data = UserDefaults.standard.data(forKey: recentOversightChangesKey) else { return [] }
        return (try? JSONDecoder().decode([OversightChange].self, from: data)) ?? []
    }()

    private func recordOversight(_ changes: [OversightChange]) async {
        guard !changes.isEmpty else { return }
        recentOversightChanges = Array((changes + recentOversightChanges).prefix(50))
        if let data = try? JSONEncoder().encode(recentOversightChanges) {
            UserDefaults.standard.set(data, forKey: Self.recentOversightChangesKey)
        }
        if UserDefaults.standard.object(forKey: Self.notifyOversightKey) as? Bool ?? true {
            await OversightNotifier.post(changes)
        }
    }

    var hasGitHubToken: Bool { ((try? secrets.read(.gitHubToken)) ?? nil) != nil }

    /// The active store: the local file, or cloud-plus-local-cache when signed in to Supabase.
    private var store: InventoryStore
    private let localStore: InventoryStore
    let secrets: SecretStore
    private var saveTask: Task<Void, Never>?

    // MARK: Cloud (Supabase)
    static let supabaseConfig: SupabaseConfig? = {
        guard let url = (Bundle.main.object(forInfoDictionaryKey: "LCCSupabaseURL") as? String).flatMap(URL.init(string:)),
              let key = Bundle.main.object(forInfoDictionaryKey: "LCCSupabasePublishableKey") as? String, !key.isEmpty
        else { return nil }
        return SupabaseConfig(url: url, publishableKey: key)
    }()
    private let sessionManager: SupabaseSessionManager?
    private var hybrid: HybridInventoryStore?
    private(set) var cloudUser: SupabaseSession?
    private(set) var cloudStatus: HybridInventoryStore.Status?
    private(set) var isSyncing = false
    var isCloudAvailable: Bool { sessionManager != nil }

    init(store: InventoryStore, secrets: SecretStore = KeychainSecretStore()) {
        self.store = store
        self.localStore = store
        self.secrets = secrets
        self.sessionManager = Self.supabaseConfig.map { SupabaseSessionManager(config: $0, secrets: secrets) }
    }

    private func useCloud(_ manager: SupabaseSessionManager, config: SupabaseConfig) {
        let remote = RemoteInventoryStore(config: config, token: { try await manager.accessToken() })
        let base = (try? JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent()) ?? FileManager.default.temporaryDirectory
        let h = HybridInventoryStore(local: localStore, remote: remote, pendingFlag: base.appending(path: "pending-upload"))
        hybrid = h
        store = h
    }

    /// Exchanges Apple's identity token for a Supabase session, then syncs. On first connection the local inventory is uploaded.
    func signInWithApple(idToken: String, rawNonce: String) async {
        guard let sessionManager, let config = Self.supabaseConfig else { return }
        do {
            cloudUser = try await sessionManager.signInWithApple(idToken: idToken, rawNonce: rawNonce)
            useCloud(sessionManager, config: config)
            await syncNow()
        } catch {
            errorMessage = String(localized: "Sign in failed: \(error.localizedDescription)")
        }
    }

    /// Pulls from the server (pushing any pending local edits first) and refreshes the screen.
    func syncNow() async {
        guard let hybrid, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if let inventory = try await hybrid.load() { apply(inventory) }
        } catch {
            errorMessage = String(localized: "Could not load inventory: \(error.localizedDescription)")
        }
        cloudStatus = await hybrid.status
    }

    func signOut() async {
        await sessionManager?.signOut()
        cloudUser = nil
        hybrid = nil
        cloudStatus = nil
        store = localStore
    }

    private(set) var isSyncingAppStore = false
    private(set) var lastAppStoreSync: (at: Date, report: StoreSync.Report)?

    /// Refreshes public App Store data (version, seller, URL) for every App Store listing. No credentials are used.
    func refreshAppStore() async {
        guard !isSyncingAppStore else { return }
        isSyncingAppStore = true
        defer { isSyncingAppStore = false }
        let (updated, report) = await StoreSync.refreshAppStore(products, using: AppStoreLookupClient())
        for product in updated {
            update(product.id) { current in
                for listing in product.storeListings where listing.store == .appStore {
                    if let i = current.storeListings.firstIndex(where: { $0.id == listing.id }) { current.storeListings[i] = listing }
                }
            }
        }
        lastAppStoreSync = (.now, report)
    }

    // MARK: Store changes and automatic refresh

    static let autoRefreshKey = "LCCAutoRefreshStores"
    static let notifyKey = "LCCNotifyStoreChanges"
    static let autoRefreshInterval: TimeInterval = 30 * 60
    private static let recentChangesKey = "LCCRecentStoreChanges"
    private static let lastAutoRefreshKey = "LCCLastStoreAutoRefresh"

    /// Changes noticed by console refreshes on this device, newest first. A per-device convenience,
    /// kept in UserDefaults; the store data itself lives in the inventory.
    private(set) var recentStoreChanges: [StoreChange] = {
        guard let data = UserDefaults.standard.data(forKey: recentChangesKey) else { return [] }
        return (try? JSONDecoder().decode([StoreChange].self, from: data)) ?? []
    }()

    private func record(_ changes: [StoreChange]) async {
        guard !changes.isEmpty else { return }
        recentStoreChanges = Array((changes + recentStoreChanges).prefix(50))
        if let data = try? JSONEncoder().encode(recentStoreChanges) { UserDefaults.standard.set(data, forKey: Self.recentChangesKey) }
        if UserDefaults.standard.object(forKey: Self.notifyKey) as? Bool ?? true { await StoreNotifier.post(changes) }
    }

    /// Refreshes every connected console if automatic refresh is on and the last run is old enough.
    func autoRefreshStoresIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoRefreshKey) as? Bool ?? true, isLoaded else { return }
        let last = defaults.object(forKey: Self.lastAutoRefreshKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= Self.autoRefreshInterval - 60 else { return }
        defaults.set(Date.now, forKey: Self.lastAutoRefreshKey)
        // Public App Store data (ratings) needs no key.
        await refreshAppStore()
        let connected = AppStore.allCases.filter(hasConsoleCredentials)
        guard !connected.isEmpty else { return }
        if defaults.object(forKey: Self.notifyKey) as? Bool ?? true { await StoreNotifier.requestPermission() }
        for store in connected { await refreshFromConsole(store) }
    }

    private(set) var syncingConsoles: Set<AppStore> = []
    private(set) var lastConsoleSync: [AppStore: (at: Date, report: StoreConsoleSync.Report)] = [:]

    func consoleSecretKey(_ store: AppStore) -> SecretKey {
        store == .appStore ? .appStoreConnectKey : .googlePlayServiceAccount
    }

    func hasConsoleCredentials(_ store: AppStore) -> Bool {
        ((try? secrets.read(consoleSecretKey(store))) ?? nil) != nil
    }

    /// Reads versions and review states from App Store Connect or the Play Console, read-only,
    /// with the credentials in the Keychain, and updates only that store's listings.
    func refreshFromConsole(_ store: AppStore) async {
        guard !syncingConsoles.contains(store) else { return }
        syncingConsoles.insert(store)
        defer { syncingConsoles.remove(store) }
        let updated: [Product]
        let report: StoreConsoleSync.Report
        do {
            guard let stored = try secrets.read(consoleSecretKey(store)) else { return }
            switch store {
            case .appStore:
                let credentials = try JSONDecoder().decode(AppStoreConnectCredentials.self, from: Data(stored.utf8))
                (updated, report) = await StoreConsoleSync.refreshAppStoreConnect(products, using: AppStoreConnectClient(credentials: credentials))
            case .googlePlay:
                let credentials = try GooglePlayCredentials(serviceAccountJSON: Data(stored.utf8))
                (updated, report) = await StoreConsoleSync.refreshGooglePlay(products, using: GooglePlayClient(credentials: credentials))
            }
        } catch {
            errorMessage = String(localized: "Could not use the \(store.title) credentials: \(error.localizedDescription)")
            return
        }
        let changes = StoreChangeDetector.changes(before: products, after: updated)
        for product in updated {
            update(product.id) { current in
                for listing in product.storeListings where listing.store == store {
                    if let i = current.storeListings.firstIndex(where: { $0.id == listing.id }) { current.storeListings[i] = listing }
                }
            }
        }
        lastConsoleSync[store] = (.now, report)
        await record(changes)
    }

    /// Refreshes every GitHub repository snapshot, read-only. Without a token only public repositories succeed.
    func refreshGitHub() async {
        guard !isSyncingGitHub else { return }
        isSyncingGitHub = true
        defer { isSyncingGitHub = false }
        let token: String?
        do { token = try secrets.read(.gitHubToken) } catch {
            errorMessage = String(localized: "Could not read the GitHub token from the Keychain: \(error.localizedDescription)")
            return
        }
        let (updated, report) = await RepositorySync.refresh(products, using: GitHubClient(token: token))
        // Apply only the snapshots, in case products changed while the sync was running.
        for product in updated {
            update(product.id) { current in
                for repo in product.repositories {
                    if let i = current.repositories.firstIndex(where: { $0.id == repo.id }), let snap = repo.gitHub {
                        current.repositories[i].gitHub = snap
                    }
                }
            }
        }
        lastGitHubSync = (.now, report)
    }

    /// The GitHub owner used as a public fallback when there is no token. Prefers an owner seen on a
    /// product repository; otherwise the known account.
    private var oversightOwner: String {
        for product in products {
            for repo in product.repositories {
                if let owner = repo.gitHubSlug?.split(separator: "/").first { return String(owner) }
            }
        }
        return "aminullah-dev"
    }

    /// Discovers and refreshes every repository under oversight, read-only. Security posture and
    /// latest-change facts come from GitHub. Existing data is kept if the sweep fails.
    func refreshOversight() async {
        guard !isSyncingOversight else { return }
        isSyncingOversight = true
        defer { isSyncingOversight = false }
        let token: String?
        do { token = try secrets.read(.gitHubToken) } catch {
            errorMessage = String(localized: "Could not read the GitHub token from the Keychain: \(error.localizedDescription)")
            return
        }
        let before = oversight
        let (updated, report) = await OversightSync.refresh(
            oversight, using: GitHubClient(token: token), owner: oversightOwner
        )
        oversight = updated
        lastOversightSync = (.now, report)
        persist()
        await recordOversight(OversightChangeDetector.changes(before: before, after: updated))
    }

    #if os(macOS)
    /// Presents the folder picker, stores the workspace bookmark, then scans it.
    func chooseWorkspace() async {
        guard WorkspaceStore.choose() != nil else { return }
        await refreshLocal()
    }
    #endif

    /// Scans the chosen workspace folder read-only and merges each working copy's status into the
    /// oversight register, matched to a repository by its `origin` remote. A local checkout whose
    /// remote isn't already in the register is added, so local-only repos still appear.
    func refreshLocal() async {
        guard !isScanningLocal else { return }
        isScanningLocal = true
        defer { isScanningLocal = false }
        guard let statuses = await WorkspaceStore.scan() else { return }
        let before = oversight

        var bySlug = Dictionary(uniqueKeysWithValues: oversight.map { ($0.slug, $0) })
        // Clear any stale local status first; a repo removed from the folder shouldn't keep old data.
        for slug in bySlug.keys { bySlug[slug]?.local = nil }

        for status in statuses {
            guard let slug = status.originSlug else { continue }   // only match GitHub-origin checkouts
            if bySlug[slug] != nil {
                bySlug[slug]?.local = status
            } else {
                bySlug[slug] = OversightRepo(slug: slug, local: status)
            }
        }
        oversight = bySlug.values.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
        persist()
        await recordOversight(OversightChangeDetector.changes(before: before, after: oversight))
    }

    /// Runs an oversight sweep (GitHub, plus local if a workspace is set) if the automatic sweep is
    /// on, a token exists, and the last run is old enough. Shares the 30-minute cadence with stores.
    func autoRefreshOversightIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoRefreshOversightKey) as? Bool ?? true, isLoaded, hasGitHubToken else { return }
        let last = defaults.object(forKey: Self.lastOversightAutoRefreshKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= Self.autoRefreshInterval - 60 else { return }
        defaults.set(Date.now, forKey: Self.lastOversightAutoRefreshKey)
        if defaults.object(forKey: Self.notifyOversightKey) as? Bool ?? true { await OversightNotifier.requestPermission() }
        await refreshOversight()
        if hasWorkspace { await refreshLocal() }
    }

    var summary: DashboardSummary { DashboardSummary(products: products) }
    var oversightSummary: OversightSummary { OversightSummary(repos: oversight) }

    func product(id: Product.ID) -> Product? {
        products.first { $0.id == id }
    }

    /// Loads the stored inventory. On first launch it seeds from the verified seed file.
    /// A file from an older schema is archived (never deleted) and replaced by the current seed.
    func load() async {
        if let sessionManager, let config = Self.supabaseConfig, let session = await sessionManager.current {
            cloudUser = session
            useCloud(sessionManager, config: config)
        }
        defer { Task { if let hybrid { cloudStatus = await hybrid.status } } }
        do {
            if let inventory = try await store.load() {
                apply(inventory)
                try await upgradeSeedIfUntouched(inventory)
            } else {
                try seed()
            }
        } catch InventoryStoreError.outdatedSchemaVersion(let version) {
            do {
                let archived = try await store.archive()
                try seed()
                let kept = archived?.path(percentEncoded: false) ?? String(localized: "its original location")
                notice = String(localized: "The inventory was rebuilt from the verified seed (schema \(Inventory.currentSchemaVersion)). The previous schema-\(version) file was kept at \(kept).")
            } catch {
                errorMessage = String(localized: "Could not upgrade inventory: \(error.localizedDescription)")
            }
        } catch {
            errorMessage = String(localized: "Could not load inventory: \(error.localizedDescription)")
        }
        isLoaded = true
    }

    /// The bundled seed gets new owner-confirmed facts over time (`seedRevision`). An inventory
    /// nobody has edited is archived and rebuilt from the newer seed. An edited one is kept,
    /// because edits are never overwritten, and the user is told a newer seed exists.
    private func upgradeSeedIfUntouched(_ stored: Inventory) async throws {
        let bundled = try SeedInventory.load()
        guard stored.seedRevision < bundled.seedRevision else { return }
        if stored.hasUserEdits {
            notice = String(localized: "A newer verified inventory is bundled with this version. Your edits were kept, so it wasn't applied automatically.")
            return
        }
        let archived = try await store.archive()
        apply(bundled)
        persist()
        let kept = archived?.path(percentEncoded: false) ?? String(localized: "its original location")
        notice = String(localized: "The inventory was updated with newly confirmed facts. The previous file was kept at \(kept).")
    }

    private func seed() throws {
        apply(try SeedInventory.load())
        persist()
    }

    private func apply(_ inventory: Inventory) {
        products = inventory.products
        unresolved = inventory.unresolved
        market = inventory.market
        content = inventory.content
        oversight = inventory.oversight
        seedRevision = inventory.seedRevision
    }

    /// Applies a change to market intelligence. It's refused (returns the issues) if it would break the evidence rules.
    @discardableResult
    func updateMarket(_ change: (inout MarketIntelligence) -> Void) -> [String] {
        var next = market
        change(&next)
        let issues = next.issues
        guard issues.isEmpty else { return issues }
        market = next
        persist()
        return []
    }

    func upsertContent(_ item: ContentItem) {
        content.upsert(item)
        persist()
    }

    func deleteContent(_ id: ContentItem.ID) {
        content.removeAll { $0.id == id }
        persist()
    }

    /// Adds a product, or replaces the existing product with the same ID.
    func upsert(_ product: Product) {
        if let index = products.firstIndex(where: { $0.id == product.id }) {
            products[index] = product
        } else {
            products.append(product)
        }
        persist()
    }

    func update(_ id: Product.ID, _ mutate: (inout Product) -> Void) {
        guard let index = products.firstIndex(where: { $0.id == id }) else { return }
        mutate(&products[index])
        persist()
    }

    func delete(_ id: Product.ID) {
        products.removeAll { $0.id == id }
        persist()
    }

    /// Returns a unique product ID for a name, adding a numeric suffix if the slug is taken.
    func newProductID(for name: String) -> String {
        let base = Product.slug(for: name).isEmpty ? "product" : Product.slug(for: name)
        var candidate = base
        var n = 2
        while products.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Saves are chained so they reach the store in the same order as the mutations.
    private func persist() {
        let snapshot = Inventory(seedRevision: seedRevision, products: products, unresolved: unresolved, market: market, content: content, oversight: oversight)
        let previous = saveTask
        saveTask = Task { [store, hybrid] in
            await previous?.value
            do {
                try await store.save(snapshot)
                if let hybrid {
                    let status = await hybrid.status
                    await MainActor.run { self.cloudStatus = status }
                }
            } catch {
                await MainActor.run { self.errorMessage = String(localized: "Could not save inventory: \(error.localizedDescription)") }
            }
        }
    }
}
