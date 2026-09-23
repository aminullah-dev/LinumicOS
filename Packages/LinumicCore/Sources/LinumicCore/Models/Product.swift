import Foundation

/// A Linumic product. Optional fields are `nil` when the fact is unknown. Never fill them with guesses.
public struct Product: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String?
    public var category: String?
    public var status: ProductStatus
    public var repositories: [RepositoryRecord]
    public var platforms: [Platform]
    public var currentVersion: String?
    public var nextVersion: String?
    public var backend: String?
    public var website: URL?
    public var appStore: StoreListing?
    public var googlePlay: StoreListing?
    public var roadmap: [RoadmapItem]
    public var issues: [IssueRecord]
    public var releases: [Release]
    public var deployments: [Deployment]
    public var documentation: [DocumentLink]
    public var socialAccounts: [SocialAccount]
    public var analytics: [DocumentLink]
    public var notes: String
    public var provenance: Provenance

    public init(
        id: String, name: String, summary: String? = nil, category: String? = nil,
        status: ProductStatus = .unknown, repositories: [RepositoryRecord] = [], platforms: [Platform] = [],
        currentVersion: String? = nil, nextVersion: String? = nil, backend: String? = nil, website: URL? = nil,
        appStore: StoreListing? = nil, googlePlay: StoreListing? = nil, roadmap: [RoadmapItem] = [],
        issues: [IssueRecord] = [], releases: [Release] = [], deployments: [Deployment] = [],
        documentation: [DocumentLink] = [], socialAccounts: [SocialAccount] = [], analytics: [DocumentLink] = [],
        notes: String = "", provenance: Provenance = .manualEntry()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.status = status
        self.repositories = repositories
        self.platforms = platforms
        self.currentVersion = currentVersion
        self.nextVersion = nextVersion
        self.backend = backend
        self.website = website
        self.appStore = appStore
        self.googlePlay = googlePlay
        self.roadmap = roadmap
        self.issues = issues
        self.releases = releases
        self.deployments = deployments
        self.documentation = documentation
        self.socialAccounts = socialAccounts
        self.analytics = analytics
        self.notes = notes
        self.provenance = provenance
    }

    /// Builds a URL-safe identifier from a product name, e.g. "Safe Beauty" -> "safe-beauty".
    public static func slug(for name: String) -> String {
        let parts = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return parts.joined(separator: "-")
    }

    public var openIssues: [IssueRecord] { issues.filter(\.isOpen) }
    public var openCriticalIssues: [IssueRecord] { issues.filter { $0.isOpen && $0.severity == .critical } }
    public var upcomingReleases: [Release] { releases.filter { $0.stage.isUpcoming } }
    public var latestReleased: Release? {
        releases.filter { $0.stage == .released }
            .max { ($0.releaseDate ?? .distantPast) < ($1.releaseDate ?? .distantPast) }
    }
}

extension Product {
    private enum CodingKeys: String, CodingKey {
        case id, name, summary, category, status, repositories, platforms, currentVersion, nextVersion,
             backend, website, appStore, googlePlay, roadmap, issues, releases, deployments,
             documentation, socialAccounts, analytics, notes, provenance
    }

    /// Tolerant decoding: missing collections default to empty and a missing status to `.unknown`,
    /// so older files and hand-edited seed data keep loading as the schema grows.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        status = try c.decodeIfPresent(ProductStatus.self, forKey: .status) ?? .unknown
        repositories = try c.decodeIfPresent([RepositoryRecord].self, forKey: .repositories) ?? []
        platforms = try c.decodeIfPresent([Platform].self, forKey: .platforms) ?? []
        currentVersion = try c.decodeIfPresent(String.self, forKey: .currentVersion)
        nextVersion = try c.decodeIfPresent(String.self, forKey: .nextVersion)
        backend = try c.decodeIfPresent(String.self, forKey: .backend)
        website = try c.decodeIfPresent(URL.self, forKey: .website)
        appStore = try c.decodeIfPresent(StoreListing.self, forKey: .appStore)
        googlePlay = try c.decodeIfPresent(StoreListing.self, forKey: .googlePlay)
        roadmap = try c.decodeIfPresent([RoadmapItem].self, forKey: .roadmap) ?? []
        issues = try c.decodeIfPresent([IssueRecord].self, forKey: .issues) ?? []
        releases = try c.decodeIfPresent([Release].self, forKey: .releases) ?? []
        deployments = try c.decodeIfPresent([Deployment].self, forKey: .deployments) ?? []
        documentation = try c.decodeIfPresent([DocumentLink].self, forKey: .documentation) ?? []
        socialAccounts = try c.decodeIfPresent([SocialAccount].self, forKey: .socialAccounts) ?? []
        analytics = try c.decodeIfPresent([DocumentLink].self, forKey: .analytics) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        provenance = try c.decode(Provenance.self, forKey: .provenance)
    }
}

/// The whole persisted inventory. `schemaVersion` allows future migrations.
public struct Inventory: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var products: [Product]

    public init(schemaVersion: Int = Inventory.currentSchemaVersion, products: [Product] = []) {
        self.schemaVersion = schemaVersion
        self.products = products
    }
}
