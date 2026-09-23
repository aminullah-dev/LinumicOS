import Foundation
import Testing
@testable import LinumicCore

// Data built in these tests is SAMPLE data for testing only. The seed tests read the real seed file.

private let day = Date(timeIntervalSince1970: 1_790_000_000)
private let sampleSource = Source(kind: .localRepository, reference: "~/Projects/Sample/build.gradle.kts", observedAt: day, detail: "applicationId sample.app")

private func verified(_ sources: [Source] = [sampleSource]) -> Verification {
    Verification(status: .verified, sources: sources, verifiedAt: day)
}

@Suite("Product model")
struct ProductTests {
    @Test func slugIsURLSafe() {
        #expect(Product.slug(for: "Safe Beauty") == "safe-beauty")
        #expect(Product.slug(for: "The Digital Infrastructure of the Pashto Language") == "the-digital-infrastructure-of-the-pashto-language")
        #expect(Product.slug(for: "SODER-HAKEM") == "soder-hakem")
    }

    @Test func decodesMinimalRecordWithEverythingUnknown() throws {
        let json = #"{"id":"x","name":"X","provenance":{"source":"test","recordedAt":"2026-01-01T00:00:00Z"}}"#
        let product = try InventoryCoding.decoder().decode(Product.self, from: Data(json.utf8))
        #expect(product.status.value == nil)
        #expect(product.status.status == .unknown)
        #expect(product.currentVersion == .unknown)
        #expect(product.repositories.isEmpty && product.platforms.isEmpty && product.storeListings.isEmpty)
        #expect(product.overallVerification == .unknown)
    }

