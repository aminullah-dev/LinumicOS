import Foundation

// MARK: - Building the Products page
//
// Pure: everything here is built from what the app already read (the Platforms hub's GitHub reading, the Release
// Center's App Store Connect, Google Play and GitHub reading, the licence ledger, the Monitor) plus the commits on each
// default branch (`MainHistory`). Nothing is fetched here and nothing is guessed: a value that was not read is
// `Sourced.unknown` with its reason.

/// What the Products page is built from, as the App holds it.
public struct ProductsInput: Sendable {
    public var now: Date
    /// The inventory.
    public var products: [Product]
    /// The Platforms hub's repositories, plus the ones read for this page alone (Linumic OS).
    public var tracking: [RepoReleaseTracking]
    public var releases: ReleaseCenterSnapshot
    public var licences: BriefLicenceInput
    public var monitor: MonitorSnapshot
    public var monitorTargets: [MonitorTarget]
    /// Commits on each default branch.
    public var history: [MainHistory]
    /// Repositories whose commits could not be read, with why.
    public var historyErrors: [String: String]
    /// The build running on this device (Linumic OS itself).
    public var runningApp: RunningBuild?
    public var catalog: [CompanyProduct]
    public var versionFiles: [VersionFileSpec]

    public init(now: Date, products: [Product], tracking: [RepoReleaseTracking], releases: ReleaseCenterSnapshot,
                licences: BriefLicenceInput, monitor: MonitorSnapshot, monitorTargets: [MonitorTarget] = MonitorCatalog.targets,
                history: [MainHistory] = [], historyErrors: [String: String] = [:], runningApp: RunningBuild? = nil,
                catalog: [CompanyProduct] = ProductsCatalog.products,
                versionFiles: [VersionFileSpec] = PlatformCatalog.profiles.flatMap(\.versionFiles) + ProductsCatalog.extraVersionFiles) {
        self.now = now
        self.products = products
        self.tracking = tracking
        self.releases = releases
        self.licences = licences
        self.monitor = monitor
        self.monitorTargets = monitorTargets
        self.history = history
        self.historyErrors = historyErrors
        self.runningApp = runningApp
        self.catalog = catalog
        self.versionFiles = versionFiles
    }

    /// True when none of the sources has been read on this device yet.
    public var nothingRead: Bool {
        tracking.isEmpty && history.isEmpty && releases.appStoreReadAt == nil && releases.playReadAt == nil && releases.gitHubReadAt == nil
    }
}

/// Monitor checks of a product or part, as last read.
public struct HealthSummary: Hashable, Sendable {
    public var up: Int
    public var degraded: Int
    public var down: Int
    /// Targets not checked yet.
    public var unchecked: Int

    public var total: Int { up + degraded + down + unchecked }
}

/// Open pull requests of a product's repositories.
public struct PullSummary: Hashable, Sendable {
    public var open: Int
    public var drafts: Int
    /// Opened by a scheduled agent (`[agent:<slug>]` or `agent/<slug>/`).
    public var byAgents: Int
    /// The pull requests themselves when the Release Center listed them (empty when only a count was read).
    public var pulls: [ProductPull]
}

public struct ProductPull: Hashable, Sendable, Identifiable {
    public var repo: String
    public var pull: GitHubPullInfo
    public var id: String { "\(repo)#\(pull.number)" }
}

/// CI on the default branch of a product's repositories.
public struct CISummary: Hashable, Sendable {
    public var passing: [String]
    public var failing: [String]
    public var running: [String]
    /// Repositories with no CI run on the default branch.
    public var noRuns: [String]
}

/// Licences of a licence product in the ledger.
public struct ProductLicences: Hashable, Sendable {
    public var active: Int
    public var expiringSoon: Int
    public var expired: Int
    public var total: Int
}

/// One platform as read.
public struct SlotReading: Hashable, Sendable, Identifiable {
    public var slot: ProductSlot
    public var live: Sourced<VersionStamp>
    public var build: Sourced<VersionStamp>
    public var main: Sourced<VersionStamp>
    public var behind: Sourced<BehindMain>
    /// Monitor checks of this part, for a part with monitored addresses.
    public var health: Sourced<HealthSummary>?

