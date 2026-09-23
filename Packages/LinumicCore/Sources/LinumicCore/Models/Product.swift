import Foundation

/// A Linumic product. Every important field is a `Fact`: a value plus its evidence.
/// Unknown facts have a `nil` value and `.unknown` status. They are never filled with guesses.
public struct Product: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Whether this is a Linumic product at all.
    public var isLinumicProduct: Fact<Bool>
    /// Other names the product appears under (store names, app titles, working names).
    public var alsoKnownAs: Fact<[String]>
    public var summary: Fact<String>
    public var category: Fact<String>
    public var projectType: Fact<String>
    public var status: Fact<ProductStatus>
    public var currentVersion: Fact<String>
    public var nextVersion: Fact<String>
    public var backend: Fact<String>
    public var website: Fact<URL>
    public var repositories: [RepositoryRecord]
    public var platforms: [PlatformRecord]
    public var storeListings: [StoreListing]
    public var roadmap: [RoadmapItem]
    public var issues: [IssueRecord]
    public var releases: [Release]
    public var deployments: [Deployment]
    public var documentation: [DocumentLink]
    public var socialAccounts: [SocialAccount]
    public var analytics: [DocumentLink]
    public var notes: String
    /// Who created this record and when (not evidence for any single fact).
    public var provenance: Provenance

    public init(
        id: String, name: String,
        isLinumicProduct: Fact<Bool> = .unknown, alsoKnownAs: Fact<[String]> = .unknown,
        summary: Fact<String> = .unknown, category: Fact<String> = .unknown, projectType: Fact<String> = .unknown,
        status: Fact<ProductStatus> = .unknown, currentVersion: Fact<String> = .unknown, nextVersion: Fact<String> = .unknown,
        backend: Fact<String> = .unknown, website: Fact<URL> = .unknown,
        repositories: [RepositoryRecord] = [], platforms: [PlatformRecord] = [], storeListings: [StoreListing] = [],
        roadmap: [RoadmapItem] = [], issues: [IssueRecord] = [], releases: [Release] = [], deployments: [Deployment] = [],
        documentation: [DocumentLink] = [], socialAccounts: [SocialAccount] = [], analytics: [DocumentLink] = [],
        notes: String = "", provenance: Provenance = .manualEntry()
    ) {
        self.id = id
        self.name = name
        self.isLinumicProduct = isLinumicProduct
        self.alsoKnownAs = alsoKnownAs
        self.summary = summary
        self.category = category
        self.projectType = projectType
        self.status = status
        self.currentVersion = currentVersion
        self.nextVersion = nextVersion
        self.backend = backend
        self.website = website
        self.repositories = repositories
        self.platforms = platforms
        self.storeListings = storeListings
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

    /// Distinct platforms with at least partial evidence.
    public var evidencedPlatforms: [Platform] {
        let found = Set(platforms.filter { $0.verification.status == .verified || $0.verification.status == .partiallyVerified }.map(\.platform))
        return Platform.allCases.filter(found.contains)
    }

    public func listings(on store: AppStore) -> [StoreListing] {
        storeListings.filter { $0.store == store }
    }
}

// MARK: - Verification roll-up

/// The product fields that carry verification, in display order.
public enum ProductField: String, CaseIterable, Sendable, Identifiable {
    case isLinumicProduct, alsoKnownAs, summary, category, projectType, status, currentVersion, nextVersion, backend, website

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .isLinumicProduct: "Linumic product"
        case .alsoKnownAs: "Also known as"
        case .summary: "Description"
        case .category: "Category"
        case .projectType: "Project type"
        case .status: "Development status"
        case .currentVersion: "Current version"
        case .nextVersion: "Next version"
        case .backend: "Backend"
        case .website: "Website"
        }
    }

    /// Fields that decide a product's overall verification. The next version is a plan, not a fact to verify.
    public var isKey: Bool { self != .nextVersion && self != .alsoKnownAs }
}

/// A field's value rendered as text together with its verification, for display and roll-up.
public struct FieldState: Hashable, Sendable, Identifiable {
    public var field: ProductField
    public var displayValue: String?
    public var verification: Verification
    public var id: ProductField { field }
}

