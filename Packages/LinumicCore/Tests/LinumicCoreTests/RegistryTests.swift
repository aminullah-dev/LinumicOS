import Foundation
import Testing
@testable import LinumicCore

// SAMPLE data for testing only. The seed test reads the real seed file.

private let day = Date(timeIntervalSince1970: 1_790_000_000)
private let later = day.addingTimeInterval(86_400)
private let gradle = Source(kind: .gradleConfiguration, reference: "~/Projects/Sample/app/build.gradle.kts", observedAt: day, detail: "applicationId sample.app")
private let api = Source(kind: .gitHub, reference: "https://api.github.com/repos/sample-owner/sample", observedAt: later)

private func v(_ status: VerificationStatus, _ sources: [Source] = [gradle]) -> Verification {
    status == .unknown ? .unknown : Verification(status: status, sources: sources, verifiedAt: sources.map(\.observedAt).max())
}

private func sampleProduct() -> Product {
    var p = Product(id: "sample", name: "SAMPLE", provenance: Provenance(source: "test", recordedAt: day))
    p.repositories = [
        RepositoryRecord(name: "sample", url: URL(string: "https://github.com/sample-owner/sample"), link: v(.verified, [api]),
                         gitHub: RepositorySnapshot(slug: "sample-owner/sample", visibility: .private, defaultBranch: "main",
                                                    latestCommit: .init(sha: "a", message: "old", date: day), fetchedAt: later),
                         localCheckouts: [LocalCheckout(path: "~/Projects/Sample", lastCommit: .init(sha: "b", message: "new", date: later), observedAt: later)]),
        RepositoryRecord(name: "unlinked", link: .unknown),
    ]
    p.platforms = [
        PlatformRecord(platform: .android, verification: v(.verified)),
        PlatformRecord(platform: .iOS, verification: v(.partiallyVerified, [Source(kind: .localRepository, reference: "~/Elsewhere/README.md", observedAt: day)])),
    ]
    return p
}

@Suite("Product registry")
struct RegistryTests {
    @Test func repositoryAccessorsAreDerived() throws {
        let repo = sampleProduct().repositories[0]
        #expect(repo.localPath == "~/Projects/Sample")
        #expect(repo.defaultBranch == "main")
        #expect(repo.visibility == .private)
        #expect(repo.latestCommit?.sha == "b", "the newer local commit wins over the GitHub snapshot")
        #expect(repo.latestCommitDate == later)
        #expect(repo.verificationState == .verified)
        #expect(repo.source == api)
        let unlinked = sampleProduct().repositories[1]
        #expect(unlinked.localPath == nil && unlinked.latestCommit == nil && unlinked.source == nil)
        #expect(unlinked.verificationState == .unknown)
    }

    @Test func platformsAreMatchedToTheirRepositoryByEvidence() {
        let p = sampleProduct()
        #expect(p.platforms(for: p.repositories[0]).map(\.platform) == [.android], "the README elsewhere isn't evidence for this repository")
        #expect(p.platforms(for: p.repositories[1]).isEmpty)
    }

    @Test func breakdownCoversExactlyTheOverallEvidence() {
        let p = sampleProduct()
        let areas = Dictionary(uniqueKeysWithValues: p.verificationBreakdown.map { ($0.area, $0) })
        #expect(areas[.repositories]?.count(.verified) == 1)
        #expect(areas[.repositories]?.count(.unknown) == 1)
        #expect(areas[.repositories]?.status == .partiallyVerified)
        #expect(areas[.platforms]?.status == .partiallyVerified)
        #expect(areas[.stores]?.total == 0 && areas[.stores]?.status == .unknown)
        #expect(p.verificationBreakdown.map(\.total).reduce(0, +) == p.allVerifications.count)
        #expect(p.verificationState == p.overallVerification)
    }

    @Test func conflictAnywhereMakesTheProductConflicting() {
        var p = sampleProduct()
        p.platforms[0].verification = Verification(status: .conflicting, sources: [gradle, api], verifiedAt: later)
        #expect(p.verificationBreakdown.first { $0.area == .platforms }?.status == .conflicting)
        #expect(p.verificationState == .conflicting)
    }

    @Test func sourcesAreDistinctAndNewestFirst() {
        let p = sampleProduct()
        #expect(p.sources.first == api)
        #expect(p.sources.count == Set(p.sources.map(\.id)).count)
        #expect(p.sources.filter { $0 == gradle }.count == 1)
    }

    @Test func evidenceVocabularyMapsToStoredFields() {
        #expect(gradle.sourceType == .gradleConfiguration)
        #expect(gradle.sourceReference == "~/Projects/Sample/app/build.gradle.kts")
        #expect(gradle.observedValue == "applicationId sample.app")
        #expect(gradle.verifiedAt == day)
        #expect(SourceKind.gradleConfiguration.isLocal && SourceKind.localRepository.isLocal && !SourceKind.gitHub.isLocal)
    }

    @Test func unknownSourceKindDecodesAsOther() throws {
        let json = #"{"kind":"someFutureKind","reference":"x","observedAt":"2026-01-01T00:00:00Z"}"#
        let s = try InventoryCoding.decoder().decode(Source.self, from: Data(json.utf8))
        #expect(s.kind == .other)
        let legacy = #"{"kind":"localRepository","reference":"x","observedAt":"2026-01-01T00:00:00Z"}"#
        #expect(try InventoryCoding.decoder().decode(Source.self, from: Data(legacy.utf8)).kind == .localRepository)
    }

    @Test func seedUsesTheSpecificLocalKinds() throws {
        let seed = try SeedInventory.load()
        let sources = seed.products.flatMap(\.sources)
        for s in sources where s.kind == .localRepository {
            let file = s.reference.split(separator: "/").last.map(String.init) ?? ""
            #expect(!file.hasPrefix("build.gradle") && file != "project.yml" && file != "package.json", "\(s.reference) should use a specific kind")
        }
        #expect(sources.contains { $0.kind == .gradleConfiguration })
        #expect(sources.contains { $0.kind == .xcodeProject })
        #expect(sources.contains { $0.kind == .packageManifest })
        // Every seed product keeps a derived state consistent with its areas.
        for p in seed.products {
            #expect(p.verificationBreakdown.map(\.total).reduce(0, +) == p.allVerifications.count)
            #expect(p.integrityIssues.isEmpty, "\(p.name): \(p.integrityIssues)")
        }
    }
}
