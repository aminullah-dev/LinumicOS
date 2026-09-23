import Foundation

/// Lifecycle status of a product. "Not known" is expressed as an unknown `Fact`, not as a case here.
public enum ProductStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case idea, development, active, maintenance, paused, retired
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: L("Idea")
        case .development: L("In Development")
        case .active: L("Active")
        case .maintenance: L("Maintenance")
        case .paused: L("Paused")
        case .retired: L("Retired")
        }
    }
}

/// How much attention a product gets. The owner decides this, and evidence can't.
public enum ProductPriority: String, Codable, CaseIterable, Sendable, Identifiable {
    case high, normal, low
    /// Parked for now ("در حاشیه"): kept in the inventory, left out of attention lists.
    case sidelined
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .high: L("High priority")
        case .normal: L("Normal priority")
        case .low: L("Low priority")
        case .sidelined: L("Sidelined")
        }
    }
}

/// A platform a product ships on. Each product/platform link is a `PlatformRecord` with its own evidence.
public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case android, iOS, macOS, windows, web, backend, desktop, watchOS, research, unknown
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .android: L("Android")
        case .iOS: L("iOS")
        case .macOS: L("macOS")
        case .windows: L("Windows")
        case .web: L("Web")
        case .backend: L("Backend")
        case .desktop: L("Desktop")
        case .watchOS: L("watchOS")
        case .research: L("Research")
        case .unknown: L("Unknown")
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
        case .monorepo: L("Monorepo")
        case .application: L("Application")
        case .backend: L("Backend")
        case .website: L("Website")
        case .releases: L("Release repository")
        case .documentation: L("Documentation")
        case .research: L("Research")
        case .infrastructure: L("Infrastructure")
        case .marketing: L("Marketing")
        case .unknown: L("Unknown")
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RepositoryType(rawValue: raw) ?? .unknown
    }
}

public enum RepositoryVisibility: String, Codable, CaseIterable, Sendable {
    case `public`, `private`, `internal`
    public var title: String { L(rawValue.capitalized) }
}

public enum AppStore: String, Codable, CaseIterable, Sendable, Identifiable {
    case appStore, googlePlay
    public var id: String { rawValue }
    public var title: String { self == .appStore ? L("App Store") : L("Google Play") }
}

/// Where a release sits in its lifecycle. Order matters: see `isUpcoming`.
public enum ReleaseStage: String, Codable, CaseIterable, Sendable, Identifiable {
    case planning, development, internalTesting, beta, review, released, deprecated, blocked
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .planning: L("Planning")
        case .development: L("Development")
        case .internalTesting: L("Internal Testing")
        case .beta: L("Beta")
        case .review: L("Review")
        case .released: L("Released")
        case .deprecated: L("Deprecated")
        case .blocked: L("Blocked")
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
    public var title: String { L(rawValue.capitalized) }
}

public enum DeploymentStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case unknown, healthy, degraded, failed, inProgress
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unknown: L("Unknown")
        case .healthy: L("Healthy")
        case .degraded: L("Degraded")
        case .failed: L("Failed")
        case .inProgress: L("In Progress")
        }
    }
}

public enum IssueSeverity: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case low, medium, high, critical
    public var id: String { rawValue }
    public var title: String { L(rawValue.capitalized) }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum RoadmapStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case idea, planned, inProgress, done, dropped
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idea: L("Idea")
        case .planned: L("Planned")
        case .inProgress: L("In Progress")
        case .done: L("Done")
        case .dropped: L("Dropped")
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
        case .linkedIn: L("LinkedIn")
        case .facebook: L("Facebook")
        case .instagram: L("Instagram")
        case .x: L("X")
        case .youTube: L("YouTube")
        }
    }
}
