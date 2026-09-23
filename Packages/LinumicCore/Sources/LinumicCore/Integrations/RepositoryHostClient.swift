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
    /// When this snapshot was fetched. Every integration datum carries a timestamp.
    public var fetchedAt: Date

    public init(
        slug: String, visibility: RepositoryVisibility? = nil, description: String? = nil, homepage: URL? = nil,
        defaultBranch: String, latestCommit: Commit? = nil, releaseCount: Int? = nil, latestRelease: ReleaseInfo? = nil,
        openPullRequests: Int? = nil, openIssues: Int? = nil, languages: [String] = [], ciConclusion: CIConclusion? = nil,
        fetchedAt: Date
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
        self.fetchedAt = fetchedAt
    }
}

/// Read-only access to a repository host. Write operations (push, merge,
/// delete, close) are intentionally absent from this protocol.
public protocol RepositoryHostClient: Sendable {
    func snapshot(slug: String) async throws -> RepositorySnapshot
}