    @Test func gitHubSlugParsesURL() {
        let repo = RepositoryRecord(name: "r", url: URL(string: "https://github.com/aminullah-dev/-Namazia.git"))
        #expect(repo.gitHubSlug == "aminullah-dev/-Namazia")
        // Regression: only a trailing ".git" is removed.
        #expect(RepositoryRecord(name: "r", url: URL(string: "https://github.com/aminullah-dev/nerkhtimes.github.io")).gitHubSlug == "aminullah-dev/nerkhtimes.github.io")
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

@Suite("Repositories")
struct RepositoryTests {
    @Test func productHoldsSeveralTypedRepositories() {
        let p = Product(id: "s", name: "SAMPLE", repositories: [
            RepositoryRecord(name: "sample-app", type: .monorepo, link: verified()),
            RepositoryRecord(name: "sample-releases", type: .releases, link: verified()),
            RepositoryRecord(name: "sample-site", type: .website, link: Verification(status: .partiallyVerified, sources: [sampleSource], verifiedAt: day)),
        ])
        #expect(p.repositories.count == 3)
        #expect(Set(p.repositories.map(\.type)) == [.monorepo, .releases, .website])
        // A partially verified link keeps the product from being fully verified.
        #expect(p.needsConfirmation.contains { $0.label == "Repository sample-site" })
    }

    @Test func repositoryTypeRoundTripsAndUnknownValuesDecodeAsUnknown() throws {
        for type in RepositoryType.allCases {
            let data = try InventoryCoding.encoder().encode(type)
            #expect(try InventoryCoding.decoder().decode(RepositoryType.self, from: data) == type)
        }
        #expect(try InventoryCoding.decoder().decode(RepositoryType.self, from: Data(#""somethingNew""#.utf8)) == .unknown)
        #expect(try InventoryCoding.decoder().decode(Platform.self, from: Data(#""tvOS""#.utf8)) == .unknown)
    }

    @Test func repositoryDefaultsToUnknownTypeAndUnverifiedLink() throws {
        let json = #"{"id":"6F1C2D3E-0000-4000-8000-000000000001","name":"r"}"#
        let repo = try InventoryCoding.decoder().decode(RepositoryRecord.self, from: Data(json.utf8))
        #expect(repo.type == .unknown)
        #expect(repo.link.status == .unknown)
        #expect(repo.localCheckouts.isEmpty)
    }
}

@Suite("Verification")
struct VerificationTests {
    @Test func rollUpRules() {
        #expect([VerificationStatus]().rollUp == .unknown)
        #expect([.verified, .verified].rollUp == .verified)
        #expect([.unknown, .unknown].rollUp == .unknown)
        #expect([.verified, .unknown].rollUp == .partiallyVerified)
        #expect([.verified, .partiallyVerified].rollUp == .partiallyVerified)
        #expect([.verified, .conflicting, .unknown].rollUp == .conflicting)
    }

    @Test func attentionOrderPutsConflictsFirst() {
        #expect(VerificationStatus.allCases.sorted() == [.conflicting, .unknown, .partiallyVerified, .verified])
    }

    @Test func verifiedWithoutSourceIsAnIntegrityIssue() {
        let bad = Fact<String>("1.0", Verification(status: .verified))
        #expect(bad.issues.contains("Verified without any source"))
        #expect(bad.issues.contains("Verified without a verification date"))
        #expect(Fact<String>("1.0", verified()).issues.isEmpty)
    }

    @Test func unknownFactsCarryNoValue() {
        #expect(Fact<String>.unknown.issues.isEmpty)
        #expect(Fact<String>("guess", .unknown).issues.contains { $0.contains("marked Unknown") })
        #expect(Fact<String>(nil, verified()).issues.contains { $0.contains("value is empty") })
    }

    @Test func conflictingNeedsEvidenceOrExplanation() {
        #expect(!Verification(status: .conflicting, sources: [sampleSource], verifiedAt: day).issues.isEmpty)
        #expect(Verification(status: .conflicting, sources: [sampleSource], verifiedAt: day, notes: "Site says A, repo says B").issues.isEmpty)
    }

    @Test func productRollsUpFieldsPlatformsAndLinks() {
        var p = Product(id: "s", name: "SAMPLE")
        for field in ProductField.allCases where field.isKey {
            switch field {
            case .isLinumicProduct: p.isLinumicProduct = Fact(true, verified())
            case .summary: p.summary = Fact("x", verified())
            case .category: p.category = Fact("x", verified())
            case .projectType: p.projectType = Fact("x", verified())
            case .status: p.status = Fact(.active, verified())
            case .currentVersion: p.currentVersion = Fact("1.0", verified())
            case .backend: p.backend = Fact("x", verified())
            case .website: p.website = Fact(URL(string: "https://example.com"), verified())
            case .alsoKnownAs, .nextVersion: break
            }
        }
        p.platforms = [PlatformRecord(platform: .android, identifier: "sample.app", verification: verified())]
        #expect(p.overallVerification == .verified)
        #expect(p.needsConfirmation.isEmpty)
        #expect(p.integrityIssues.isEmpty)

        p.platforms.append(PlatformRecord(platform: .iOS, verification: .unknown))
        #expect(p.overallVerification == .partiallyVerified)

        p.website = Fact(nil, Verification(status: .conflicting, sources: [sampleSource, sampleSource], verifiedAt: day))
        #expect(p.overallVerification == .conflicting)
        #expect(p.needsConfirmation.first?.verification.status == .conflicting)
        #expect(p.lastVerifiedAt == day)
    }
}

@Suite("Editing")
struct EditingTests {
    @Test func setFieldParsesAndClears() {
        var p = Product(id: "s", name: "SAMPLE")
        let r1 = p.setField(.status, text: "development", verification: verified())
        #expect(r1)
        #expect(p.status.value == .development)
        let r2 = p.setField(.website, text: "https://example.com/x", verification: verified())
        #expect(r2)
        #expect(p.website.value?.host() == "example.com")
        let r3 = p.setField(.website, text: "not a url", verification: verified())
        #expect(!r3)
        #expect(p.website.value?.host() == "example.com")
        let r4 = p.setField(.alsoKnownAs, text: "A, B ,", verification: verified())
        #expect(r4)
        #expect(p.alsoKnownAs.value == ["A", "B"])
        let r5 = p.setField(.currentVersion, text: "  ", verification: .unknown)
        #expect(r5)
        #expect(p.currentVersion == .unknown)
        let r6 = p.setField(.isLinumicProduct, text: "maybe", verification: verified())
        #expect(!r6)
    }
}

@Suite("Source tracking")
struct SourceTests {
    @Test func sourcesSurviveRoundTrip() throws {
        let fact = Fact<String>("2.1.5", Verification(status: .verified, sources: [sampleSource, Source(kind: .appStore, reference: "https://apps.apple.com/x", observedAt: day)], verifiedAt: day, notes: "n"))
        let decoded = try InventoryCoding.decoder().decode(Fact<String>.self, from: InventoryCoding.encoder().encode(fact))
        #expect(decoded == fact)
        #expect(decoded.verification.sources.map(\.kind) == [.localRepository, .appStore])
        #expect(decoded.verification.sources.first?.detail == "applicationId sample.app")
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
            id: "sample", name: "SAMPLE", status: Fact(.development, verified()),
            repositories: [RepositoryRecord(name: "a", type: .application, link: verified()), RepositoryRecord(name: "b", type: .backend)],
            platforms: [PlatformRecord(platform: .macOS, verification: verified())],
            storeListings: [StoreListing(store: .appStore, appName: "Sample", verification: verified())],
            provenance: Provenance(source: "test", recordedAt: Date(timeIntervalSince1970: 0))
        )
        let unresolved = UnresolvedItem(id: "u", kind: .possibleProduct, name: "U", location: "~/x", findings: "f", verification: .unknown)
        let inventory = Inventory(products: [product], unresolved: [unresolved])
        try await store.save(inventory)
        #expect(try await store.load() == inventory)
    }

    /// Regression: the real location is "Application Support". `URL.path()` percent-encodes the space,
    /// which made the store think the file was missing and reseed over it on every launch.
    @Test func loadsFromADirectoryWithASpaceInItsName() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lcc \(UUID())/Application Support")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = JSONFileInventoryStore(fileURL: dir.appending(path: "inventory.json"))
        let inventory = Inventory(products: [Product(id: "s", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: Date(timeIntervalSince1970: 0)))])
        try await store.save(inventory)
        #expect(try await store.load() == inventory)
        let archived = try #require(try await store.archive())
        #expect(FileManager.default.fileExists(atPath: archived.path(percentEncoded: false)))
    }

    @Test func rejectsNewerSchemaAndFlagsOlderSchema() {
        #expect(throws: InventoryStoreError.unsupportedSchemaVersion(999)) {
            try InventoryCoding.decode(Data(#"{"schemaVersion":999,"products":[]}"#.utf8))
        }
        #expect(throws: InventoryStoreError.outdatedSchemaVersion(1)) {
            try InventoryCoding.decode(Data(#"{"schemaVersion":1,"products":[]}"#.utf8))
        }
    }

    @Test func archiveMovesTheFileAsideWithoutDeleting() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lcc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileInventoryStore(fileURL: dir.appending(path: "inventory.json"))
        try await store.save(Inventory())
        let archived = try #require(try await store.archive())
        #expect(FileManager.default.fileExists(atPath: archived.path(percentEncoded: false)))
        #expect(try await store.load() == nil)
    }
}

