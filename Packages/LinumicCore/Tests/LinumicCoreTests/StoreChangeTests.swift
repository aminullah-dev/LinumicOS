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