    public var id: String { slot.id }
}

public struct TrackReading: Hashable, Sendable, Identifiable {
    public var track: ProductTrack
    public var slots: [SlotReading]
    public var id: String { track.id }
}

/// One card of the Products page.
public struct ProductCard: Hashable, Sendable, Identifiable {
    public var product: CompanyProduct
    public var tracks: [TrackReading]
    public var level: ProductLevelState
    public var repos: [String]
    public var pulls: Sourced<PullSummary>
    public var ci: Sourced<CISummary>
    /// Nil when the product is not sold with a licence.
    public var licences: Sourced<ProductLicences>?
    public var health: Sourced<HealthSummary>
    /// The newest read time of anything on the card.
    public var readAt: Date?

    public var id: String { product.id }
    public var slots: [SlotReading] { tracks.flatMap(\.slots) }

    /// What was not read on the compared platforms, whatever the level (a product not level can have parts unread too).
    /// With the track's name when more than one app of the product is compared (VELRO Ride, Driver and Ops).
    public var unread: [String] {
        let compared = tracks.filter { $0.slots.contains(where: \.slot.compared) }
        return compared.flatMap { t in
            ProductLevelRule.evaluate(t.track.title, t.slots.filter(\.slot.compared)).unknowns.map { compared.count > 1 ? "\(t.track.title): \($0)" : $0 }
        }
    }
}

public struct ProductsReport: Sendable, Hashable {
    public var cards: [ProductCard]
    public var generatedAt: Date
    /// Nothing was read on this device yet.
    public var nothingRead: Bool

    public func card(_ id: String) -> ProductCard? { cards.first { $0.id == id } }
    public var notLevel: [ProductCard] { cards.filter { if case .notLevel = $0.level { true } else { false } } }
    public var unknown: [ProductCard] { cards.filter { if case .unknown = $0.level { true } else { false } } }
    public var level: [ProductCard] { cards.filter { $0.level == .level } }
}

public enum ProductsBuilder {
    public static func build(_ input: ProductsInput) -> ProductsReport {
        let ctx = Context(input)
        let cards = input.catalog.map { card($0, ctx) }
        return ProductsReport(cards: cards, generatedAt: input.now, nothingRead: input.nothingRead)
    }

    /// Lookups shared by every card.
    struct Context {
        let input: ProductsInput
        let tracking: [String: RepoReleaseTracking]
        let history: [String: MainHistory]
        let specs: [String: VersionFileSpec]

