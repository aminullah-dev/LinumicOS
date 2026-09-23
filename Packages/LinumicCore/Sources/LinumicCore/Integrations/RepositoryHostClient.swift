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
    }

    public enum CIConclusion: String, Codable, Sendable {
        case success, failure, cancelled, inProgress, none
    }

    public var slug: String
    public var defaultBranch: String
    public var latestCommit: Commit?
    public var openPullRequests: Int
    public var openIssues: Int
    public var latestReleaseTag: String?
    public var ciConclusion: CIConclusion?
    /// When this snapshot was fetched. Every integration datum carries a timestamp.
    public var fetchedAt: Date
}

/// Read-only access to a repository host. Write operations (push, merge,
/// delete, close) are intentionally absent from this protocol.
public protocol RepositoryHostClient: Sendable {
    func snapshot(slug: String) async throws -> RepositorySnapshot
}
