import Foundation

/// Read-only status of a working copy on this Mac, parsed directly from the `.git` directory.
/// The app is sandboxed and cannot run `git`, so only facts that can be read exactly from the
/// repository's own files are reported. Anything that would need a full git implementation
/// (exact ahead/behind counts, untracked-file detection that honours `.gitignore`) is left out
/// and shown as Unknown rather than guessed.
public struct LocalGitStatus: Codable, Hashable, Sendable {
    /// Absolute path of the working copy (the folder that contains `.git`).
    public var path: String
    /// `owner/name` parsed from the `origin` remote, when it is a GitHub remote.
    public var originSlug: String?
    /// Current branch, or `nil` when detached or unreadable.
    public var branch: String?
    public var isDetached: Bool
    /// The local branch tip commit (SHA).
    public var localTip: String?
    /// The tracked `origin/<branch>` tip as of the last fetch (SHA). `nil` when no such ref exists.
    public var remoteTip: String?
    /// Exact count of tracked files whose working content differs from the index (compared by git
    /// blob SHA, not by timestamp). `nil` when the index could not be read (e.g. an unsupported
    /// index version), which is reported as Unknown.
    public var modifiedTrackedFiles: Int?
    public var scannedAt: Date

    public init(
        path: String, originSlug: String? = nil, branch: String? = nil, isDetached: Bool = false,
        localTip: String? = nil, remoteTip: String? = nil, modifiedTrackedFiles: Int? = nil, scannedAt: Date = .now
    ) {
        self.path = path
        self.originSlug = originSlug
        self.branch = branch
        self.isDetached = isDetached
        self.localTip = localTip
        self.remoteTip = remoteTip
        self.modifiedTrackedFiles = modifiedTrackedFiles
        self.scannedAt = scannedAt
    }

    /// How the local branch stands against its tracked remote ref, as of the last fetch. This is a
    /// tip comparison, not a graph walk, so it reports "diverged" without a direction.
    public enum SyncState: String, Codable, Sendable {
        case inSync        // local tip == remote tip
        case diverged      // local tip != remote tip (unpushed and/or unfetched work)
        case noRemoteRef   // no origin/<branch> ref to compare against
        case unknown       // local tip itself could not be read

        public var title: String {
            switch self {
            case .inSync: L("In sync with origin")
            case .diverged: L("Diverged from origin")
            case .noRemoteRef: L("No remote branch")
            case .unknown: L("Unknown")
            }
        }
    }

    public var syncState: SyncState {
        guard let localTip else { return .unknown }
        guard let remoteTip else { return .noRemoteRef }
        return localTip == remoteTip ? .inSync : .diverged
    }

    /// True when there are tracked files with uncommitted changes. `nil` when the index was unreadable.
    public var hasUncommittedChanges: Bool? {
        modifiedTrackedFiles.map { $0 > 0 }
    }
}
