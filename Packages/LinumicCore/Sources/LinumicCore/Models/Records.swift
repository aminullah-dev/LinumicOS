import Foundation

/// Where a record's facts came from and when they were recorded.
public struct Provenance: Codable, Hashable, Sendable {
    public var source: String
    public var recordedAt: Date

    public init(source: String, recordedAt: Date = .now) {
        self.source = source
        self.recordedAt = recordedAt
    }

    public static func manualEntry(at date: Date = .now) -> Provenance {
        Provenance(source: "Manual entry", recordedAt: date)
    }
}

/// A working copy of a repository on this Mac, observed read-only.
public struct LocalCheckout: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var branch: String?
    public var lastCommit: RepositorySnapshot.Commit?
    public var observedAt: Date
    public var notes: String
    public var id: String { path }

    public init(path: String, branch: String? = nil, lastCommit: RepositorySnapshot.Commit? = nil, observedAt: Date = .now, notes: String = "") {
        self.path = path
        self.branch = branch
        self.lastCommit = lastCommit
        self.observedAt = observedAt
        self.notes = notes
    }
}

/// A repository linked to a product. One product can have many repositories, and the
/// link itself carries evidence (`link`), because a repository can exist without
/// its product relationship being confirmed.
public struct RepositoryRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var owner: String?
    public var url: URL?
    public var host: RepositoryHost
    public var type: RepositoryType
    /// Evidence that this repository belongs to the product.
    public var link: Verification
    /// Latest read-only observation from GitHub, if any.
    public var gitHub: RepositorySnapshot?
    public var localCheckouts: [LocalCheckout]
    public var notes: String

    public init(
        id: UUID = UUID(), name: String, owner: String? = nil, url: URL? = nil, host: RepositoryHost = .github,
        type: RepositoryType = .unknown, link: Verification = .unknown, gitHub: RepositorySnapshot? = nil,
        localCheckouts: [LocalCheckout] = [], notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.url = url
        self.host = host
        self.type = type
        self.link = link
        self.gitHub = gitHub
        self.localCheckouts = localCheckouts
        self.notes = notes
    }

    /// `owner/name` parsed from a GitHub URL, if this is one.
    public var gitHubSlug: String? {
        guard host == .github, let url, url.host() == "github.com" else { return nil }
        let parts = url.path().split(separator: "/").prefix(2)
        guard parts.count == 2 else { return nil }
        let slug = parts.joined(separator: "/")
        // Strip only a trailing ".git": "nerkhtimes.github.io" contains ".git" in the middle.
        return slug.hasSuffix(".git") ? String(slug.dropLast(4)) : slug
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, owner, url, host, type, link, gitHub, localCheckouts, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        host = try c.decodeIfPresent(RepositoryHost.self, forKey: .host) ?? .github
        type = try c.decodeIfPresent(RepositoryType.self, forKey: .type) ?? .unknown
        link = try c.decodeIfPresent(Verification.self, forKey: .link) ?? .unknown
        gitHub = try c.decodeIfPresent(RepositorySnapshot.self, forKey: .gitHub)
        localCheckouts = try c.decodeIfPresent([LocalCheckout].self, forKey: .localCheckouts) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// A product running on a platform. It needs evidence (a build config, a store listing),
/// not a folder name.
public struct PlatformRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var platform: Platform
    /// Which part of the product, e.g. "Passenger app", "Admin console".
    public var component: String?
    /// Bundle ID / application ID / package name, when one exists.
    public var identifier: String?
    /// Version declared in the build configuration (not necessarily released).
    public var sourceVersion: String?
    public var verification: Verification

    public init(id: UUID = UUID(), platform: Platform, component: String? = nil, identifier: String? = nil, sourceVersion: String? = nil, verification: Verification) {
        self.id = id
        self.platform = platform
        self.component = component
        self.identifier = identifier
        self.sourceVersion = sourceVersion
        self.verification = verification
    }
}

