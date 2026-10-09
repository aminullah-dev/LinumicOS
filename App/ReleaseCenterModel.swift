import Foundation
import LinumicCore
import Observation

/// Release Center (انتشارها): App Store versions and builds, Google Play tracks, and open PRs and CI of every product
/// repository, plus "Waiting on you". Uses the credentials Settings → Integrations already keeps in the Keychain
/// (`appstoreconnect.key`, `googleplay.serviceaccount`, `github.token`); it never holds a copy of its own.
/// Reads only, except one confirmed action: releasing an App Store version that waits for a manual release.
@MainActor
@Observable
final class ReleaseCenterModel {
    private(set) var snapshot: ReleaseCenterSnapshot
    private(set) var isRefreshing = false
    private(set) var actions: [ReleaseActionRecord] = []
    /// Version ids being released right now (the button shows progress and can't be pressed twice).
    private(set) var releasing: Set<String> = []
    var errorMessage: String?

    static let autoRefreshKey = "LCCAutoRefreshReleases"
    private static let lastAutoRefreshKey = "LCCLastReleasesAutoRefresh"

    private let inventory: InventoryModel
    private let store: ReleaseCenterStore?
    private let log: ReleaseActionLog?

    init(inventory: InventoryModel) {
        self.inventory = inventory
        store = (try? ReleaseCenterStore.defaultFileURL()).map(ReleaseCenterStore.init(fileURL:))
        log = (try? ReleaseActionLog.defaultFileURL()).map(ReleaseActionLog.init(fileURL:))
        snapshot = store?.load() ?? ReleaseCenterSnapshot()
    }

    var waiting: [WaitingItem] { snapshot.waiting }
    var apps: [ReleaseApp] { ReleaseCatalog.apps(from: inventory.products) }
    var repos: [ReleaseRepo] { ReleaseCatalog.repos(from: inventory.products) }

    func load() async {
        actions = (try? await log?.load()) ?? []
    }

    // MARK: Credentials (the existing Keychain items, read when needed)

    private func appStoreClient() throws -> AppStoreConnectClient? {
        guard let stored = try inventory.secrets.read(.appStoreConnectKey) else { return nil }
        let credentials = try JSONDecoder().decode(AppStoreConnectCredentials.self, from: Data(stored.utf8))
        return AppStoreConnectClient(credentials: credentials)
    }

    private func playClient() throws -> GooglePlayClient? {
        guard let stored = try inventory.secrets.read(.googlePlayServiceAccount) else { return nil }
        return GooglePlayClient(credentials: try GooglePlayCredentials(serviceAccountJSON: Data(stored.utf8)))
    }

    var hasAppStoreKey: Bool { inventory.hasConsoleCredentials(.appStore) }
    var hasPlayKey: Bool { inventory.hasConsoleCredentials(.googlePlay) }

    // MARK: Refresh

    /// Reads all three sources. A source without credentials keeps its last data and says why.
    func refresh() async {
        guard !isRefreshing, inventory.isLoaded else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let ios = readAppStore()
        async let android = readPlay()
        async let github = readGitHub()
        let (a, p, g) = await (ios, android, github)
        var s = snapshot
        apply(a, to: &s.appStore, readAt: &s.appStoreReadAt, note: &s.appStoreNote)
        apply(p, to: &s.play, readAt: &s.playReadAt, note: &s.playNote)
        apply(g, to: &s.repos, readAt: &s.gitHubReadAt, note: &s.gitHubNote)
        snapshot = s
        save()
    }

    private enum Read<T: Sendable>: Sendable { case data([T], Date), unavailable(String) }

    private func apply<T: Sendable>(_ read: Read<T>, to list: inout [T], readAt: inout Date?, note: inout String?) {
        switch read {
        case .data(let items, let at):
            list = items
            readAt = at
            note = nil
        case .unavailable(let why):
            note = why   // keep the previous reading, with its own time, and say why it wasn't refreshed
        }
    }

    private func readAppStore() async -> Read<AppStoreAppStatus> {
        let apps = apps.filter { $0.store == .appStore }
        let client: AppStoreConnectClient
        do {
            guard let c = try appStoreClient() else {
                return .unavailable(String(localized: "No App Store Connect key. Add it in Settings → Integrations."))
            }
            client = c
        } catch { return .unavailable(String(localized: "The App Store Connect key can't be used: \(error.localizedDescription)")) }
        let now = Date.now
        var out: [AppStoreAppStatus] = []
        for app in apps { out.append(await client.releaseCenterStatus(for: app, now: now)) }
        return .data(out, now)
    }

    private func readPlay() async -> Read<PlayAppStatus> {
        let apps = apps.filter { $0.store == .googlePlay }
        let client: GooglePlayClient
        do {
            guard let c = try playClient() else {
                return .unavailable(String(localized: "No Google Play service account. Add it in Settings → Integrations."))
            }
            client = c
        } catch { return .unavailable(String(localized: "The Google Play service account can't be used: \(error.localizedDescription)")) }
        let now = Date.now
        var out: [PlayAppStatus] = []
        for app in apps { out.append(await client.releaseCenterStatus(for: app, now: now)) }
        return .data(out, now)
    }

    private func readGitHub() async -> Read<RepoReleaseStatus> {
        let token: String?
        do { token = try inventory.secrets.read(.gitHubToken) } catch {
            return .unavailable(String(localized: "Could not read the GitHub token from the Keychain: \(error.localizedDescription)"))
        }
        let client = GitHubClient(token: token)
        let now = Date.now
        let repos = repos
        let results = await withTaskGroup(of: RepoReleaseStatus.self) { group in
            for repo in repos { group.addTask { await client.releaseStatus(repo) } }
            var all: [RepoReleaseStatus] = []
            for await r in group { all.append(r) }
            return all
        }
        return .data(results.sorted { $0.repo.slug.lowercased() < $1.repo.slug.lowercased() }, now)
    }

    /// Launch, then every 30 minutes with the other refreshes, when at least one source has credentials.
    func autoRefreshIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoRefreshKey) as? Bool ?? true, inventory.isLoaded,
              hasAppStoreKey || hasPlayKey || inventory.hasGitHubToken else { return }
        let last = defaults.object(forKey: Self.lastAutoRefreshKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= InventoryModel.autoRefreshInterval - 60 else { return }
        defaults.set(Date.now, forKey: Self.lastAutoRefreshKey)
        await refresh()
    }

    // MARK: The one write

    /// Releases an approved App Store version that waits for a manual release. Called only from the confirmation
    /// dialog. Checks the state first, sends once (never retried), reads back, records the result, re-reads the app.
    func release(_ version: AppStoreVersionInfo, of status: AppStoreAppStatus) async -> ReleaseActionRecord? {
        guard !releasing.contains(version.id) else { return nil }
        let client: AppStoreConnectClient
        do {
            guard let c = try appStoreClient() else {
                errorMessage = String(localized: "No App Store Connect key. Add it in Settings → Integrations.")
                return nil
            }
            client = c
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        releasing.insert(version.id)
        defer { releasing.remove(version.id) }
        let record = await AppStoreReleaseAction.release(app: status.app, version: version, using: client)
        actions.insert(record, at: 0)
        try? await log?.append(record)
        let fresh = await client.releaseCenterStatus(for: status.app, now: .now)
        if let i = snapshot.appStore.firstIndex(where: { $0.id == status.id }) { snapshot.appStore[i] = fresh }
        save()
        return record
    }

    private func save() {
        try? store?.save(snapshot)
    }
}
