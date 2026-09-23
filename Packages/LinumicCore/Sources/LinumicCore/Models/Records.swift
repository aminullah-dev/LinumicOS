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

public struct RepositoryRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: URL?
    public var host: RepositoryHost
    public var defaultBranch: String?

    public init(id: UUID = UUID(), name: String, url: URL? = nil, host: RepositoryHost = .github, defaultBranch: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.host = host
        self.defaultBranch = defaultBranch
    }

    /// `owner/name` parsed from a GitHub URL, if this is one.
    public var gitHubSlug: String? {
        guard host == .github, let url, url.host() == "github.com" else { return nil }
        let parts = url.path().split(separator: "/").prefix(2)
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/").replacingOccurrences(of: ".git", with: "")
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

public struct StoreListing: Codable, Hashable, Sendable {
    public var url: URL?
    public var productionVersion: String?
    public var latestSubmittedVersion: String?
    public var reviewStatus: String?
    public var lastChecked: Date?

    public init(url: URL? = nil, productionVersion: String? = nil, latestSubmittedVersion: String? = nil, reviewStatus: String? = nil, lastChecked: Date? = nil) {
        self.url = url
        self.productionVersion = productionVersion
        self.latestSubmittedVersion = latestSubmittedVersion
        self.reviewStatus = reviewStatus
        self.lastChecked = lastChecked
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