public struct Release: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var version: String
    public var buildNumber: String?
    public var platform: Platform
    public var environment: DeploymentEnvironment
    public var stage: ReleaseStage
    public var isReleaseCandidate: Bool
    public var releaseDate: Date?
    public var notes: String

    public init(
        id: UUID = UUID(), version: String, buildNumber: String? = nil, platform: Platform,
        environment: DeploymentEnvironment = .production, stage: ReleaseStage = .planning,
        isReleaseCandidate: Bool = false, releaseDate: Date? = nil, notes: String = ""
    ) {
        self.id = id
        self.version = version
        self.buildNumber = buildNumber
        self.platform = platform
        self.environment = environment
        self.stage = stage
        self.isReleaseCandidate = isReleaseCandidate
        self.releaseDate = releaseDate
        self.notes = notes
    }
}

public struct RoadmapItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var status: RoadmapStatus
    public var targetVersion: String?
    public var targetDate: Date?

    public init(id: UUID = UUID(), title: String, detail: String = "", status: RoadmapStatus = .planned, targetVersion: String? = nil, targetDate: Date? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.targetVersion = targetVersion
        self.targetDate = targetDate
    }
}

public struct IssueRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var severity: IssueSeverity
    public var isOpen: Bool
    public var url: URL?

    public init(id: UUID = UUID(), title: String, severity: IssueSeverity = .medium, isOpen: Bool = true, url: URL? = nil) {
        self.id = id
        self.title = title
        self.severity = severity
        self.isOpen = isOpen
        self.url = url
    }
}

public struct Deployment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var environment: DeploymentEnvironment
    public var target: String
    public var status: DeploymentStatus
    public var version: String?
    public var deployedAt: Date?

    public init(id: UUID = UUID(), environment: DeploymentEnvironment, target: String, status: DeploymentStatus = .unknown, version: String? = nil, deployedAt: Date? = nil) {
        self.id = id
        self.environment = environment
        self.target = target
        self.status = status
        self.version = version
        self.deployedAt = deployedAt
    }
}

/// One app on one store. A product can have several (e.g. separate passenger and driver apps).
public struct StoreListing: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var store: AppStore
    public var appName: String?
    /// Bundle ID or application ID.
    public var appIdentifier: String?
    public var url: URL?
    public var storefront: String?
    public var seller: String?
    public var productionVersion: String?
    public var latestSubmittedVersion: String?
    public var reviewStatus: String?
    public var verification: Verification

    public init(
        id: UUID = UUID(), store: AppStore, appName: String? = nil, appIdentifier: String? = nil, url: URL? = nil,
        storefront: String? = nil, seller: String? = nil, productionVersion: String? = nil,
        latestSubmittedVersion: String? = nil, reviewStatus: String? = nil, verification: Verification = .unknown
    ) {
        self.id = id
        self.store = store
        self.appName = appName
        self.appIdentifier = appIdentifier
        self.url = url
        self.storefront = storefront
        self.seller = seller
        self.productionVersion = productionVersion
        self.latestSubmittedVersion = latestSubmittedVersion
        self.reviewStatus = reviewStatus
        self.verification = verification
    }
}

public struct SocialAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var network: SocialNetwork
    public var handle: String
    public var url: URL?

    public init(id: UUID = UUID(), network: SocialNetwork, handle: String, url: URL? = nil) {
        self.id = id
        self.network = network
        self.handle = handle
        self.url = url
    }
}

public struct DocumentLink: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// A coarse phase read from a listing's free-text review status, for scanning a table at a glance.
/// The full text stays the source of truth and is shown alongside.
public enum ReviewPhase: String, Sendable, CaseIterable {
    case live, pending, testing, rejected, unknown

    public var title: String {
        switch self {
        case .live: L("Live")
        case .pending: L("Pending review")
        case .testing: L("Testing")
        case .rejected: L("Rejected")
        case .unknown: L("Unknown")
        }
    }

    public init(reviewStatus: String?) {
        guard let text = reviewStatus?.lowercased(), !text.isEmpty else { self = .unknown; return }
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("rejected", "not approved") { self = .rejected }
        else if has("nothing pending") { self = .live }
        else if has("pending", "in review", "waiting", "draft", "prepare", "ready for review", "not published", "not sent") { self = .pending }
        else if has("testing", "alpha", "beta", "internal") { self = .testing }
        else if has("live", "available", "published", "ready for distribution", "ready for sale") { self = .live }
        else { self = .unknown }
    }
}

extension StoreListing {
    public var reviewPhase: ReviewPhase { ReviewPhase(reviewStatus: reviewStatus) }
}
