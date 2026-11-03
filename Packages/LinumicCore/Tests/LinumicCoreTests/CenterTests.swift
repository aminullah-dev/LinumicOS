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

    // MARK: Tiers

    @Test func aChoiceOverridesTheDefaultAndChoosingTheDefaultClearsIt() {
        var tiers = ProjectTiers()
        #expect(tiers.tier(forProduct: "velro") == .maintenance)
        tiers.set(.focus, forProduct: "velro")
        #expect(tiers.tier(forProduct: "velro") == .focus)
        #expect(tiers.chosen == ["velro": .focus])
        tiers.set(.maintenance, forProduct: "velro")
        #expect(tiers.chosen.isEmpty)
    }

    @Test func tiersSurviveTheFileAndABadFileMeansNoChoices() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tiers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProjectTiersStore(fileURL: url)
        #expect(store.load() == ProjectTiers())
        var tiers = ProjectTiers()
        tiers.set(.archived, forProduct: "velro")
        try store.save(tiers)
        #expect(store.load().tier(forProduct: "velro") == .archived)
        try Data("not json".utf8).write(to: url)
        #expect(store.load() == ProjectTiers())
    }

    // MARK: Projects added from the inventory

    private func listing(_ store: AppStore, _ id: String?) -> StoreListing {
        var l = StoreListing(store: store)
        l.appIdentifier = id
        return l
    }

    @Test func anInventoryProductNotInTheCatalogGetsACardWithoutABuild() {
        var product = Product(id: "newapp", name: "New App")
        product.storeListings = [listing(.appStore, "com.new.app"), listing(.googlePlay, "com.new.app"), listing(.appStore, nil), listing(.appStore, "com.new.app")]
        let all = ProductsCatalog.all(inventory: [product], catalog: [])
        #expect(all.map(\.id) == ["newapp"])
        #expect(all[0].inventoryID == "newapp")
        #expect(all[0].slots.map(\.platform) == [.iOS, .android], "one slot per platform and identifier, none without an identifier")
        #expect(all[0].slots.allSatisfy { $0.compared && $0.noVersionFile != nil })
        #expect(CenterTier.default(forProduct: "newapp") == .maintenance)
    }

    @Test func aProductWithNoListingStillGetsACard() {
        let all = ProductsCatalog.all(inventory: [Product(id: "idea", name: "Idea")], catalog: [])
        #expect(all.map(\.id) == ["idea"] && all[0].tracks.isEmpty)
    }

    @Test func aCataloguedProductIsNotListedTwice() {
        let all = ProductsCatalog.all(inventory: [Product(id: "worktrack", name: "WorkTrack")])
        #expect(all.count(where: { $0.inventoryID == "worktrack" }) == 1)
        #expect(all.count == ProductsCatalog.products.count)
    }

    @Test func anAddedProductsCommitsAreReadButAnArchivedOnesAreNot() {
        let added = Product(id: "newapp", name: "New App")
        let book = Product(id: "soder-hakem", name: "SODER-HAKEM")
        let ids = ProductsCatalog.read(inventory: [added, book]).map(\.id)
        #expect(ids.contains("newapp") && !ids.contains("soder-hakem"))
        #expect(ids.contains("dukanpro"), "a catalogued product stays read whatever its tier")
    }

    @Test func aConsoleAppWithoutAnInventoryListingIsUnknownUntilReadNotAbsent() throws {
        // In App Review on 2026-11-02: saying "not in a store" would be false, so unread stays unknown.
        let input = ProductsInput(now: now, products: [], tracking: [], releases: ReleaseCenterSnapshot(),
                                  licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil), monitor: MonitorSnapshot())
        let card = try #require(ProductsBuilder.build(input).card("pashtolikman"))
        let slot = try #require(card.slots.first)
        #expect(slot.live.isUnknown)
        #expect(slot.build.isUnknown)
    }

    @Test func aProductNotReadFromAConsoleStillSaysItIsNotInAStore() throws {
        var added = Product(id: "newapp", name: "New App")
        added.storeListings = []
        let product = CompanyProduct(id: "x", title: "X", inventoryID: nil, tracks: [ProductTrack(id: "app", title: "X", slots: [
            ProductSlot(id: "x.app.ios", platform: .iOS, label: "X", appIdentifier: "com.x.app", noVersionFile: "n", build: .store, compared: true, source: "t"),
        ])], source: "t")
        let input = ProductsInput(now: now, products: [added], tracking: [], releases: ReleaseCenterSnapshot(),
                                  licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil), monitor: MonitorSnapshot(), catalog: [product])
        let slot = try #require(ProductsBuilder.build(input).card("x")?.slots.first)
        guard case .none = slot.live else { Issue.record("no listing and not a console app reads as not in a store"); return }
    }

    @Test func pashtoLikmanIsReadFromTheStore() throws {
        let product = try #require(ProductsCatalog.product("pashtolikman"))
        #expect(product.slots.map(\.appIdentifier) == ["com.pashtokey.app"])
        #expect(ReleaseCatalog.apps(from: []).contains { $0.appIdentifier == "com.pashtokey.app" && $0.store == .appStore })
    }

    // MARK: Weekly review

    private func source(_ id: String, _ state: DeskSourceStatus.State) -> DeskSourceStatus {
        DeskSourceStatus(source: LedgerSource(id, "Projects/Multiplatform/\(id)/PRIORITIES.md", .named(id)), displayPath: "~/\(id)", state: state, readAt: now)
    }

    @Test func aLedgerOverAWeekOldIsDueOldestFirst() throws {
        let today = try #require(KeyDay("2026-11-02"))
        var d = desk()
        d.sources = [
            source("week", .read(open: 1, ticked: 0, skipped: [], reviewedOn: KeyDay("2026-10-26"))),   // exactly 7 days: not yet
            source("newer", .read(open: 1, ticked: 0, skipped: [], reviewedOn: KeyDay("2026-10-25"))),
            source("older", .read(open: 1, ticked: 0, skipped: [], reviewedOn: KeyDay("2026-10-19"))),
            source("noDay", .read(open: 1, ticked: 0, skipped: [], reviewedOn: nil)),
            source("report", .report(today: 1, thisWeek: 0, skipped: [], day: KeyDay("2026-10-01"))),
            source("missing", .notFound),
        ]
        let overdue = CenterBuilder.build(desk: d, products: report([]), today: today).overdueLedgers
        #expect(overdue.map(\.path) == ["~/older", "~/newer"])
    }

    @Test func withoutTodayNothingIsDue() {
        var d = desk()
        d.sources = [source("older", .read(open: 1, ticked: 0, skipped: [], reviewedOn: KeyDay("2020-01-01")))]
        #expect(CenterBuilder.build(desk: d, products: report([])).overdueLedgers.isEmpty)
    }
}