extension Product {
    public func state(of field: ProductField) -> FieldState {
        switch field {
        case .isLinumicProduct: FieldState(field: field, displayValue: isLinumicProduct.value.map { $0 ? "Yes" : "No" }, verification: isLinumicProduct.verification)
        case .alsoKnownAs: FieldState(field: field, displayValue: alsoKnownAs.value.map { $0.joined(separator: ", ") }, verification: alsoKnownAs.verification)
        case .summary: FieldState(field: field, displayValue: summary.value, verification: summary.verification)
        case .category: FieldState(field: field, displayValue: category.value, verification: category.verification)
        case .projectType: FieldState(field: field, displayValue: projectType.value, verification: projectType.verification)
        case .status: FieldState(field: field, displayValue: status.value?.title, verification: status.verification)
        case .currentVersion: FieldState(field: field, displayValue: currentVersion.value, verification: currentVersion.verification)
        case .nextVersion: FieldState(field: field, displayValue: nextVersion.value, verification: nextVersion.verification)
        case .backend: FieldState(field: field, displayValue: backend.value, verification: backend.verification)
        case .website: FieldState(field: field, displayValue: website.value?.absoluteString, verification: website.verification)
        }
    }

    public var fieldStates: [FieldState] { ProductField.allCases.map(state(of:)) }

    /// Every verification that feeds the product's overall status: the key fields, each
    /// platform, each repository link and each store listing.
    public var allVerifications: [Verification] {
        ProductField.allCases.filter(\.isKey).map { state(of: $0).verification }
            + platforms.map(\.verification)
            + repositories.map(\.link)
            + storeListings.map(\.verification)
    }

    /// VERIFIED only when everything is. CONFLICTING when anything is.
    public var overallVerification: VerificationStatus { allVerifications.map(\.status).rollUp }

    /// Most recent verification date across all evidence.
    public var lastVerifiedAt: Date? { allVerifications.compactMap(\.verifiedAt).max() }

    /// Items needing the owner's attention, conflicting first.
    public var needsConfirmation: [(label: String, verification: Verification)] {
        var items: [(String, Verification)] = []
        for s in fieldStates where s.field.isKey && s.verification.status != .verified {
            items.append((s.field.title, s.verification))
        }
        for r in repositories where r.link.status != .verified {
            items.append(("Repository \(r.name)", r.link))
        }
        for p in platforms where p.verification.status != .verified {
            items.append(("Platform \(p.platform.title)\(p.component.map { " (\($0))" } ?? "")", p.verification))
        }
        return items.sorted { $0.1.status < $1.1.status }
    }

    /// Data-integrity problems, e.g. "verified" with no source. Empty for a consistent record.
    public var integrityIssues: [String] {
        var result: [String] = []
        for s in fieldStates {
            let valueless = s.displayValue == nil
            var issues = s.verification.issues
            if valueless && (s.verification.status == .verified || s.verification.status == .partiallyVerified) {
                issues.append("\(s.verification.status.title) but the value is empty")
            }
            if !valueless && s.verification.status == .unknown {
                issues.append("Has a value but is marked Unknown")
            }
            result += issues.map { "\(s.field.title): \($0)" }
        }
        for r in repositories { result += r.link.issues.map { "Repository \(r.name): \($0)" } }
        for p in platforms { result += p.verification.issues.map { "Platform \(p.platform.title): \($0)" } }
        for l in storeListings { result += l.verification.issues.map { "\(l.store.title) listing: \($0)" } }
        return result
    }
}

// MARK: - Decoding

extension Product {
    private enum CodingKeys: String, CodingKey {
        case id, name, isLinumicProduct, alsoKnownAs, summary, category, projectType, status, currentVersion, nextVersion,
             backend, website, repositories, platforms, storeListings, roadmap, issues, releases, deployments,
             documentation, socialAccounts, analytics, notes, provenance
    }

