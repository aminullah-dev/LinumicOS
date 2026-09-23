import Foundation

/// Lifecycle status of a product. `.unknown` means nobody has verified it yet.
public enum ProductStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case unknown, idea, development, active, maintenance, paused, retired
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unknown: "Unknown"
        case .idea: "Idea"
        case .development: "In Development"
        case .active: "Active"
        case .maintenance: "Maintenance"
        case .paused: "Paused"
        case .retired: "Retired"
        }
    }
}

public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case macOS, iOS, iPadOS, android, web, windows, linux, backend
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .iPadOS: "iPadOS"
        case .android: "Android"
        case .web: "Web"
        case .windows: "Windows"
        case .linux: "Linux"
        case .backend: "Backend"
        }
    }
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
