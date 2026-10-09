import Foundation

/// One repository under project oversight, independent of whether it is linked to a confirmed
/// product. This is the "from 0 to 100" register: every repository the owner has, watched for
/// latest changes and security, read-only. Facts come from GitHub (`snapshot`) and, later, a
/// local `.git` scan. Anything unread is `nil`, never guessed.
public struct OversightRepo: Codable, Hashable, Sendable, Identifiable {
    /// `owner/name`, the stable identity.
    public var slug: String
    public var isPrivate: Bool
    public var isArchived: Bool
    /// Last push time from the repository listing (as of the last sync).
    public var pushedAt: Date?
    /// Full read-only GitHub observation, including security posture. `nil` until first scanned.
    public var snapshot: RepositorySnapshot?
    /// The last sync error for this repo, if the snapshot could not be refreshed.
    public var scanError: String?
    /// Status of the local working copy on this Mac, from the last local scan. `nil` when no local
    /// checkout has been scanned (no workspace folder chosen, or this repo isn't checked out there).
    public var local: LocalGitStatus?
    /// When this entry was last touched by a sync.
    public var observedAt: Date

    public var id: String { slug }
    public var name: String { slug.split(separator: "/").last.map(String.init) ?? slug }
    public var owner: String? { slug.split(separator: "/").first.map(String.init) }

    public init(
        slug: String, isPrivate: Bool = false, isArchived: Bool = false, pushedAt: Date? = nil,
        snapshot: RepositorySnapshot? = nil, scanError: String? = nil, local: LocalGitStatus? = nil, observedAt: Date = .now
    ) {
        self.slug = slug
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.pushedAt = pushedAt
        self.snapshot = snapshot
        self.scanError = scanError
        self.local = local
        self.observedAt = observedAt
    }
}

/// How much attention a repository needs, derived from its snapshot. Never stored.
public enum OversightHealth: String, Codable, Sendable, Comparable {
    /// At least one open security alert, or a failing CI run on the default branch.
    case critical
    /// A softer signal: unprotected default branch, stale (no recent push), or a scan error.
    case attention
    /// Scanned, nothing flagged.
    case healthy
    /// Never scanned yet, so its state is genuinely unknown.
    case unknown

    /// Most-urgent first, for sorting and roll-ups.
    private var rank: Int {
        switch self { case .critical: 0; case .attention: 1; case .unknown: 2; case .healthy: 3 }
    }
    public static func < (lhs: OversightHealth, rhs: OversightHealth) -> Bool { lhs.rank < rhs.rank }

    public var title: String {
        switch self {
        case .critical: L("Critical")
        case .attention: L("Needs attention")
        case .healthy: L("Healthy")
        case .unknown: L("Not scanned")
        }
    }
}

extension OversightRepo {
    /// Days since the last push, as of `reference`. `nil` when the push time is unknown.
    public func daysSincePush(asOf reference: Date = .now) -> Int? {
        guard let pushedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: pushedAt, to: reference).day
    }

    /// Derived health. `staleAfterDays` is how long without a push counts as stale. A repository is
    /// Unknown only when neither a GitHub snapshot nor a local scan exists; it is Healthy only after
    /// being scanned with nothing flagged.
    public func health(staleAfterDays: Int = 30, asOf reference: Date = .now) -> OversightHealth {
        if snapshot == nil && local == nil { return .unknown }
        // Critical: anything security- or build-breaking from GitHub.
        if snapshot?.security?.hasOpenAlerts == true { return .critical }
        if snapshot?.ciConclusion == .failure { return .critical }
        // Needs attention: softer signals, from GitHub or the local working copy.
        if scanError != nil { return .attention }
        if snapshot?.security?.defaultBranchProtected == false { return .attention }
        if local?.hasUncommittedChanges == true { return .attention }
        if local?.syncState == .diverged { return .attention }
        if let days = daysSincePush(asOf: reference), days > staleAfterDays { return .attention }
        return .healthy
    }
}