    /// Tolerant decoding: missing facts decode as unknown and missing collections as empty,
    /// so hand-edited files and newer fields keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func fact<T>(_ key: CodingKeys) throws -> Fact<T> { try c.decodeIfPresent(Fact<T>.self, forKey: key) ?? .unknown }
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isLinumicProduct = try fact(.isLinumicProduct)
        alsoKnownAs = try fact(.alsoKnownAs)
        summary = try fact(.summary)
        category = try fact(.category)
        projectType = try fact(.projectType)
        status = try fact(.status)
        currentVersion = try fact(.currentVersion)
        nextVersion = try fact(.nextVersion)
        backend = try fact(.backend)
        website = try fact(.website)
        repositories = try c.decodeIfPresent([RepositoryRecord].self, forKey: .repositories) ?? []
        platforms = try c.decodeIfPresent([PlatformRecord].self, forKey: .platforms) ?? []
        storeListings = try c.decodeIfPresent([StoreListing].self, forKey: .storeListings) ?? []
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

/// A repository or project found during inventory work that isn't a confirmed product:
/// a possible product, or a repository with unresolved ownership.
public struct UnresolvedItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case possibleProduct, unresolvedRepository
        public var title: String { self == .possibleProduct ? "Possible product" : "Unresolved repository" }
    }

    public var id: String
    public var kind: Kind
    public var name: String
    public var location: String
    public var findings: String
    public var question: String?
    public var verification: Verification

    public init(id: String, kind: Kind, name: String, location: String, findings: String, question: String? = nil, verification: Verification) {
        self.id = id
        self.kind = kind
        self.name = name
        self.location = location
        self.findings = findings
        self.question = question
        self.verification = verification
    }
}

/// The whole persisted inventory. `schemaVersion` allows future migrations.
/// Newer optional sections (market intelligence, content) decode as empty when absent.
public struct Inventory: Codable, Hashable, Sendable {
    /// v2: facts with verification, multiple typed repositories, platform records, store listings.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var products: [Product]
    public var unresolved: [UnresolvedItem]
    public var market: MarketIntelligence
    public var content: [ContentItem]

    public init(schemaVersion: Int = Inventory.currentSchemaVersion, products: [Product] = [], unresolved: [UnresolvedItem] = [],
                market: MarketIntelligence = MarketIntelligence(), content: [ContentItem] = []) {
        self.schemaVersion = schemaVersion
        self.products = products
        self.unresolved = unresolved
        self.market = market
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, products, unresolved, market, content }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        products = try c.decodeIfPresent([Product].self, forKey: .products) ?? []
        unresolved = try c.decodeIfPresent([UnresolvedItem].self, forKey: .unresolved) ?? []
        market = try c.decodeIfPresent(MarketIntelligence.self, forKey: .market) ?? MarketIntelligence()
        content = try c.decodeIfPresent([ContentItem].self, forKey: .content) ?? []
    }
}
// MARK: - Editing

extension Product {
    /// Sets a field from text entered by a person, with the verification they chose.
    /// Empty text clears the value. Returns false if the text can't be parsed for this field
    /// (e.g. an invalid URL or unknown status). The product is left unchanged in that case.
    @discardableResult
    public mutating func setField(_ field: ProductField, text: String?, verification: Verification) -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        switch field {
        case .isLinumicProduct:
            guard let value else { isLinumicProduct = Fact(nil, verification); return true }
            guard let flag = ["yes": true, "no": false][value.lowercased()] else { return false }
            isLinumicProduct = Fact(flag, verification)
        case .alsoKnownAs:
            let names = value?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            alsoKnownAs = Fact(names?.isEmpty == false ? names : nil, verification)
        case .summary: summary = Fact(value, verification)
        case .category: category = Fact(value, verification)
        case .projectType: projectType = Fact(value, verification)
        case .status:
            guard let value else { status = Fact(nil, verification); return true }
            guard let parsed = ProductStatus(rawValue: value) ?? ProductStatus.allCases.first(where: { $0.title == value }) else { return false }
            status = Fact(parsed, verification)
        case .currentVersion: currentVersion = Fact(value, verification)
        case .nextVersion: nextVersion = Fact(value, verification)
        case .backend: backend = Fact(value, verification)
        case .website:
            guard let value else { website = Fact(nil, verification); return true }
            guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true else { return false }
            website = Fact(url, verification)
        }
        return true
    }
}