        init(_ input: ProductsInput) {
            self.input = input
            tracking = Dictionary(input.tracking.map { ($0.slug.lowercased(), $0) }, uniquingKeysWith: { a, b in a.fetchedAt >= b.fetchedAt ? a : b })
            history = Dictionary(input.history.map { ($0.repo.lowercased(), $0) }, uniquingKeysWith: { a, b in a.readAt >= b.readAt ? a : b })
            specs = Dictionary(input.versionFiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        func inventory(_ product: CompanyProduct) -> Product? {
            product.inventoryID.flatMap { id in input.products.first { $0.id == id } }
        }
    }

    // MARK: Card

    static func card(_ product: CompanyProduct, _ ctx: Context) -> ProductCard {
        let inventory = ctx.inventory(product)
        let repos = repositories(product, inventory: inventory)
        let tracks = product.tracks.map { track in
            TrackReading(track: track, slots: track.slots.map { slotReading($0, product: product, inventory: inventory, repos: repos, ctx) })
        }
        let level = ProductLevelRule.evaluate(tracks)
        let pulls = pullSummary(repos, ctx)
        let ci = ciSummary(repos, ctx)
        let licences = product.licence.map { licenceSummary($0, ctx) }
        let health = healthSummary(product.monitor.map { m in ctx.input.monitorTargets.filter { $0.product == m && $0.environment == .production }.map(\.id) } ?? [],
                                   ctx, noneReason: L("No public address of this product is monitored."))
        let times = tracks.flatMap(\.slots).flatMap { [$0.live.readAt, $0.build.readAt, $0.main.readAt, $0.behind.readAt] }
            + [pulls.readAt, ci.readAt, licences?.readAt, health.readAt]
        return ProductCard(product: product, tracks: tracks, level: level, repos: repos, pulls: pulls, ci: ci, licences: licences,
                           health: health, readAt: times.compactMap { $0 }.max())
    }

    /// The product's code repositories: the inventory's (monorepo, application, backend) and the catalogue's extra ones.
    static func repositories(_ product: CompanyProduct, inventory: Product?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for repo in inventory?.repositories ?? [] where ReleaseCatalog.codeTypes.contains(repo.type) {
            if let slug = repo.gitHubSlug, seen.insert(slug.lowercased()).inserted { out.append(slug) }
        }
        for slug in product.extraRepos where seen.insert(slug.lowercased()).inserted { out.append(slug) }
        return out
    }

    // MARK: One platform

    static func slotReading(_ slot: ProductSlot, product: CompanyProduct, inventory: Product?, repos: [String], _ ctx: Context) -> SlotReading {
        let listing = storeListing(slot, inventory: inventory)
        let live = liveVersion(slot, listing: listing, ctx)
        let build = newestBuild(slot, listing: listing, ctx)
        let spec = slot.versionSpec.flatMap { ctx.specs[$0] }
        let historyRepo = spec?.repo ?? repos.first
        let main = mainVersion(slot, spec: spec, ctx)
        let behind = behindMain(slot, build: build, repo: historyRepo, ctx)
        let health = slot.monitorTargets.isEmpty ? nil : healthSummary(slot.monitorTargets, ctx, noneReason: L("No public address of this part is monitored."))
        return SlotReading(slot: slot, live: live, build: build, main: main, behind: behind, health: health)
    }

    static func storeListing(_ slot: ProductSlot, inventory: Product?) -> StoreListing? {
        guard let id = slot.appIdentifier, let store = slot.store else { return nil }
        return inventory?.storeListings.first { $0.store == store && $0.appIdentifier?.trimmingCharacters(in: .whitespaces) == id }
    }

    // MARK: Live in the store

    static func liveVersion(_ slot: ProductSlot, listing: StoreListing?, _ ctx: Context) -> Sourced<VersionStamp> {
        guard let store = slot.store, let appID = slot.appIdentifier else {
            return .none(L("Not in a store."), source: slot.source, readAt: nil)
        }
        guard let listing else {
            return .none(LF("Not in a store: the inventory has no %1$@ listing for %2$@.", store.title, appID), source: L("Inventory store listings"), readAt: nil)
        }
        let releases = ctx.input.releases
        switch store {
        case .appStore:
            if let status = releases.appStore.first(where: { $0.app.appIdentifier == appID }), status.error == nil, let platform = slot.ascPlatform {
                if let v = status.live(platform: platform) {
                    return .known(VersionStamp(name: v.versionString, code: v.build?.number, detail: v.phase.title), source: status.endpoint,
                                  readAt: status.fetchedAt)
                }
                return .none(LF("No version is live on the App Store for %@.", slot.platform.title), source: status.endpoint, readAt: status.fetchedAt)
            }
            return listingVersion(listing, why: appStoreReason(appID, releases))
        case .googlePlay:
            if let status = releases.play.first(where: { $0.app.appIdentifier == appID }), status.error == nil {
                guard let production = status.tracks.first(where: { $0.track == "production" }),
                      let release = newestRelease(production.releases.filter { $0.status != .draft }) else {
                    return .none(L("Nothing is on the production track."), source: status.endpoint, readAt: status.fetchedAt)
                }
                return .known(VersionStamp(name: playVersionName(release.name), code: release.versionCodes.max().map(String.init),
                                           detail: playDetail(release)),
                              source: status.endpoint, readAt: status.fetchedAt)
            }
            return listingVersion(listing, why: playReason(appID, releases))
        }
    }

    /// The live version the inventory's store listing holds, when the console was not read: with the listing's own source.
    static func listingVersion(_ listing: StoreListing, why: String) -> Sourced<VersionStamp> {
        guard let label = listing.productionVersion?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return .unknown(why) }
        let source = listing.verification.sources.max { $0.observedAt < $1.observedAt }
        let when = listing.verification.verifiedAt ?? source?.observedAt
        return .known(VersionStamp(name: SemanticVersion.single(in: label)?.description ?? label, detail: L("From the inventory's store listing")),
                      source: source?.reference ?? L("Inventory store listing"), readAt: when)
    }

