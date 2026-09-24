import Foundation
import Testing
@testable import LinumicCore

// SAMPLE data for testing only.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let api = Source(kind: .googlePlay, reference: "Google Play Developer API applications/sample/tracks/*/releases", observedAt: t0)
private let screenshot = Source(kind: .ownerStatement, reference: "screenshot", observedAt: t0)

private func product(_ listing: StoreListing) -> Product {
    var p = Product(id: "sample", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: t0))
    p.storeListings = [listing]
    return p
}

private func listing(id: UUID, live: String?, pending: String?, status: String?, source: Source = api) -> StoreListing {
    StoreListing(id: id, store: .googlePlay, appName: "Sample App", productionVersion: live, latestSubmittedVersion: pending, reviewStatus: status,
                 verification: Verification(status: .verified, sources: [source], verifiedAt: t0))
}

@Suite("Store change detection")
struct StoreChangeTests {
    let id = UUID()

    @Test func reviewEndingInReleaseIsNowLive() {
        let before = product(listing(id: id, live: nil, pending: "1.1.0 (4)", status: "production 1.1.0 (4): In review"))
        let after = product(listing(id: id, live: "1.1.0", pending: nil, status: "Live: production 1.1.0 (4)"))
        let changes = StoreChangeDetector.changes(before: [before], after: [after], at: t0)
        #expect(changes.map(\.kind) == [.nowLive])
        #expect(changes.first?.to == "1.1.0" && changes.first?.isImportant == true)
    }

    @Test func rejectionIsAPhaseChange() {
        let before = product(listing(id: id, live: "1.0", pending: "1.1", status: "production 1.1 (5): In review"))
        let after = product(listing(id: id, live: "1.0", pending: "1.1", status: "production 1.1 (5): Not approved"))
        let c = StoreChangeDetector.changes(before: [before], after: [after], at: t0)
        #expect(c.map(\.kind) == [.phaseChanged])
        #expect(c.first?.from == ReviewPhase.pending.rawValue && c.first?.to == ReviewPhase.rejected.rawValue)
        #expect(c.first?.isImportant == true)
    }

    @Test func newVersionWaiting() {
        let before = product(listing(id: id, live: "1.0", pending: "1.1 (5)", status: "production 1.1 (5): In review"))
        let after = product(listing(id: id, live: "1.0", pending: "1.2 (6)", status: "production 1.2 (6): In review"))
        let c = StoreChangeDetector.changes(before: [before], after: [after], at: t0)
        #expect(c.map(\.kind) == [.newPending])
        #expect(c.first?.isImportant == false)
    }

    @Test func relabellingIsNotAChange() {
        // What the live data did on 2026-09-23 when Play labels were cleaned up.
        let before = product(listing(id: id, live: "10 (1.0.10)", pending: "4 (1.1.0) (4)", status: "production 4 (1.1.0) (4): In review"))
        let after = product(listing(id: id, live: "1.0.10", pending: "1.1.0 (4)", status: "production 1.1.0 (4): In review"))
        #expect(StoreChangeDetector.changes(before: [before], after: [after], at: t0).isEmpty)
        #expect(StoreChangeDetector.versionKey("iOS 1.0, macOS 1.0") == ["1.0"])
        #expect(StoreChangeDetector.versionKey("1.1.0 (4)") != StoreChangeDetector.versionKey("1.2.0 (5)"))
    }

    @Test func nothingChangedMeansNoChanges() {
        let l = product(listing(id: id, live: "1.0", pending: nil, status: "Live: production 1.0 (1)"))
        #expect(StoreChangeDetector.changes(before: [l], after: [l], at: t0).isEmpty)
    }

    @Test func firstConsoleReadAfterSeedDataIsSilent() {
        // The seed's screenshot text differs from the API's, but that isn't news.
        let before = product(listing(id: id, live: nil, pending: "1.0", status: "Pending: yellow clock", source: screenshot))
        let after = product(listing(id: id, live: nil, pending: "1.0", status: "1.0: Prepare for submission"))
        #expect(StoreChangeDetector.changes(before: [before], after: [after], at: t0).isEmpty)
    }

    @Test func changesRoundTripAsJSON() throws {
        let c = StoreChange(kind: .nowLive, productID: "p", appName: "A", store: .appStore, from: nil, to: "1.0", detectedAt: t0)
        let data = try JSONEncoder().encode([c])
        #expect(try JSONDecoder().decode([StoreChange].self, from: data) == [c])
        #expect(!c.message.isEmpty)
    }
}

@Suite("Review and build changes")
struct InsightChangeTests {
    let id = UUID()
    private let asc = Source(kind: .appStore, reference: "App Store Connect API /v1/apps/1/appStoreVersions", observedAt: t0)

