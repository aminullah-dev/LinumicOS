import Foundation
import Testing
@testable import LinumicCore

// SAMPLE data for testing only: no real app, bundle ID or rating.

private final class LookupStub: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    /// Response body per storefront (the `country` query item).
    let byCountry: [String: String]
    let status: Int

    init(_ byCountry: [String: String], status: Int = 200) {
        self.byCountry = byCountry
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let country = items.first { $0.name == "country" }?.value ?? ""
        let body = byCountry[country] ?? #"{"resultCount":0,"results":[]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let found = #"{"resultCount":1,"results":[{"trackName":"Sample App","version":"2.1.0","currentVersionReleaseDate":"2026-09-01T10:00:00Z","trackViewUrl":"https://apps.apple.com/us/app/sample/id1?uo=4","sellerName":"Sample Seller","averageUserRating":4.5,"userRatingCount":12}]}"#
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func product(_ listing: StoreListing) -> Product {
    var p = Product(id: "sample", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: t0))
    p.storeListings = [listing]
    return p
}

@Suite("App Store public lookup")
struct AppStoreLookupTests {
    @Test func lookupURLCarriesBundleAndStorefront() {
        let url = AppStoreLookupClient.lookupURL(bundleID: "com.sample.app", country: "af")
        #expect(url.absoluteString == "https://itunes.apple.com/lookup?bundleId=com.sample.app&country=af")
    }

    @Test func parsesResultAndStripsTrackingQuery() async throws {
        let client = AppStoreLookupClient(transport: LookupStub(["us": found]))
        let r = try #require(try await client.lookup(bundleID: "com.sample.app", country: "us"))
        #expect(r.trackName == "Sample App" && r.version == "2.1.0" && r.seller == "Sample Seller")
        #expect(r.url?.absoluteString == "https://apps.apple.com/us/app/sample/id1")
        #expect(r.averageUserRating == 4.5 && r.userRatingCount == 12 && r.storefront == "us")
    }

    @Test func emptyResultIsNilAndHTTPErrorThrows() async throws {
        let none = AppStoreLookupClient(transport: LookupStub([:]))
        #expect(try await none.lookup(bundleID: "com.sample.app", country: "us") == nil)
        let failing = AppStoreLookupClient(transport: LookupStub([:], status: 500))
        await #expect(throws: (any Error).self) { _ = try await failing.lookup(bundleID: "com.sample.app", country: "us") }
    }

    @Test func refreshFallsBackToSecondStorefrontAndVerifies() async {
        let stub = LookupStub(["af": found])
        let listing = StoreListing(store: .appStore, appIdentifier: "com.sample.app")
        let (out, report) = await StoreSync.refreshAppStore([product(listing)], using: AppStoreLookupClient(transport: stub), now: t0)
        let l = out[0].storeListings[0]
        #expect(report.updated == ["com.sample.app"] && report.notPublic.isEmpty && report.failed.isEmpty)
        #expect(l.productionVersion == "2.1.0" && l.storefront == "AF")
        #expect(l.insights?.ratingStorefront == "AF" && l.insights?.rating == 4.5)
        #expect(l.verification.status == .verified)
        #expect(stub.requests.count == 2, "tries us first, then af")
    }

    @Test func appMissingFromEveryStorefrontIsReportedNotWritten() async {
        let listing = StoreListing(store: .appStore, appIdentifier: "com.sample.app", productionVersion: "1.0")
        let (out, report) = await StoreSync.refreshAppStore([product(listing)], using: AppStoreLookupClient(transport: LookupStub([:])), now: t0)
        #expect(report.notPublic == ["com.sample.app"])
        #expect(out[0].storeListings[0] == listing, "an app that may be in review is never rewritten")
    }

    @Test func listingsWithoutBundleOrOnGooglePlayAreSkipped() async {
        let stub = LookupStub(["us": found])
        let p = Product(id: "sample", name: "SAMPLE", provenance: Provenance(source: "t", recordedAt: t0))
        var q = p
        q.storeListings = [StoreListing(store: .appStore), StoreListing(store: .googlePlay, appIdentifier: "com.sample.app")]
        let (_, report) = await StoreSync.refreshAppStore([q], using: AppStoreLookupClient(transport: stub), now: t0)
        #expect(stub.requests.isEmpty && report == StoreSync.Report())
    }

    @Test func consoleVersionIsNotOverwrittenByPublicLookup() async {
        let asc = Source(kind: .appStore, reference: StoreConsoleSync.ascReferencePrefix + "sample", observedAt: t0)
        let listing = StoreListing(store: .appStore, appIdentifier: "com.sample.app", productionVersion: "2.0.0",
                                   verification: Verification(status: .verified, sources: [asc], verifiedAt: t0))
        let (out, _) = await StoreSync.refreshAppStore([product(listing)], using: AppStoreLookupClient(transport: LookupStub(["us": found])), now: t0)
        let l = out[0].storeListings[0]
        #expect(l.productionVersion == "2.0.0", "App Store Connect has spoken")
        #expect(l.insights?.rating == 4.5, "the rating still comes from the public lookup")
        #expect(l.verification.sources.contains { $0.reference == asc.reference })
    }

    @Test func previousLookupSourceIsReplacedNotStacked() async {
        let old = Source(kind: .appStore, reference: AppStoreLookupClient.lookupURL(bundleID: "com.sample.app", country: "us").absoluteString, observedAt: t0)
        let owner = Source(kind: .ownerStatement, reference: "note", observedAt: t0)
        let listing = StoreListing(store: .appStore, appIdentifier: "com.sample.app", verification: Verification(status: .verified, sources: [old, owner], verifiedAt: t0))
        let (out, _) = await StoreSync.refreshAppStore([product(listing)], using: AppStoreLookupClient(transport: LookupStub(["us": found])), now: t0.addingTimeInterval(60))
        let sources = out[0].storeListings[0].verification.sources
        #expect(sources.count == 2 && sources.contains { $0.kind == .ownerStatement })
        #expect(sources.filter { $0.reference.hasPrefix("https://itunes.apple.com/lookup") }.count == 1)
    }
}
