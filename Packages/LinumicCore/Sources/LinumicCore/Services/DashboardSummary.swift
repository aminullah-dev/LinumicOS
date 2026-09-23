import Foundation

/// Metrics computed from the inventory. They are derived analysis, not stored facts.
public struct DashboardSummary: Equatable, Sendable {
    public struct ReleaseRef: Equatable, Sendable, Identifiable {
        public var productID: String
        public var productName: String
        public var release: Release
        public var id: UUID { release.id }
    }

    public struct IssueRef: Equatable, Sendable, Identifiable {
        public var productID: String
        public var productName: String
        public var issue: IssueRecord
        public var id: UUID { issue.id }
    }

    public var totalProducts: Int
    /// Counts by recorded development status (products with an unknown status are excluded).
    public var countsByStatus: [ProductStatus: Int]
    /// Products whose development status is not known.
    public var unknownStatusCount: Int
    /// Products by overall verification (VERIFIED / PARTIALLY / UNKNOWN / CONFLICTING).
    public var countsByVerification: [VerificationStatus: Int]
    /// Fields, platforms and repository links still awaiting confirmation, across all products.
    public var pendingConfirmations: Int
    public var conflictingItems: Int
    public var currentReleases: [ReleaseRef]
    public var upcomingReleases: [ReleaseRef]
    public var blockedReleases: [ReleaseRef]
    public var openCriticalIssues: [IssueRef]
    public var deploymentsByStatus: [DeploymentStatus: Int]
    public var productsWithRepositories: Int
    /// Products with at least one live App Store version backed by evidence.
    public var productsWithAppStoreListing: Int
    public var productsWithGooglePlayListing: Int

    public var activeCount: Int { countsByStatus[.active, default: 0] }
    public var inDevelopmentCount: Int { countsByStatus[.development, default: 0] }

    public init(products: [Product]) {
        totalProducts = products.count
        countsByStatus = Dictionary(grouping: products.compactMap(\.status.value), by: { $0 }).mapValues(\.count)
        unknownStatusCount = products.count { $0.status.value == nil }
        countsByVerification = Dictionary(grouping: products, by: \.overallVerification).mapValues(\.count)
        let pending = products.flatMap(\.needsConfirmation)
        pendingConfirmations = pending.count
        conflictingItems = pending.count { $0.verification.status == .conflicting }

        currentReleases = products.compactMap { p in
            p.latestReleased.map { ReleaseRef(productID: p.id, productName: p.name, release: $0) }
        }.sorted { ($0.release.releaseDate ?? .distantPast) > ($1.release.releaseDate ?? .distantPast) }

        let upcoming = products.flatMap { p in
            p.upcomingReleases.map { ReleaseRef(productID: p.id, productName: p.name, release: $0) }
        }
        // Dated releases first, soonest first. Releases with no date go last.
        upcomingReleases = upcoming.sorted {
            ($0.release.releaseDate ?? .distantFuture) < ($1.release.releaseDate ?? .distantFuture)
        }
        blockedReleases = upcomingReleases.filter { $0.release.stage == .blocked }

        openCriticalIssues = products.flatMap { p in
            p.openCriticalIssues.map { IssueRef(productID: p.id, productName: p.name, issue: $0) }
        }

        deploymentsByStatus = Dictionary(grouping: products.flatMap(\.deployments), by: \.status).mapValues(\.count)
        productsWithRepositories = products.count { !$0.repositories.isEmpty }
        // Only a live (production) version counts. Apps in review or closed testing aren't "on" the store yet.
        func hasEvidencedListing(_ p: Product, _ store: AppStore) -> Bool {
            p.listings(on: store).contains {
                $0.productionVersion != nil && ($0.verification.status == .verified || $0.verification.status == .partiallyVerified)
            }
        }
        productsWithAppStoreListing = products.count { hasEvidencedListing($0, .appStore) }
        productsWithGooglePlayListing = products.count { hasEvidencedListing($0, .googlePlay) }
    }
}
