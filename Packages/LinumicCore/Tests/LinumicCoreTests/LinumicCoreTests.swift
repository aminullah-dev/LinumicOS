import Foundation
import Testing
@testable import LinumicCore

// All data in these tests is SAMPLE data for testing only.

@Suite("Product model")
struct ProductTests {
    @Test func slugIsURLSafe() {
        #expect(Product.slug(for: "Safe Beauty") == "safe-beauty")
        #expect(Product.slug(for: "The Digital Infrastructure of the Pashto Language") == "the-digital-infrastructure-of-the-pashto-language")
        #expect(Product.slug(for: "SODER-HAKEM") == "soder-hakem")
    }

    @Test func decodesMinimalRecordWithUnknownDefaults() throws {
        let json = #"{"id":"x","name":"X","provenance":{"source":"test","recordedAt":"2026-01-01T00:00:00Z"}}"#
        let product = try InventoryCoding.decoder().decode(Product.self, from: Data(json.utf8))
        #expect(product.status == .unknown)
        #expect(product.releases.isEmpty)
        #expect(product.currentVersion == nil)
        #expect(product.notes.isEmpty)
    }

    @Test func gitHubSlugParsesURL() {
        let repo = RepositoryRecord(name: "r", url: URL(string: "https://github.com/aminullah-dev/-Namazia.git"))
        #expect(repo.gitHubSlug == "aminullah-dev/-Namazia")
        #expect(RepositoryRecord(name: "r", url: URL(string: "https://gitlab.com/a/b")).gitHubSlug == nil)
    }

    @Test func latestReleasedPicksNewestDate() {
        let old = Release(version: "1.0", platform: .android, stage: .released, releaseDate: Date(timeIntervalSince1970: 0))
        let new = Release(version: "1.1", platform: .android, stage: .released, releaseDate: Date(timeIntervalSince1970: 100))
        let beta = Release(version: "1.2", platform: .android, stage: .beta)
        let p = Product(id: "s", name: "SAMPLE", releases: [new, beta, old])
        #expect(p.latestReleased?.version == "1.1")
        #expect(p.upcomingReleases.map(\.version) == ["1.2"])
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func jsonStoreRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONFileInventoryStore(fileURL: url)

        #expect(try await store.load() == nil)

        let product = Product(
            id: "sample", name: "SAMPLE", status: .development, platforms: [.macOS],
            releases: [Release(version: "0.1", platform: .macOS, releaseDate: Date(timeIntervalSince1970: 1_000_000))],
            provenance: Provenance(source: "test", recordedAt: Date(timeIntervalSince1970: 0))
        )
        try await store.save(Inventory(products: [product]))
        #expect(try await store.load() == Inventory(products: [product]))
    }

    @Test func rejectsNewerSchema() {
        let json = #"{"schemaVersion":999,"products":[]}"#
        #expect(throws: InventoryStoreError.unsupportedSchemaVersion(999)) {
            try InventoryCoding.decode(Data(json.utf8))
        }
    }

    @Test func seedContainsOnlyVerifiedFacts() throws {
        let seed = try SeedInventory.load()
        #expect(seed.products.count == 12)
        #expect(Set(seed.products.map(\.id)).count == seed.products.count)
        for p in seed.products {
            // Nothing beyond name and repository is asserted in the seed.
            #expect(p.status == .unknown)
            #expect(p.platforms.isEmpty)
            #expect(p.currentVersion == nil && p.nextVersion == nil)
            #expect(p.releases.isEmpty && p.issues.isEmpty && p.roadmap.isEmpty)
            #expect(p.repositories.count == 1)
            #expect(p.repositories.first?.gitHubSlug?.hasPrefix("aminullah-dev/") == true)
        }
    }
}

@Suite("Dashboard summary")
struct DashboardSummaryTests {
    @Test func computesCounts() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let products = [
            Product(id: "a", name: "SAMPLE A", status: .active,
                    issues: [IssueRecord(title: "crash", severity: .critical), IssueRecord(title: "closed", severity: .critical, isOpen: false)],
                    releases: [Release(version: "2.0", platform: .iOS, stage: .blocked, releaseDate: now),
                               Release(version: "1.0", platform: .iOS, stage: .released, releaseDate: now)]),
            Product(id: "b", name: "SAMPLE B", status: .development,
                    releases: [Release(version: "0.1", platform: .web, stage: .beta)],
                    deployments: [Deployment(environment: .production, target: "api", status: .healthy)]),
            Product(id: "c", name: "SAMPLE C"),
        ]
        let s = DashboardSummary(products: products)
        #expect(s.totalProducts == 3)
        #expect(s.activeCount == 1)
        #expect(s.inDevelopmentCount == 1)
        #expect(s.unknownStatusCount == 1)
        #expect(s.openCriticalIssues.count == 1)
        #expect(s.upcomingReleases.map(\.release.version) == ["2.0", "0.1"])
        #expect(s.blockedReleases.map(\.release.version) == ["2.0"])
        #expect(s.currentReleases.map(\.release.version) == ["1.0"])
        #expect(s.deploymentsByStatus[.healthy] == 1)
    }
}
