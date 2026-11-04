import Foundation
import LinumicCore
import Observation
#if os(macOS)
import AppKit
#endif

/// Products (محصولات) and Agents (ایجنت‌ها): every product with each platform's store version, build, version on main,
/// pull requests, CI, licences and health; and what each scheduled agent opened on GitHub. Built on this device from what
/// the Platforms hub, the Release Center, the licence ledger and the Monitor already read, plus two GitHub reads of its own
/// (the commits on each default branch, the agents' pull requests) with the existing token. Read-only; it never talks to
/// the service that runs the agents. Its reading is kept in `products-agents.json` (dates, versions, the agents' pull
/// request titles and links; no response body, no credential).
@MainActor
@Observable
final class ProductsModel {
    private(set) var file: ProductsFile
    /// The owner's tier choices for the management centre.
    private(set) var tiers: ProjectTiers
    private(set) var isRefreshing = false
    private(set) var lastReport: ProductsSync.Report?
    var errorMessage: String?
    /// The products' Mac apps as /Applications holds them, from their Info.plist only (`InstalledAppReader`): read at
    /// launch, whenever the app comes to the front, and after each products reading. Never kept in a file. Empty on
    /// iPhone and iPad, which have no /Applications to read.
    private(set) var installedApps: [String: Sourced<InstalledAppInfo>] = [:]
    @ObservationIgnored private var activeObserver: (any NSObjectProtocol)?

    private let inventory: InventoryModel
    private let platforms: PlatformHubModel
    private let releases: ReleaseCenterModel
    private let licences: LicenceModel
    private let monitor: MonitorModel
    private let store: ProductsStore?
    private let tiersStore: ProjectTiersStore?
    /// ETags for this session only (not saved: the file keeps observations, never a response body).
    private let cache = GitHubResponseCache()

    let registry = AgentRegistry.bundled

    init(inventory: InventoryModel, platforms: PlatformHubModel, releases: ReleaseCenterModel, licences: LicenceModel, monitor: MonitorModel) {
        self.inventory = inventory
        self.platforms = platforms
        self.releases = releases
        self.licences = licences
        self.monitor = monitor
        store = (try? ProductsStore.defaultFileURL()).map(ProductsStore.init(fileURL:))
        file = store?.load() ?? ProductsFile()
        tiersStore = (try? ProjectTiersStore.defaultFileURL()).map(ProjectTiersStore.init(fileURL:))
        tiers = tiersStore?.load() ?? ProjectTiers()
        readInstalledApps()
        #if os(macOS)
        // The owner installs a release in the Finder and comes back: the Center and the Releases tab say so at once.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readInstalledApps() }
        }
        #endif
    }

    /// Lists /Applications and reads the Info.plist of each catalogued app (`InstalledAppCatalog`). Nothing else of an
    /// app is opened, and none is run.
    func readInstalledApps(now: Date = .now) {
        #if os(macOS)
        installedApps = InstalledAppReader.read(using: LocalInstalledAppFiles(), now: now)
        #endif
    }

    /// Each catalogued Mac app against its product's newest release (the GitHub tags and releases Releases read). Empty on
    /// iPhone and iPad.
    func installedStatuses() -> [InstalledAppStatus] {
        #if DEBUG
        if let sample = ProductsPreviewData.installed() { return sample }
        #endif
        #if os(macOS)
        return InstalledAppCheck.statuses(installed: installedApps, releases: releases.snapshot)
        #else
        return []
        #endif
    }

    /// This app's own build: Linumic OS is not in a store, so the build running here is the one that is known.
    nonisolated static var runningBuild: RunningBuild? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        #if os(macOS)
        let platform = Platform.macOS
        #else
        let platform = Platform.iOS
        #endif
        return RunningBuild(platform: platform, version: version, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    func setTier(_ tier: CenterTier, forProduct id: String) {
        tiers.set(tier, forProduct: id)
        do { try tiersStore?.save(tiers) } catch {
            errorMessage = String(localized: "Could not save the project's tier: \(error.localizedDescription)")
        }
    }

    func input(now: Date = .now) -> ProductsInput {
        ProductsInput(now: now, products: inventory.products, tracking: platforms.tracking + file.extraTracking, releases: releases.snapshot,
                      licences: BriefLicenceInput(isLoaded: licences.isLoaded, records: licences.records, lastSyncedAt: licences.lastSyncedAt),
                      monitor: monitor.snapshot, monitorTargets: monitor.targets, history: file.history, historyErrors: file.historyErrors,
                      runningApp: Self.runningBuild, catalog: ProductsCatalog.all(inventory: inventory.products))
    }

    /// The Products page as of now. Derived every time, never stored.
    func report(now: Date = .now) -> ProductsReport {
        #if DEBUG
        if let sample = ProductsPreviewData.input(now: now) { return ProductsBuilder.build(sample) }
        #endif
        return ProductsBuilder.build(input(now: now))
    }

    /// The agents as of now.
    func agents(now: Date = .now) -> AgentsReport {
        #if DEBUG
        if let sample = ProductsPreviewData.windows(now: now) { return AgentActivity.report(registry: registry, windows: sample, now: now) }
        #endif
        return AgentActivity.report(registry: registry, windows: file.pullWindows, now: now)
    }

    /// Reads the commits on each default branch, Linumic OS's repository and the agents' pull requests from GitHub
    /// (GET only). Without a token, only public repositories answer; the others keep their last reading and say why.
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
        let (updated, report) = await ProductsSync.refresh(products: inventory.products, file: file, using: client, registry: registry)
        file = updated
        lastReport = report
        readInstalledApps()
        do { try store?.save(file) } catch {
            errorMessage = String(localized: "Could not save the products reading: \(error.localizedDescription)")
        }
    }
}