    static func appStoreReason(_ appID: String, _ releases: ReleaseCenterSnapshot) -> String {
        if let status = releases.appStore.first(where: { $0.app.appIdentifier == appID }), let error = status.error { return error }
        return releases.appStoreNote ?? (releases.appStoreReadAt == nil ? L("App Store Connect not read yet.") : LF("App Store Connect did not list %@.", appID))
    }

    static func playReason(_ appID: String, _ releases: ReleaseCenterSnapshot) -> String {
        if let status = releases.play.first(where: { $0.app.appIdentifier == appID }), let error = status.error { return error }
        return releases.playNote ?? (releases.playReadAt == nil ? L("Google Play not read yet.") : LF("Google Play did not list %@.", appID))
    }

    /// Play's default release name is "<versionCode> (<versionName>)": that becomes the version name.
    static func playVersionName(_ name: String?) -> String? {
        PlayRelease(releaseName: name, track: "", versionCodes: [], state: "").versionName
    }

    static func playDetail(_ release: PlayTrackRelease) -> String {
        if let f = release.userFraction, release.status == .inProgress {
            return LF("%1$@, %2$ld%%", release.status.title, Int((f * 100).rounded()))
        }
        return release.status.title
    }

    static func newestRelease(_ releases: [PlayTrackRelease]) -> PlayTrackRelease? {
        releases.filter { !$0.isEmptyDraft && !$0.versionCodes.isEmpty }.max { ($0.versionCodes.max() ?? 0) < ($1.versionCodes.max() ?? 0) }
    }

    // MARK: Newest build

    static func newestBuild(_ slot: ProductSlot, listing: StoreListing?, _ ctx: Context) -> Sourced<VersionStamp> {
        switch slot.build {
        case .none(let why):
            return .none(L(why), source: slot.source, readAt: nil)
        case .runningApp:
            guard let running = ctx.input.runningApp, running.platform == slot.platform else {
                return .unknown(L("Only the build running on this device is known here: Linumic OS is not in a store and has no GitHub release."))
            }
            return .known(VersionStamp(name: running.version, code: running.build, detail: L("Running on this device")),
                          source: L("This app's Info.plist (the build running now)"), readAt: ctx.input.now)
        case .releaseAsset(let repo, let suffixes, let contains):
            return releaseAssetBuild(repo: repo, suffixes: suffixes, contains: contains, ctx)
        case .store:
            guard let store = slot.store, let appID = slot.appIdentifier else { return .none(L("Not in a store."), source: slot.source, readAt: nil) }
            guard listing != nil else {
                return .unknown(LF("No %1$@ listing for %2$@ in the inventory, so its builds are not read.", store.title, appID))
            }
            let releases = ctx.input.releases
            switch store {
            case .appStore:
                guard let status = releases.appStore.first(where: { $0.app.appIdentifier == appID }), status.error == nil,
                      let platform = slot.ascPlatform else { return .unknown(appStoreReason(appID, releases)) }
                var builds = status.builds.filter { $0.platform == platform }
                // A build attached to a version is that version's platform's, even when the builds list didn't say.
                for v in status.versions where v.platform == platform {
                    if let b = v.build, !builds.contains(where: { $0.id == b.id }) { builds.append(b) }
                }
                guard let b = builds.max(by: { ($0.uploadedAt ?? .distantPast) < ($1.uploadedAt ?? .distantPast) }) else {
                    if status.versions.isEmpty, status.builds.isEmpty {
                        return .unknown(L("App Store Connect returned no versions and no builds for this app."))
                    }
                    return .none(LF("App Store Connect lists no build for %@.", slot.platform.title), source: status.endpoint, readAt: status.fetchedAt)
                }
                let attached = status.versions.first { $0.build?.id == b.id }
                return .known(VersionStamp(name: b.version ?? attached?.versionString, code: b.number, date: b.uploadedAt,
                                           detail: attached?.phase.title ?? b.processingState),
                              source: LF("App Store Connect API /v1/builds of %@", appID), readAt: status.fetchedAt)
            case .googlePlay:
                guard let status = releases.play.first(where: { $0.app.appIdentifier == appID }), status.error == nil else {
                    return .unknown(playReason(appID, releases))
                }
                var best: (track: String, release: PlayTrackRelease)?
                for track in status.tracks {
                    if let r = newestRelease(track.releases), (r.versionCodes.max() ?? 0) > (best?.release.versionCodes.max() ?? -1) {
                        best = (track.track, r)
                    }
                }
                guard let best else { return .none(L("No release on any Google Play track."), source: status.endpoint, readAt: status.fetchedAt) }
                return .known(VersionStamp(name: playVersionName(best.release.name), code: best.release.versionCodes.max().map(String.init),
                                           detail: "\(best.track) · \(playDetail(best.release))"),
                              source: status.endpoint, readAt: status.fetchedAt)
            }
        }
    }

