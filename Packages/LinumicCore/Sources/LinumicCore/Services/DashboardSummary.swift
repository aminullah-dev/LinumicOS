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
    public var countsByStatus: [ProductStatus: Int]
    /// Products whose status has not been verified yet.
    public var unknownStatusCount: Int
    public var currentReleases: [ReleaseRef]
    public var upcomingReleases: [ReleaseRef]
    public var blockedReleases: [ReleaseRef]
    public var openCriticalIssues: [IssueRef]
    public var deploymentsByStatus: [DeploymentStatus: Int]
    public var productsWithRepositories: Int
    public var productsWithAppStoreListing: Int
    public var productsWithGooglePlayListing: Int

    public var activeCount: Int { countsByStatus[.active, default: 0] }
    public var inDevelopmentCount: Int { countsByStatus[.development, default: 0] }

    public init(products: [Product]) {
        totalProducts = products.count
        countsByStatus = Dictionary(grouping: products, by: \.status).mapValues(\.count)
        unknownStatusCount = countsByStatus[.unknown, default: 0]

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
        productsWithAppStoreListing = products.count { $0.appStore != nil }
        productsWithGooglePlayListing = products.count { $0.googlePlay != nil }
    }
}
