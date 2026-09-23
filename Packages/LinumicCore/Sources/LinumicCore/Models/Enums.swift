import Foundation

/// Lifecycle status of a product. "Not known" is expressed as an unknown `Fact`, not as a case here.
public enum ProductStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case idea, development, active, maintenance, paused, retired
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: "Idea"
        case .development: "In Development"
        case .active: "Active"
        case .maintenance: "Maintenance"
        case .paused: "Paused"
        case .retired: "Retired"
        }
    }
}

/// A platform a product ships on. Each product/platform link is a `PlatformRecord` with its own evidence.
public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case android, iOS, macOS, windows, web, backend, desktop, watchOS, research, unknown
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .android: "Android"
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .windows: "Windows"
        case .web: "Web"
        case .backend: "Backend"
        case .desktop: "Desktop"
        case .watchOS: "watchOS"
        case .research: "Research"
        case .unknown: "Unknown"
        }
    }

    /// Values this build doesn't know (e.g. from a newer file) decode as `.unknown` and don't fail.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Platform(rawValue: raw) ?? .unknown
    }
}

/// What a repository is for. A product can have several repositories of different types.
public enum RepositoryType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Several components (apps, backend, web) in one repository.
    case monorepo
    case application, backend, website, releases, documentation, research, infrastructure, marketing, unknown
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monorepo: "Monorepo"
        case .application: "Application"
        case .backend: "Backend"
        case .website: "Website"
        case .releases: "Release repository"
        case .documentation: "Documentation"
        case .research: "Research"
        case .infrastructure: "Infrastructure"
        case .marketing: "Marketing"
        case .unknown: "Unknown"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RepositoryType(rawValue: raw) ?? .unknown
    }
}

public enum RepositoryVisibility: String, Codable, CaseIterable, Sendable {
    case `public`, `private`, `internal`
    public var title: String { rawValue.capitalized }
}

public enum AppStore: String, Codable, CaseIterable, Sendable, Identifiable {
    case appStore, googlePlay
    public var id: String { rawValue }
    public var title: String { self == .appStore ? "App Store" : "Google Play" }
}

/// Where a release sits in its lifecycle. Order matters: see `isUpcoming`.
public enum ReleaseStage: String, Codable, CaseIterable, Sendable, Identifiable {
    case planning, development, internalTesting, beta, review, released, deprecated, blocked
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .planning: "Planning"
        case .development: "Development"
        case .internalTesting: "Internal Testing"
        case .beta: "Beta"
        case .review: "Review"
        case .released: "Released"
        case .deprecated: "Deprecated"
        case .blocked: "Blocked"
        }
    }

    /// Stages for a release that hasn't shipped yet and is still moving forward or blocked.
    public var isUpcoming: Bool {
        switch self {
        case .planning, .development, .internalTesting, .beta, .review, .blocked: true
        case .released, .deprecated: false
        }
    }
}

public enum DeploymentEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case development, staging, production
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum DeploymentStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case unknown, healthy, degraded, failed, inProgress
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unknown: "Unknown"
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .failed: "Failed"
        case .inProgress: "In Progress"
        }
    }
}

public enum IssueSeverity: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case low, medium, high, critical
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum RoadmapStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case idea, planned, inProgress, done, dropped
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: "Idea"
        case .planned: "Planned"
        case .inProgress: "In Progress"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }
}

public enum RepositoryHost: String, Codable, CaseIterable, Sendable {
    case github, other
}

public enum SocialNetwork: String, Codable, CaseIterable, Sendable, Identifiable {
    case linkedIn, facebook, instagram, x, youTube
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .linkedIn: "LinkedIn"
        case .facebook: "Facebook"
        case .instagram: "Instagram"
        case .x: "X"
        case .youTube: "YouTube"
        }
    }
}
