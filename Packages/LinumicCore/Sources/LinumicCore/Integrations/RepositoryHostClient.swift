import Foundation

// GitHub integration boundary (Phase 2). Only the contract is defined here.
// There is deliberately no implementation yet: no fake data and no calls
// without a user-provided token. See docs/integrations.md.

/// A point-in-time, read-only view of a hosted repository.
public struct RepositorySnapshot: Codable, Hashable, Sendable {
    public struct Commit: Codable, Hashable, Sendable {
        public var sha: String
        public var message: String
        public var author: String?
        public var date: Date?

        public init(sha: String, message: String, author: String? = nil, date: Date? = nil) {
            self.sha = sha
            self.message = message
            self.author = author
            self.date = date
        }
    }

    public struct ReleaseInfo: Codable, Hashable, Sendable {
        public var tag: String
        public var name: String?
        public var publishedAt: Date?
        public var assets: [String]

        public init(tag: String, name: String? = nil, publishedAt: Date? = nil, assets: [String] = []) {
            self.tag = tag
            self.name = name
            self.publishedAt = publishedAt
            self.assets = assets
        }
    }

    public enum CIConclusion: String, Codable, Sendable {
        case success, failure, cancelled, inProgress, none
    }

    /// Read-only security posture from GitHub. Every count is optional: `nil` means the
    /// datum could not be read (the feature is off, or the token lacks the scope), never zero.
    /// This keeps the no-invented-data rule: an unreadable fact is Unknown, not "clean".
    public struct Security: Codable, Hashable, Sendable {
        /// Open Dependabot (vulnerable-dependency) alerts.
        public var dependabotAlerts: Int?
        /// Open secret-scanning alerts (leaked credentials).
        public var secretScanningAlerts: Int?
        /// Open code-scanning (CodeQL) alerts.
        public var codeScanningAlerts: Int?
        /// Whether the default branch has a protection rule.
        public var defaultBranchProtected: Bool?
        public var observedAt: Date

        public init(
            dependabotAlerts: Int? = nil, secretScanningAlerts: Int? = nil,
            codeScanningAlerts: Int? = nil, defaultBranchProtected: Bool? = nil, observedAt: Date
        ) {
            self.dependabotAlerts = dependabotAlerts
            self.secretScanningAlerts = secretScanningAlerts
            self.codeScanningAlerts = codeScanningAlerts
            self.defaultBranchProtected = defaultBranchProtected
            self.observedAt = observedAt
        }

        /// Total open alerts across the readable categories; `nil` only when none were readable.
        public var openAlertTotal: Int? {
            let readable = [dependabotAlerts, secretScanningAlerts, codeScanningAlerts].compactMap { $0 }
            return readable.isEmpty ? nil : readable.reduce(0, +)
        }

        /// True when any readable category has at least one open alert.
        public var hasOpenAlerts: Bool { (openAlertTotal ?? 0) > 0 }
    }

    /// A lightweight entry from the owner's repository list, before a full snapshot is fetched.
    public struct Listing: Codable, Hashable, Sendable, Identifiable {
        public var slug: String
        public var isPrivate: Bool
        public var isArchived: Bool
        public var pushedAt: Date?
        public var id: String { slug }

        public init(slug: String, isPrivate: Bool, isArchived: Bool, pushedAt: Date? = nil) {
            self.slug = slug
            self.isPrivate = isPrivate
            self.isArchived = isArchived
            self.pushedAt = pushedAt
        }
    }

    public var slug: String
    public var visibility: RepositoryVisibility?
    public var description: String?
    public var homepage: URL?
    public var defaultBranch: String
    public var latestCommit: Commit?
    public var releaseCount: Int?
    public var latestRelease: ReleaseInfo?
    public var openPullRequests: Int?
    public var openIssues: Int?
    /// Languages by bytes, largest first.
    public var languages: [String]
    public var ciConclusion: CIConclusion?
    /// Read-only security posture, if any of it was readable.
    public var security: Security?
    /// When this snapshot was fetched. Every integration datum carries a timestamp.
    public var fetchedAt: Date

    public init(
        slug: String, visibility: RepositoryVisibility? = nil, description: String? = nil, homepage: URL? = nil,
        defaultBranch: String, latestCommit: Commit? = nil, releaseCount: Int? = nil, latestRelease: ReleaseInfo? = nil,
        openPullRequests: Int? = nil, openIssues: Int? = nil, languages: [String] = [], ciConclusion: CIConclusion? = nil,
        security: Security? = nil, fetchedAt: Date
    ) {
        self.slug = slug
        self.visibility = visibility
        self.description = description
        self.homepage = homepage
        self.defaultBranch = defaultBranch
        self.latestCommit = latestCommit
        self.releaseCount = releaseCount
        self.latestRelease = latestRelease
        self.openPullRequests = openPullRequests
        self.openIssues = openIssues
        self.languages = languages
        self.ciConclusion = ciConclusion
        self.security = security
        self.fetchedAt = fetchedAt
    }
}

/// Read-only access to a repository host. Write operations (push, merge,
/// delete, close) are intentionally absent from this protocol.
public protocol RepositoryHostClient: Sendable {
    func snapshot(slug: String) async throws -> RepositorySnapshot
}