    static func releaseAssetBuild(repo: String, suffixes: [String], contains: String?, _ ctx: Context) -> Sourced<VersionStamp> {
        guard let tracking = ctx.tracking[repo.lowercased()] else {
            return .unknown(LF("%@ has not been read from GitHub yet.", repo))
        }
        var releases = tracking.recentReleases
        if let latest = tracking.release, !releases.contains(where: { $0.tag == latest.tag }) { releases.append(latest) }
        func matches(_ name: String) -> Bool {
            let n = name.lowercased()
            return suffixes.contains { n.hasSuffix($0.lowercased()) } && (contains.map { n.contains($0.lowercased()) } ?? true)
        }
        let candidates = releases.compactMap { r in r.assets.first { matches($0.name) }.map { (r, $0) } }
        if let (release, asset) = candidates.max(by: { ($0.0.publishedAt ?? .distantPast) < ($1.0.publishedAt ?? .distantPast) }) {
            // "v1.8.0" reads as 1.8.0; a tag that is no version ("salon-desktop") keeps its name, so it is never compared.
            let name = release.version?.description ?? SemanticVersion.single(in: asset.name)?.description ?? release.tag
            return .known(VersionStamp(name: name, date: release.publishedAt, detail: asset.name),
                          source: LF("GitHub release %1$@ of %2$@", release.tag, repo), readAt: tracking.fetchedAt)
        }
        if releases.isEmpty {
            if tracking.latestRelease == RepoReleaseTracking.LatestRelease.none {
                return .none(LF("%@ has no GitHub release.", repo), source: LF("GitHub releases of %@", repo), readAt: tracking.fetchedAt)
            }
            return .unknown(tracking.problems.first ?? tracking.error ?? LF("The releases of %@ were not read.", repo))
        }
        // The latest release was read but the list of releases was not: an older release may hold the file.
        if tracking.recentReleases.isEmpty {
            return .unknown(tracking.problems.first ?? LF("The releases of %@ were not read.", repo))
        }
        let kinds = (contains.map { ["\($0)"] } ?? []) + [suffixes.joined(separator: " / ")]
        return .none(LF("None of the last %1$ld GitHub releases of %2$@ has a %3$@ file.", releases.count, repo, kinds.joined(separator: " ")),
                     source: LF("GitHub releases of %@", repo), readAt: tracking.fetchedAt)
    }

    // MARK: Default branch

