import Foundation

// MARK: - Drift

/// A factual mismatch between two observed values, computed and never guessed. Each flag says what was
/// compared and where both values came from.
public struct DriftFlag: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The version on the default branch is higher than the latest GitHub release.
        case releaseBehindMain
        /// The live store version is lower than the version on the default branch.
        case storeBehindMain
        /// The latest run of a workflow on the default branch failed.
        case ciFailing

        public var title: String {
            switch self {
            case .releaseBehindMain: L("Main is ahead of the latest release")
            case .storeBehindMain: L("Store version older than main")
            case .ciFailing: L("CI failing on main")
            }
        }
    }

    public var kind: Kind
    /// One sentence with both values, e.g. "Android: main 1.9.0, release v1.8.0".
    public var detail: String
    /// Where each compared value came from, with its date.
    public var evidence: [String]
    public var url: URL?

    public var id: String { "\(kind.rawValue)|\(detail)" }
}

public enum PlatformDrift {
    /// All drift flags for one product. A comparison is made only when both sides are real version numbers;
    /// a store label with two different versions, or a release tag like `android-app`, is never compared.
    public static func flags(profile: PlatformProfile, product: Product?, tracking: [RepoReleaseTracking]) -> [DriftFlag] {
        let bySlug = Dictionary(tracking.map { ($0.slug.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var flags: [DriftFlag] = []
        var seenRelease = Set<String>()

        for spec in profile.versionFiles {
            guard let reading = bySlug[spec.repo.lowercased()]?.versions.first(where: { $0.specID == spec.id }),
                  let mainName = reading.versionName, let main = SemanticVersion(mainName) else { continue }
            let mainEvidence = LF("Main: %1$@ from %2$@, read %3$@", mainName, reading.sourceReference, stamp(reading.fetchedAt))

            // 1. Release drift.
            if let releaseRepo = spec.releaseRepo, let repo = bySlug[releaseRepo.lowercased()],
               let release = repo.release, let released = release.version, released < main {
                let key = "\(releaseRepo)|\(mainName)|\(release.tag)"
                if seenRelease.insert(key).inserted {
                    flags.append(DriftFlag(
                        kind: .releaseBehindMain,
                        detail: LF("%1$@: main %2$@, latest release %3$@", spec.component, mainName, release.tag),
                        evidence: [mainEvidence, LF("Release: %1$@ on %2$@ (GitHub /releases/latest, read %3$@)", release.tag, releaseRepo, stamp(repo.fetchedAt))],
                        url: release.url))
                }
            }

            // 2. Store drift.
            if let appID = spec.appIdentifier, let store = store(for: spec.platform), let product {
                for listing in product.storeListings where listing.store == store && listing.appIdentifier == appID {
                    guard let live = SemanticVersion.single(in: listing.productionVersion), live < main,
                          let label = listing.productionVersion else { continue }
                    let source = listing.verification.sources.max { $0.observedAt < $1.observedAt }
                    let when = listing.verification.verifiedAt ?? source?.observedAt
                    flags.append(DriftFlag(
                        kind: .storeBehindMain,
                        detail: LF("%1$@ %2$@: live %3$@, main %4$@", store.title, listing.appName ?? appID, label, mainName),
                        evidence: [mainEvidence, LF("Store: %1$@ (%2$@, %3$@)", label, source?.reference ?? L("no source recorded"),
                                                    when.map(stamp) ?? L("date unknown"))],
                        url: listing.url))
                }
            }
        }

        // 3. CI failing on the default branch.
        for repo in tracking {
            for workflow in repo.failingWorkflows {
                flags.append(DriftFlag(
                    kind: .ciFailing,
                    detail: LF("%1$@ · %2$@ failed on %3$@", repo.slug, workflow.name, repo.defaultBranch ?? "main"),
                    evidence: [LF("GitHub Actions run of %1$@, %2$@ (read %3$@)", workflow.path,
                                  workflow.latestRun?.createdAt.map(stamp) ?? L("date unknown"), stamp(repo.fetchedAt))],
                    url: workflow.latestRun?.url))
            }
        }
        return flags
    }

    static func store(for platform: Platform) -> AppStore? {
        switch platform {
        case .android: .googlePlay
        case .iOS, .macOS, .watchOS: .appStore
        default: nil
        }
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
}

// MARK: - Rows

/// One product in the hub: the reference facts, the inventory record and what GitHub said. Derived, never stored.
public struct PlatformRow: Sendable, Identifiable {
    public var profile: PlatformProfile
    public var product: Product?
    /// Tracking for every repository of this product, in the product's order.
    public var repos: [RepoReleaseTracking]
    /// Repositories the hub watches for this product that haven't been read yet.
    public var unreadRepos: [String]
    public var flags: [DriftFlag]

    public var id: String { profile.productID }

    /// The newest published release across this product's repositories.
    public var latestRelease: (release: GitHubRelease, repo: String, fetchedAt: Date)? {
        repos.compactMap { r in r.release.map { ($0, r.slug, r.fetchedAt) } }
            .max { ($0.0.publishedAt ?? .distantPast) < ($1.0.publishedAt ?? .distantPast) }
    }

    /// True when every watched repository answered `/releases/latest` with 404.
    public var hasNoRelease: Bool {
        !repos.isEmpty && unreadRepos.isEmpty && repos.allSatisfy { $0.latestRelease == RepoReleaseTracking.LatestRelease.none }
    }

    public var versions: [(spec: VersionFileSpec, reading: VersionReading?)] {
        profile.versionFiles.map { spec in
            (spec, repos.first { $0.slug.caseInsensitiveCompare(spec.repo) == .orderedSame }?.versions.first { $0.specID == spec.id })
        }
    }

    /// Sum over the repositories that could be read; nil when none could.
    public var openPullRequests: Int? {
        let counts = repos.compactMap(\.openPullRequests)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    public var workflows: [(repo: String, workflow: WorkflowStatus)] {
        repos.flatMap { r in (r.workflows ?? []).map { (r.slug, $0) } }
    }

    public var lastRead: Date? { repos.map(\.fetchedAt).max() }
    public var storeListings: [StoreListing] { product?.storeListings ?? [] }

    public func has(_ kind: DriftFlag.Kind) -> Bool { flags.contains { $0.kind == kind } }
}

public enum PlatformHub {
    /// Repository types that ship code; websites, marketing folders and research aren't watched.
    static let watchedTypes: Set<RepositoryType> = [.monorepo, .application, .backend, .releases, .infrastructure, .unknown]

    /// The GitHub repositories the hub reads for a product: its code repositories from the inventory, plus
    /// any repository a version file or release lives in.
    public static func repositories(profile: PlatformProfile, product: Product?) -> [String] {
        var slugs: [String] = []
        func add(_ slug: String?) {
            guard let slug, !slugs.contains(where: { $0.caseInsensitiveCompare(slug) == .orderedSame }) else { return }
            slugs.append(slug)
        }
        for repo in product?.repositories ?? [] where watchedTypes.contains(repo.type) { add(repo.gitHubSlug) }
        for spec in profile.versionFiles { add(spec.repo); add(spec.releaseRepo) }
        return slugs
    }

    /// Rows for every catalogued product that exists in the inventory, in catalogue order.
    public static func rows(products: [Product], tracking: [RepoReleaseTracking], profiles: [PlatformProfile] = PlatformCatalog.profiles) -> [PlatformRow] {
        let bySlug = Dictionary(tracking.map { ($0.slug.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        return profiles.compactMap { profile in
            guard let product = products.first(where: { $0.id == profile.productID }) else { return nil }
            let slugs = repositories(profile: profile, product: product)
            let repos = slugs.compactMap { bySlug[$0.lowercased()] }
            let unread = slugs.filter { bySlug[$0.lowercased()] == nil }
            return PlatformRow(profile: profile, product: product, repos: repos, unreadRepos: unread,
                               flags: PlatformDrift.flags(profile: profile, product: product, tracking: repos))
        }
    }
}

/// Dashboard roll-up of the hub. Derived.
public struct PlatformHubSummary: Sendable, Equatable {
    public var products: Int
    public var withCIFailing: Int
    public var withReleaseDrift: Int
    public var withStoreDrift: Int
    /// Products none of whose repositories has been read yet.
    public var notRead: Int
    public var lastRead: Date?

    public init(rows: [PlatformRow]) {
        products = rows.count
        withCIFailing = rows.filter { $0.has(.ciFailing) }.count
        withReleaseDrift = rows.filter { $0.has(.releaseBehindMain) }.count
        withStoreDrift = rows.filter { $0.has(.storeBehindMain) }.count
        notRead = rows.filter { $0.repos.isEmpty }.count
        lastRead = rows.compactMap(\.lastRead).max()
    }
}

// MARK: - Sync

/// Refreshes the hub from GitHub, read-only. A repository that fails keeps its previous data with the
/// error attached, so a transient failure never blanks the screen.
public enum PlatformSync {
    public struct Report: Sendable, Equatable {
        public var updated: [String] = []
        public var failed: [String: String] = [:]
        /// Answers served from the ETag cache (no rate limit used).
        public var notModified = 0
    }

    public static func refresh(products: [Product], previous: [RepoReleaseTracking], using client: GitHubClient,
                               cache: GitHubResponseCache? = nil, profiles: [PlatformProfile] = PlatformCatalog.profiles) async -> ([RepoReleaseTracking], Report) {
        var report = Report()
        let before = await cache?.notModifiedCount ?? 0
        var bySlug = Dictionary(previous.map { ($0.slug.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var jobs: [(slug: String, specs: [VersionFileSpec])] = []
        for profile in profiles {
            guard let product = products.first(where: { $0.id == profile.productID }) else { continue }
            for slug in PlatformHub.repositories(profile: profile, product: product) {
                let specs = profile.versionFiles.filter { $0.repo.caseInsensitiveCompare(slug) == .orderedSame }
                if let i = jobs.firstIndex(where: { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }) {
                    jobs[i].specs += specs
                } else {
                    jobs.append((slug, specs))
                }
            }
        }

        var stopReason: String?
        for job in jobs {
            if let stopReason {   // rate limited: don't spend more requests this round
                mark(job.slug, failed: stopReason, in: &bySlug, report: &report, now: client.now())
                continue
            }
            do {
                bySlug[job.slug.lowercased()] = try await client.releaseTracking(slug: job.slug, versionFiles: job.specs)
                report.updated.append(job.slug)
            } catch {
                if case GitHubError.rateLimited = error { stopReason = error.localizedDescription }
                mark(job.slug, failed: error.localizedDescription, in: &bySlug, report: &report, now: client.now())
            }
        }
        report.notModified = (await cache?.notModifiedCount ?? 0) - before
        let ordered = jobs.compactMap { bySlug[$0.slug.lowercased()] }
        return (ordered, report)
    }

    private static func mark(_ slug: String, failed message: String, in bySlug: inout [String: RepoReleaseTracking], report: inout Report, now: Date) {
        report.failed[slug] = message
        if bySlug[slug.lowercased()] != nil {
            bySlug[slug.lowercased()]?.error = message
        }
        // Never seen before: nothing to keep, so it stays unread (shown as Unknown with the error in the report).
    }
}

// MARK: - Local cache

/// The hub's local file: the last tracking per repository and the GitHub ETags. Observations only, so it
/// stays on this device (`platform-hub.json` next to `inventory.json`) and is rebuilt by the next refresh.
public struct PlatformHubFile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var repos: [RepoReleaseTracking]
    public var etags: [String: GitHubResponseCache.Entry]
    public var lastRefresh: Date?

    public init(repos: [RepoReleaseTracking] = [], etags: [String: GitHubResponseCache.Entry] = [:], lastRefresh: Date? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.repos = repos
        self.etags = etags
        self.lastRefresh = lastRefresh
    }
}

public actor PlatformHubStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "platform-hub.json")
    }

    /// A missing, unreadable or newer-schema file loads as empty: it is a cache, and the next refresh rebuilds it.
    public func load() -> PlatformHubFile {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? InventoryCoding.decoder().decode(PlatformHubFile.self, from: data),
              file.schemaVersion <= PlatformHubFile.currentSchemaVersion else { return PlatformHubFile() }
        return file
    }

    public func save(_ file: PlatformHubFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(file).write(to: fileURL, options: [.atomic])
    }
}
