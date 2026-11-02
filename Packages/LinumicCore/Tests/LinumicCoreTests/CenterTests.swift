import Foundation
import Testing
@testable import LinumicCore

@Suite("Management centre")
struct CenterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, title: String? = nil, level: ProductLevelState = .level,
                      ci: Sourced<CISummary> = .unknown("not read"), health: Sourced<HealthSummary> = .unknown("not read"),
                      licences: Sourced<ProductLicences>? = nil) -> ProductCard {
        let product = CompanyProduct(id: id, title: title ?? id, inventoryID: nil, tracks: [], source: "test")
        return ProductCard(product: product, tracks: [], level: level, repos: [], pulls: .unknown("not read"), ci: ci,
                           licences: licences, health: health, readAt: nil)
    }

    private func known<T>(_ value: T) -> Sourced<T> { .known(value, source: "test", readAt: now) }

    private func report(_ cards: [ProductCard]) -> ProductsReport {
        ProductsReport(cards: cards, generatedAt: now, nothingRead: false)
    }

    private func row(_ key: String, domain: String = "x", owner: Bool, bucket: DeskBucket, severity: BriefSeverity = .normal) -> DeskRow {
        let item = DeskItem(origin: .ledger(key), subjectKey: key, kindKey: "task", kind: .task, domain: .named(domain), severity: severity,
                            title: key, subject: key, ownerAction: owner, evidence: DeskEvidence(source: "test", readAt: now),
                            factHash: key, destination: .ledgerAccess)
        return DeskRow(item: item, bucket: bucket, resolution: .open, isStale: false)
    }

    private func desk(today: [DeskRow] = [], thisWeek: [DeskRow] = [], later: [DeskRow] = []) -> Desk {
        Desk(generatedAt: now, today: today, thisWeek: thisWeek, later: later, markedNotTicked: [], hidden: [], sources: [], obsoleteMarks: [])
    }

    @Test func theOwnersFocusIsTheDefault() {
        for id in ["linumicos", "khayatyar", "worktrack"] { #expect(CenterTier.default(forProduct: id) == .focus) }
        #expect(CenterTier.default(forProduct: "velro") == .maintenance)
        #expect(CenterTier.default(forProduct: "safebeauty") == .maintenance)
        #expect(CenterTier.default(forProduct: "dukanpro") == .archived)
    }

    @Test func archivedProjectsAreNotShown() {
        let r = CenterBuilder.build(desk: desk(), products: report([card("dukanpro")]))
        #expect(r.focus.isEmpty && r.maintenanceAttention.isEmpty && r.maintenanceQuiet.isEmpty)
    }

    @Test func aFocusProjectIsShownEvenWithNothingWrong() {
        let r = CenterBuilder.build(desk: desk(), products: report([card("worktrack")]))
        #expect(r.focus.map(\.id) == ["worktrack"])
        #expect(r.problemCount == 0)
    }

    @Test func aMaintenanceProjectRisesOnlyWithAProblemOrWaiting() {
        let quiet = card("velro", ci: known(CISummary(passing: ["a"], failing: [], running: [], noRuns: [])))
        let failing = card("talar", ci: known(CISummary(passing: [], failing: ["t/repo"], running: [], noRuns: [])))
        let waiting = card("safebeauty", title: "SafeBeauty")
        let r = CenterBuilder.build(desk: desk(today: [row("deploy", domain: "SafeBeauty", owner: true, bucket: .today)]),
                                    products: report([quiet, failing, waiting]))
        #expect(r.maintenanceQuiet.map(\.id) == ["velro"])
        #expect(Set(r.maintenanceAttention.map(\.id)) == ["talar", "safebeauty"])
        #expect(r.problemCount == 1)   // waiting on the owner is not a fault in the project
    }

    @Test func anUnreadValueIsNeverAProblemAndNeverReadsAsFine() {
        let project = CenterBuilder.build(desk: desk(), products: report([card("velro")])).maintenanceQuiet[0]
        #expect(!project.hasProblem)
        #expect(project.isUnread)
        let read = card("velro", ci: known(CISummary(passing: ["a"], failing: [], running: [], noRuns: [])))
        #expect(!CenterBuilder.build(desk: desk(), products: report([read])).maintenanceQuiet[0].isUnread)
    }

    @Test func theWorstProjectComesFirst() {
        let level = card("a", level: .notLevel([]))
        let down = card("b", health: known(HealthSummary(up: 1, degraded: 0, down: 2, unchecked: 0)))
        let ci = card("c", ci: known(CISummary(passing: [], failing: ["r"], running: [], noRuns: [])))
        let r = CenterBuilder.build(desk: desk(), products: report([level, ci, down]))
        #expect(r.maintenanceAttention.map(\.id) == ["b", "c", "a"])
    }

    @Test func attentionsAreSortedAndCarryTheirKinds() {
        let c = card("a", level: .notLevel([]), ci: known(CISummary(passing: [], failing: ["r"], running: [], noRuns: [])),
                     health: known(HealthSummary(up: 0, degraded: 1, down: 1, unchecked: 0)),
                     licences: known(ProductLicences(active: 1, expiringSoon: 1, expired: 1, total: 3)))
        #expect(CenterBuilder.attentions(c).map(\.kind) == [.healthDown, .ciFailing, .licenceExpired, .healthDegraded, .licenceExpiring, .notLevel])
    }

    @Test func waitingIsTheOwnersOpenRowsTodayFirst() {
        let r = CenterBuilder.build(desk: desk(today: [row("t-owner", owner: true, bucket: .today), row("t-fact", owner: false, bucket: .today)],
                                               thisWeek: [row("w-owner", owner: true, bucket: .thisWeek), row("w-fact", owner: false, bucket: .thisWeek)],
                                               later: [row("l-owner", owner: true, bucket: .later)]),
                                    products: report([]))
        #expect(r.waiting.map(\.item.title) == ["t-owner", "w-owner"])
        #expect(r.alsoToday.map(\.item.title) == ["t-fact"])
    }

    @Test func aProjectsWaitingComesFromItsOwnDomain() {
        let r = CenterBuilder.build(desk: desk(today: [row("mine", domain: "WorkTrack", owner: true, bucket: .today),
                                                       row("other", domain: "VELRO", owner: true, bucket: .today)]),
                                    products: report([card("worktrack", title: "WorkTrack")]))
        #expect(r.focus[0].waiting.map(\.item.title) == ["mine"])
    }

    @Test func theTierCanBeSetFromOutside() {
        let r = CenterBuilder.build(desk: desk(), products: report([card("velro")]), tier: { _ in .focus })
        #expect(r.focus.map(\.id) == ["velro"])
    }
}