@Suite("Seed inventory")
struct SeedTests {
    let seed: Inventory

    init() throws { seed = try SeedInventory.load() }

    @Test func containsTheTwelveOwnerListedProducts() {
        #expect(seed.products.count == 12)
        #expect(Set(seed.products.map(\.id)).count == 12)
        for p in seed.products {
            #expect(p.isLinumicProduct.value == true, "\(p.name)")
            #expect(p.isLinumicProduct.verification.sources.contains { $0.kind == .ownerStatement }, "\(p.name)")
        }
    }

    @Test func everyRecordIsInternallyConsistent() {
        for p in seed.products {
            #expect(p.integrityIssues.isEmpty, "\(p.name): \(p.integrityIssues)")
        }
        for item in seed.unresolved {
            #expect(item.verification.issues.isEmpty, "\(item.name)")
        }
    }

    @Test func everyPlatformAndRepositoryLinkHasEvidenceUnlessUnknown() {
        for p in seed.products {
            for platform in p.platforms where platform.verification.status != .unknown {
                #expect(!platform.verification.sources.isEmpty, "\(p.name) \(platform.platform)")
            }
            #expect(!p.repositories.isEmpty, "\(p.name) has no repository")
            for repo in p.repositories {
                #expect(repo.link.status != .unknown, "\(p.name) \(repo.name)")
            }
        }
    }

    @Test func productsWithSeveralRepositoriesAreModelled() throws {
        let talar = try #require(seed.products.first { $0.id == "talar" })
        #expect(Set(talar.repositories.map(\.type)) == [.monorepo, .releases])
        let nerkh = try #require(seed.products.first { $0.id == "nerkhtimes" })
        #expect(nerkh.repositories.contains { $0.name == "nerkhtimes.github.io" && $0.type == .website })
        let safeBeauty = try #require(seed.products.first { $0.id == "safe-beauty" })
        #expect(safeBeauty.repositories.first?.name == "stealth-service-vault-")
    }

    @Test func noRepositoryIsLinkedToTwoProducts() {
        let names = seed.products.flatMap { $0.repositories.map(\.name) }
        #expect(names.count == Set(names).count)
    }

    @Test func knownConflictIsSurfaced() throws {
        let tailoring = try #require(seed.products.first { $0.id == "tailoring-workshop-erp" })
        #expect(tailoring.website.status == .conflicting)
        #expect(tailoring.website.value == nil)
        #expect(tailoring.overallVerification == .conflicting)
    }
}

@Suite("Dashboard summary")
struct DashboardSummaryTests {
    @Test func computesCounts() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let products = [
            Product(id: "a", name: "SAMPLE A", status: Fact(.active, verified()),
                    storeListings: [StoreListing(store: .appStore, verification: verified()), StoreListing(store: .googlePlay, verification: .unknown)],
                    issues: [IssueRecord(title: "crash", severity: .critical), IssueRecord(title: "closed", severity: .critical, isOpen: false)],
                    releases: [Release(version: "2.0", platform: .iOS, stage: .blocked, releaseDate: now),
                               Release(version: "1.0", platform: .iOS, stage: .released, releaseDate: now)]),
            Product(id: "b", name: "SAMPLE B", status: Fact(.development, verified()),
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
        #expect(s.productsWithAppStoreListing == 1)
        #expect(s.productsWithGooglePlayListing == 0)
        #expect(s.countsByVerification[.unknown] == 1)
    }
}