    static func mainVersion(_ slot: ProductSlot, spec: VersionFileSpec?, _ ctx: Context) -> Sourced<VersionStamp> {
        guard let spec else {
            if let why = slot.noVersionFile { return .none(L(why), source: slot.source, readAt: nil) }
            return .none(L("No version file is catalogued for this part."), source: nil, readAt: nil)
        }
        guard let tracking = ctx.tracking[spec.repo.lowercased()] else {
            return .unknown(LF("%@ has not been read from GitHub yet.", spec.repo))
        }
        guard let reading = tracking.versions.first(where: { $0.specID == spec.id }) else {
            return .unknown(tracking.error ?? LF("%@ was not read in the last GitHub reading.", spec.path))
        }
        guard let name = reading.versionName else {
            return .unknown(reading.error ?? L("The file has no version this app can read."))
        }
        return .known(VersionStamp(name: name, code: reading.versionCode, date: ctx.history[spec.repo.lowercased()]?.newest),
                      source: reading.sourceReference, readAt: reading.fetchedAt)
    }

    static func behindMain(_ slot: ProductSlot, build: Sourced<VersionStamp>, repo: String?, _ ctx: Context) -> Sourced<BehindMain> {
        switch build {
        case .unknown(let why): return .unknown(why)
        case .none: return .none(L("No build to compare with the default branch."), source: nil, readAt: nil)
        case .known(let stamp, let source, _):
            guard let date = stamp.date else {
                return .none(LF("%@ gives no date for this build, so the commits since it are not counted.", source), source: source, readAt: nil)
            }
            guard let repo else { return .none(L("No repository to compare with."), source: nil, readAt: nil) }
            guard let history = ctx.history[repo.lowercased()] else {
                return .unknown(ctx.input.historyErrors[repo] ?? ctx.input.historyErrors[repo.lowercased()]
                                ?? LF("The commits on the default branch of %@ have not been read yet.", repo))
            }
            guard let newest = history.newest else {
                return .unknown(LF("GitHub listed no commit on %1$@ of %2$@.", history.branch, repo))
            }
            let (count, atLeast) = history.commits(after: date)
            let days = max(0, Int(newest.timeIntervalSince(date) / 86_400))
            return .known(BehindMain(commits: count, atLeast: atLeast, days: days, newestCommit: newest),
                          source: LF("GitHub commits on %1$@ of %2$@ (the newest %3$ld)", history.branch, repo, history.commitDates.count),
                          readAt: history.readAt)
        }
    }

    // MARK: Pull requests, CI, licences, health

    static func pullSummary(_ repos: [String], _ ctx: Context) -> Sourced<PullSummary> {
        guard !repos.isEmpty else { return .none(L("No code repository is recorded for this product."), source: nil, readAt: nil) }
        let slugs = Set(AgentRegistry.bundled.agents.map(\.slug))
        var pulls: [ProductPull] = []
        var counted = 0, drafts = 0, agents = 0
        var times: [Date] = []
        var sources: [String] = []
        for repo in repos {
            if let status = ctx.input.releases.repos.first(where: { $0.repo.slug.caseInsensitiveCompare(repo) == .orderedSame }), status.error == nil {
                pulls += status.pulls.map { ProductPull(repo: repo, pull: $0) }
                counted += status.pulls.count
                drafts += status.pulls.count(where: \.isDraft)
                agents += status.pulls.count { AgentMatcher.slug(title: $0.title, head: $0.head, slugs: slugs) != nil }
                times.append(status.fetchedAt)
                sources.append(LF("Release Center, GitHub /repos/%@/pulls", repo))
            } else if let tracking = ctx.tracking[repo.lowercased()], let n = tracking.openPullRequests {
                counted += n
                times.append(tracking.fetchedAt)
                sources.append(LF("Platforms hub, GitHub /repos/%@/pulls (count only)", repo))
            } else {
                return .unknown(LF("The pull requests of %@ have not been read yet.", repo))
            }
        }
        return .known(PullSummary(open: counted, drafts: drafts, byAgents: agents, pulls: pulls.sorted { $0.id < $1.id }),
                      source: sources.joined(separator: "; "), readAt: times.min())
    }

