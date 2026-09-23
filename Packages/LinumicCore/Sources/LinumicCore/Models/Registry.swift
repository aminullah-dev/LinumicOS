import Foundation

// The product registry's vocabulary over the stored model. Everything here is derived from
// stored evidence, so nothing can drift out of sync with it.

// MARK: - Repository

extension RepositoryRecord {
    /// First working copy on this Mac, if one was observed.
    public var localPath: String? { localCheckouts.first?.path }
    public var visibility: RepositoryVisibility? { gitHub?.visibility }
    public var defaultBranch: String? { gitHub?.defaultBranch }
    public var repositoryDescription: String? { gitHub?.description }
    public var repositoryType: RepositoryType { type }

    /// The newest commit seen, from GitHub or a local working copy.
    public var latestCommit: RepositorySnapshot.Commit? {
        ([gitHub?.latestCommit] + localCheckouts.map(\.lastCommit))
            .compactMap { $0 }
            .max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    public var latestCommitDate: Date? { latestCommit?.date }

    /// Whether this repository is confirmed to belong to its product.
    public var verificationState: VerificationStatus { link.status }
    public var lastVerifiedAt: Date? { link.verifiedAt }
    /// Most recent evidence for the product relationship.
    public var source: Source? { link.sources.max { $0.observedAt < $1.observedAt } }

    /// References that identify this repository inside other evidence: its checkout paths and GitHub slug.
    var evidenceKeys: [String] {
        localCheckouts.map(\.path) + [gitHubSlug].compactMap { $0 }
    }
}

// MARK: - Product

/// A group of verifications on a product page.
public enum VerificationArea: String, CaseIterable, Sendable, Identifiable {
    case facts, repositories, platforms, stores

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .facts: L("Product facts")
        case .repositories: L("Repositories")
        case .platforms: L("Platforms")
        case .stores: L("Store listings")
        }
    }
}

/// How one area of a product is verified: counts per status and the area's roll-up.
public struct AreaVerification: Hashable, Sendable, Identifiable {
    public var area: VerificationArea
    public var counts: [VerificationStatus: Int]
    public var id: VerificationArea { area }

    public var total: Int { counts.values.reduce(0, +) }
    public func count(_ status: VerificationStatus) -> Int { counts[status, default: 0] }

    /// Unknown for an empty area: having no store listing is not evidence of anything.
    public var status: VerificationStatus {
        counts.flatMap { Array(repeating: $0.key, count: $0.value) }.rollUp
    }
}

extension Product {
    public var officialName: String { name }
    public var lifecycleStatus: Fact<ProductStatus> { status }
    /// Derived from every piece of evidence; never stored.
    public var verificationState: VerificationStatus { overallVerification }

    public func verifications(in area: VerificationArea) -> [Verification] {
        switch area {
        case .facts: ProductField.allCases.filter(\.isKey).map { state(of: $0).verification }
        case .repositories: repositories.map(\.link)
        case .platforms: platforms.map(\.verification)
        case .stores: storeListings.map(\.verification)
        }
    }

    /// Per-area breakdown. The areas together hold exactly `allVerifications`.
    public var verificationBreakdown: [AreaVerification] {
        VerificationArea.allCases.map { area in
            AreaVerification(area: area, counts: Dictionary(grouping: verifications(in: area), by: \.status).mapValues(\.count))
        }
    }

    /// Every distinct source behind this product, newest first.
    public var sources: [Source] {
        var seen = Set<String>()
        return (allVerifications + fieldStates.map(\.verification))
            .flatMap(\.sources)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.observedAt > $1.observedAt }
    }

    /// Platforms whose evidence points into this repository (a file in its checkout, or its GitHub slug).
    public func platforms(for repository: RepositoryRecord) -> [PlatformRecord] {
        let keys = repository.evidenceKeys
        guard !keys.isEmpty else { return [] }
        return platforms.filter { p in
            p.verification.sources.contains { s in keys.contains { s.reference == $0 || s.reference.hasPrefix($0 + "/") || s.reference.hasSuffix("/" + $0) } }
        }
    }
}