    private func product(_ insights: StoreInsights) -> Product {
        var p = Product(id: "sample", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: t0))
        p.storeListings = [StoreListing(id: id, store: .appStore, appName: "Sample App", productionVersion: "1.0",
                                        verification: Verification(status: .verified, sources: [asc], verifiedAt: t0), insights: insights)]
        return p
    }

    @Test func newLowReviewIsImportant() {
        let a = CustomerReview(id: "r1", rating: 5, title: "Great")
        let b = CustomerReview(id: "r2", rating: 1, title: "Crashes on launch")
        let before = product(StoreInsights(reviews: [a], reviewsObservedAt: t0))
        let after = product(StoreInsights(reviews: [b, a], reviewsObservedAt: t0 + 1800))
        let c = StoreChangeDetector.changes(before: [before], after: [after], at: t0 + 1800)
        #expect(c.map(\.kind) == [.newReview])
        #expect(c.first?.to == "1" && c.first?.from == "Crashes on launch" && c.first?.isImportant == true)
    }

    @Test func firstReviewReadIsSilent() {
        let before = product(StoreInsights())
        let after = product(StoreInsights(reviews: [CustomerReview(id: "r1", rating: 2)], reviewsObservedAt: t0))
        #expect(StoreChangeDetector.changes(before: [before], after: [after], at: t0).isEmpty)
    }

    @Test func buildReadyAndExpiring() {
        let processing = TestBuild(id: "b7", build: "7", version: "1.0.1", processingState: "PROCESSING", expiresAt: t0 + 90 * 86_400)
        var ready = processing
        ready.processingState = "VALID"
        let old = TestBuild(id: "b6", build: "6", version: "1.0.1", processingState: "VALID", expiresAt: t0 + 8 * 86_400)
        let before = product(StoreInsights(testBuilds: [processing, old], testBuildsObservedAt: t0))
        let now = t0 + 2 * 86_400  // b6 now expires in 6 days
        let after = product(StoreInsights(testBuilds: [ready, old], testBuildsObservedAt: now))
        let c = StoreChangeDetector.changes(before: [before], after: [after], at: now)
        #expect(Set(c.map(\.kind)) == [.buildReady, .buildExpiring])
        #expect(c.first { $0.kind == .buildExpiring }?.from == "6")
        #expect(c.first { $0.kind == .buildReady }?.to == "1.0.1 (7)")
        // The next read doesn't repeat either alert.
        #expect(StoreChangeDetector.changes(before: [after], after: [after], at: now + 1800).isEmpty)
    }

    @Test func insightsRoundTripAndOlderDataDecodes() throws {
        let i = StoreInsights(rating: 4.6, ratingCount: 120, ratingStorefront: "US", ratingObservedAt: t0,
                              reviews: [CustomerReview(id: "r", rating: 4, createdAt: t0)], reviewsObservedAt: t0,
                              testBuilds: [TestBuild(id: "b", build: "3", version: "1.0", processingState: "VALID")], testBuildsObservedAt: t0)
        let data = try InventoryCoding.encoder().encode(i)
        #expect(try InventoryCoding.decoder().decode(StoreInsights.self, from: data) == i)
        #expect(try InventoryCoding.decoder().decode(StoreInsights.self, from: Data("{}".utf8)) == StoreInsights())
        // A listing stored before insights existed still decodes.
        let listing = #"{"id":"6E1C3A2B-1111-4F4F-9A9A-000000000001","store":"appStore","verification":{"status":"unknown","sources":[],"notes":""}}"#
        #expect(try InventoryCoding.decoder().decode(StoreListing.self, from: Data(listing.utf8)).insights == nil)
    }
}

@Suite("App Store Connect reviews and builds")
struct ASCInsightTests {
    private final class Stub: HTTPTransport, @unchecked Sendable {
        let handler: @Sendable (URLRequest) -> String
        init(_ h: @escaping @Sendable (URLRequest) -> String) { handler = h }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(handler(request).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func parsesReviewsAndBuildsWithVersions() async throws {
        let stub = Stub { req in
            if req.url!.path.hasSuffix("customerReviews") {
                return #"{"data":[{"id":"r1","attributes":{"rating":2,"title":"Slow","body":"Takes long","reviewerNickname":"x","createdDate":"2026-09-20T10:00:00-07:00","territory":"USA"}}]}"#
            }
            return #"{"data":[{"id":"b1","attributes":{"version":"7","uploadedDate":"2026-09-20T10:00:00.000-07:00","expirationDate":"2026-12-19T10:00:00.000-08:00","expired":false,"processingState":"VALID"},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p1"}}}}],"included":[{"type":"preReleaseVersions","id":"p1","attributes":{"version":"1.0.1","platform":"IOS"}}]}"#
        }
        let client = AppStoreConnectClient(credentials: AppStoreConnectCredentials(issuerID: "i", keyID: "k", privateKeyPEM: P256Fixture.pem), transport: stub, now: { t0 })
        let reviews = try await client.customerReviews(appID: "1")
        #expect(reviews.first?.rating == 2 && reviews.first?.title == "Slow" && reviews.first?.createdAt != nil)
        let builds = try await client.testBuilds(appID: "1")
        #expect(builds.first?.label == "1.0.1 (7)" && builds.first?.platform == "IOS" && builds.first?.isUsable == true)
    }
}

import CryptoKit
enum P256Fixture { static let pem = P256.Signing.PrivateKey().pemRepresentation }
