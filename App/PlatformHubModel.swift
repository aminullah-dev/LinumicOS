import Foundation
import LinumicCore
import Observation

/// The platforms hub: versions, releases, CI and links for every Linumic platform. Reference facts come
/// from `PlatformCatalog`, store versions from the inventory, and GitHub observations from `PlatformSync`
/// (read-only, conditional requests). The GitHub part is a per-device cache in `platform-hub.json`.
@MainActor
@Observable
final class PlatformHubModel {
    private(set) var tracking: [RepoReleaseTracking] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var lastReport: PlatformSync.Report?
    var errorMessage: String?

    static let autoRefreshKey = "LCCAutoRefreshPlatforms"
    private static let lastAutoRefreshKey = "LCCLastPlatformsAutoRefresh"

    private let inventory: InventoryModel
    private let store: PlatformHubStore?
    private var cache = GitHubResponseCache()

    init(inventory: InventoryModel) {
        self.inventory = inventory
        self.store = (try? PlatformHubStore.defaultFileURL()).map(PlatformHubStore.init(fileURL:))
    }

    var rows: [PlatformRow] { PlatformHub.rows(products: inventory.products, tracking: tracking) }
    var summary: PlatformHubSummary { PlatformHubSummary(rows: rows) }

    func row(productID: String) -> PlatformRow? { rows.first { $0.id == productID } }

    func load() async {
        guard let store else { return }
        let file = await store.load()
        tracking = file.repos
        lastRefresh = file.lastRefresh
        cache = GitHubResponseCache(entries: file.etags)
    }

    /// Reads every catalogued product's repositories from GitHub. Without a token only public repositories
    /// answer; the private ones keep their last data and show the error.
    func refresh() async {
        guard !isRefreshing, inventory.isLoaded else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let token: String?
        do { token = try inventory.secrets.read(.gitHubToken) } catch {
            errorMessage = String(localized: "Could not read the GitHub token from the Keychain: \(error.localizedDescription)")
            return
        }
        let client = GitHubClient(token: token, cache: cache)
        let (updated, report) = await PlatformSync.refresh(products: inventory.products, previous: tracking, using: client, cache: cache)
        tracking = updated
        lastReport = report
        lastRefresh = .now
        await persist()
    }

    /// Same cadence as the store and oversight refresh (launch, then every 30 minutes), and only with a token:
    /// an anonymous sweep would use most of GitHub's 60 requests an hour.
    func autoRefreshIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoRefreshKey) as? Bool ?? true, inventory.isLoaded, inventory.hasGitHubToken else { return }
        let last = defaults.object(forKey: Self.lastAutoRefreshKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= InventoryModel.autoRefreshInterval - 60 else { return }
        defaults.set(Date.now, forKey: Self.lastAutoRefreshKey)
        await refresh()
    }

    private func persist() async {
        guard let store else { return }
        let file = PlatformHubFile(repos: tracking, etags: await cache.persistable(), lastRefresh: lastRefresh)
        do { try await store.save(file) } catch {
            errorMessage = String(localized: "Could not save the platforms cache: \(error.localizedDescription)")
        }
    }
}