    static func ciSummary(_ repos: [String], _ ctx: Context) -> Sourced<CISummary> {
        guard !repos.isEmpty else { return .none(L("No code repository is recorded for this product."), source: nil, readAt: nil) }
        var s = CISummary(passing: [], failing: [], running: [], noRuns: [])
        var times: [Date] = []
        var sources: [String] = []
        for repo in repos {
            if let status = ctx.input.releases.repos.first(where: { $0.repo.slug.caseInsensitiveCompare(repo) == .orderedSame }), status.error == nil {
                switch status.mainCI {
                case .success: s.passing.append(repo)
                case .failure: s.failing.append(repo)
                case .pending: s.running.append(repo)
                case .none: s.noRuns.append(repo)
                }
                times.append(status.fetchedAt)
                sources.append(LF("Release Center, GitHub Actions runs on %1$@ of %2$@", status.defaultBranch ?? "main", repo))
            } else if let tracking = ctx.tracking[repo.lowercased()], let workflows = tracking.workflows {
                let runs = workflows.compactMap(\.latestRun)
                if runs.contains(where: { $0.outcome == .failure }) { s.failing.append(repo) }
                else if runs.contains(where: { $0.outcome == .inProgress }) { s.running.append(repo) }
                else if runs.contains(where: { $0.outcome == .success }) { s.passing.append(repo) }
                else { s.noRuns.append(repo) }
                times.append(tracking.fetchedAt)
                sources.append(LF("Platforms hub, GitHub Actions workflows of %@", repo))
            } else {
                return .unknown(LF("CI of %@ has not been read yet.", repo))
            }
        }
        return .known(s, source: sources.joined(separator: "; "), readAt: times.min())
    }

    static func licenceSummary(_ product: LicenceProduct, _ ctx: Context) -> Sourced<ProductLicences> {
        let l = ctx.input.licences
        guard l.isLoaded else { return .unknown(L("The licence ledger has not been read yet.")) }
        let records = l.records.filter { $0.product == product }
        if records.isEmpty, l.lastSyncedAt == nil {
            return .unknown(L("The ledger is empty on this device and has never been synced, so whether licences exist elsewhere is unknown."))
        }
        let now = ctx.input.now
        let summary = ProductLicences(active: records.count { $0.status == .active && !$0.isExpired(today: now) },
                                     expiringSoon: records.count { $0.isExpiring(within: DailyBriefBuilder.expiryWindowDays, today: now) },
                                     expired: records.count { $0.isExpired(today: now) }, total: records.count)
        let source = l.lastSyncedAt == nil ? L("Licence ledger on this device (not synced)") : L("Licence ledger (synced with Supabase)")
        return .known(summary, source: source, readAt: l.lastSyncedAt)
    }

    static func healthSummary(_ targetIDs: [String], _ ctx: Context, noneReason: String) -> Sourced<HealthSummary> {
        guard !targetIDs.isEmpty else { return .none(noneReason, source: nil, readAt: nil) }
        let snapshot = ctx.input.monitor
        guard snapshot.lastRoundAt != nil else { return .unknown(L("Not checked yet. The Monitor checks when the app opens.")) }
        var s = HealthSummary(up: 0, degraded: 0, down: 0, unchecked: 0)
        var times: [Date] = []
        for id in targetIDs {
            guard let r = snapshot.latest[id] else { s.unchecked += 1; continue }
            times.append(r.checkedAt)
            switch r.state {
            case .up: s.up += 1
            case .degraded: s.degraded += 1
            case .down: s.down += 1
            case .unknown: s.unchecked += 1
            }
        }
        let hosts = targetIDs.compactMap { id in ctx.input.monitorTargets.first { $0.id == id }?.host }
        var seen = Set<String>()
        return .known(s, source: LF("Monitor: GET %@", hosts.filter { seen.insert($0).inserted }.joined(separator: ", ")), readAt: times.min())
    }
}