/// Cross-repository health, derived from the oversight register. Pure, like `DashboardSummary`:
/// nothing here is stored, it is analysis of the facts.
public struct OversightSummary: Sendable, Equatable {
    public var totalRepos: Int
    public var scannedRepos: Int
    public var neverScanned: Int
    public var criticalRepos: Int
    public var attentionRepos: Int
    public var healthyRepos: Int
    /// Sum of open security alerts across repos that could be read.
    public var openSecurityAlerts: Int
    public var reposWithOpenAlerts: Int
    public var reposWithFailingCI: Int
    public var unprotectedDefaultBranches: Int
    public var staleRepos: Int
    public var totalOpenPullRequests: Int
    public var totalOpenIssues: Int
    /// Local working-copy signals (only counted for repos that were scanned locally).
    public var reposScannedLocally: Int
    public var reposWithUncommittedChanges: Int
    public var reposDivergedFromOrigin: Int
    public var lastScan: Date?

    /// A single 0–100 health score: the share of repositories that are healthy. A repo that was
    /// never scanned counts against the score (it is unverified, not assumed fine). `nil` only when
    /// there are no repos at all.
    public var healthScore: Int?

    public init(repos: [OversightRepo], staleAfterDays: Int = 30, now: Date = .now) {
        totalRepos = repos.count
        var scanned = 0, never = 0, critical = 0, attention = 0, healthy = 0
        var alerts = 0, withAlerts = 0, failingCI = 0, unprotected = 0, stale = 0, prs = 0, issues = 0
        var localScanned = 0, uncommitted = 0, diverged = 0
        var latest: Date?

        for repo in repos {
            switch repo.health(staleAfterDays: staleAfterDays, asOf: now) {
            case .critical: critical += 1
            case .attention: attention += 1
            case .healthy: healthy += 1
            case .unknown: never += 1
            }
            if let snap = repo.snapshot {
                scanned += 1
                latest = [latest, snap.fetchedAt].compactMap { $0 }.max()
                if let total = snap.security?.openAlertTotal { alerts += total }
                if snap.security?.hasOpenAlerts == true { withAlerts += 1 }
                if snap.ciConclusion == .failure { failingCI += 1 }
                if snap.security?.defaultBranchProtected == false { unprotected += 1 }
                prs += snap.openPullRequests ?? 0
                issues += snap.openIssues ?? 0
            }
            if let days = repo.daysSincePush(asOf: now), days > staleAfterDays { stale += 1 }
            if let local = repo.local {
                localScanned += 1
                if local.hasUncommittedChanges == true { uncommitted += 1 }
                if local.syncState == .diverged { diverged += 1 }
            }
        }

        totalRepos = repos.count
        scannedRepos = scanned
        neverScanned = never
        criticalRepos = critical
        attentionRepos = attention
        healthyRepos = healthy
        openSecurityAlerts = alerts
        reposWithOpenAlerts = withAlerts
        reposWithFailingCI = failingCI
        unprotectedDefaultBranches = unprotected
        staleRepos = stale
        totalOpenPullRequests = prs
        totalOpenIssues = issues
        reposScannedLocally = localScanned
        reposWithUncommittedChanges = uncommitted
        reposDivergedFromOrigin = diverged
        lastScan = latest
        healthScore = repos.isEmpty ? nil : Int((Double(healthy) / Double(repos.count) * 100).rounded())
    }
}

/// Merges two copies of the oversight register (this device's and the cloud's) so neither can wipe
/// the other. The register only grows: every slug from either side is kept. When both sides know a
/// repository, the copy observed later wins, except that this device's own working-copy status
/// (`local`, from a folder scan on this Mac) is kept when it has one, since the cloud can only hold
/// another device's scan.
public enum OversightMerge {
    public static func merge(device: [OversightRepo], cloud: [OversightRepo]) -> [OversightRepo] {
        var bySlug: [String: OversightRepo] = [:]
        for repo in cloud { bySlug[repo.slug] = newer(bySlug[repo.slug], repo) }
        for repo in device {
            guard let other = bySlug[repo.slug] else { bySlug[repo.slug] = repo; continue }
            var winner = repo.observedAt >= other.observedAt ? repo : other
            winner.local = repo.local ?? other.local
            bySlug[repo.slug] = winner
        }
        return bySlug.values.sorted {
            let l = $0.pushedAt ?? .distantPast, r = $1.pushedAt ?? .distantPast
            return l == r ? $0.slug < $1.slug : l > r
        }
    }

    private static func newer(_ a: OversightRepo?, _ b: OversightRepo) -> OversightRepo {
        guard let a else { return b }
        return a.observedAt >= b.observedAt ? a : b
    }
}
