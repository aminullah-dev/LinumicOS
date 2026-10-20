import Foundation
import Testing
@testable import LinumicCore

// The marketing queue (roadmap module 8): its seed rows, the brands beside their ledgers, the "changed since" check
// from file dates only, and the grant that Verify may keep. No ledger is read.

private let now = Date(timeIntervalSince1970: 1_792_497_600) // 2026-10-20T12:00:00Z
private let home = "/Users/owner"

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func register(file: ObligationsFile = ObligationsFile(), seed: [Obligation] = ObligationSeed.obligations) -> ObligationsRegister {
    ObligationsBuilder.build(file: file, live: ObligationLiveInput(), now: now, calendar: utc, seed: seed, seedAccounts: [])
}

@Suite("Marketing queue: the seed")
struct MarketingSeedTests {
    @Test func everyBrandQueueAndTheClockChangeAreObligationsWithSources() {
        let rows = ObligationSeed.obligations.filter { $0.area == .marketing }
        #expect(Set(rows.map(\.id)) == ["marketing.worktrack-queue-end", "marketing.safebeauty-queue-end", "marketing.velro-queue",
                                        "marketing.safebeauty-dst-pashto", "marketing.safebeauty-dst-reels"])
        for o in rows {
            #expect(!o.source.isEmpty && o.recordedOn != nil, "\(o.id) has its source and the day it was recorded")
            #expect(o.origin == .seed && !ObligationsBuilder.isLiveID(o.id))
            #expect(MarketingLedgers.ledger(forBrand: o.product) != nil, "\(o.id) sits beside its brand's ledger")
        }
        // The queue ends, as their ledgers and notes record them.
        #expect(rows.first { $0.id == "marketing.worktrack-queue-end" }?.due == KeyDay("2026-10-26"))
        #expect(rows.first { $0.id == "marketing.safebeauty-queue-end" }?.due == KeyDay("2026-11-13"))
        // No schedule is recorded for VELRO: its end is unknown, never invented, and no consequence is made up.
        let velro = rows.first { $0.id == "marketing.velro-queue" }
        #expect(velro?.due == nil && velro?.consequence == nil)
        // The clock change: both rows due before 2026-11-01's effects reach their posts.
        #expect(rows.first { $0.id == "marketing.safebeauty-dst-pashto" }?.due == KeyDay("2026-10-30"))
        #expect(rows.first { $0.id == "marketing.safebeauty-dst-reels" }?.due == KeyDay("2026-11-09"))
    }

    @Test func theRegisterAcceptsThemAndTheDeskShowsThem() {
        let r = register()
        #expect(r.issues.isEmpty)
        let lanes = r.lanes(today: KeyDay(now, calendar: utc))
        #expect(lanes[.dateUnknown]?.contains { $0.id == "marketing.velro-queue" } == true)
        let brief = DailyBriefBuilder.obligations(BriefInput(now: now, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                                                             licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                                                             worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                                                             operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []),
                                                             obligations: BriefObligationsInput(register: r)))
        let ids = Set(brief.lines.map(\.id))
        for id in ["marketing.worktrack-queue-end", "marketing.safebeauty-queue-end", "marketing.velro-queue"] {
            #expect(ids.contains("obligation.\(id)"))
        }
    }

    @Test func theNewRowsAreSentForTheServersSweepAtTheNewRevision() {
        #expect(ObligationSeed.revision == 5)
        let sent = DeskCloudMapping.seedChanges(remote: [], seed: ObligationSeed.obligations, revision: ObligationSeed.revision)
        #expect(sent.contains { $0.key == "marketing.safebeauty-queue-end" && $0.seedRevision == 5 })
        #expect(sent.contains { $0.key == "marketing.velro-queue" })
    }
}

@Suite("Marketing queue: brands, ledgers and Verify")
struct MarketingQueueTests {
    @Test func everyLedgerIsListedWithItsBrandsObligationsInOrder() {
        let brands = MarketingQueue.build(register: register(), files: [:], calendar: utc)
        #expect(brands.map(\.brand) == ["WorkTrack", "SafeBeauty", "VELRO"], "focus first, and no brand without a ledger here")
        let safe = brands[1]
        #expect(safe.obligations.map(\.id) == ["marketing.safebeauty-dst-pashto", "marketing.safebeauty-dst-reels", "marketing.safebeauty-queue-end"])
        #expect(brands[2].obligations.map(\.id) == ["marketing.velro-queue"])
        #expect(brands.allSatisfy { $0.changedSince.isEmpty }, "no ledger date read, no flag")
    }

    @Test func aLedgerChangedAfterTheDateWasRecordedIsFlaggedFromDatesOnly() {
        let r = register()
        let after = KeyDay("2026-10-19")!.start(calendar: utc).addingTimeInterval(3600)
        let before = KeyDay("2026-10-14")!.start(calendar: utc)
        var brands = MarketingQueue.build(register: r, files: ["safebeauty": .modified(after)], calendar: utc)
        // The queue end was recorded 2026-10-15 and the clock-change rows 2026-10-19: a change on 2026-10-19 is later
        // than the first only.
        #expect(brands[1].changedSince == ["marketing.safebeauty-queue-end"])
        brands = MarketingQueue.build(register: r, files: ["safebeauty": .modified(before)], calendar: utc)
        #expect(brands[1].changedSince.isEmpty)
        // A date the owner set after verifying counts from the day he set it.
        brands = MarketingQueue.build(register: r, files: ["safebeauty": .modified(after)],
                                      dateEnteredOn: ["marketing.safebeauty-queue-end": KeyDay("2026-10-20")!], calendar: utc)
        #expect(brands[1].changedSince.isEmpty)
        // Missing or unknown files flag nothing.
        brands = MarketingQueue.build(register: r, files: ["safebeauty": .missing, "worktrack": .unknown("x")], calendar: utc)
        #expect(brands.allSatisfy { $0.changedSince.isEmpty })
    }

    @Test func aDoneRowIsNotFlagged() throws {
        var file = ObligationsFile()
        try file.complete("marketing.safebeauty-queue-end", due: KeyDay("2026-11-13"), on: KeyDay("2026-10-20")!, evidence: "sample: 12 new posts scheduled",
                          now: now, calendar: utc)
        let later = KeyDay("2026-10-20")!.start(calendar: utc)
        let brands = MarketingQueue.build(register: register(file: file), files: ["safebeauty": .modified(later)], calendar: utc)
        #expect(!brands[1].changedSince.contains("marketing.safebeauty-queue-end"))
        #expect(brands[1].obligations.last?.id == "marketing.safebeauty-queue-end", "done rows last")
    }

    @Test func aMarketingRowOfABrandWithoutALedgerIsStillShown() {
        let other = Obligation(id: "owner.sample", title: "Sample brand's queue ends", product: "Sample Brand", area: .marketing,
                               due: KeyDay("2026-11-01"), source: "sample note", recordedOn: KeyDay("2026-10-20"), origin: .seed)
        let brands = MarketingQueue.build(register: register(seed: [other]), files: [:], calendar: utc)
        #expect(brands.last?.brand == "Sample Brand" && brands.last?.ledger == nil)
    }

    @Test func verifyKeepsOnlyALedgersOwnFolder() {
        for ledger in MarketingLedgers.all {
            #expect(MarketingLedgers.decide("\(home)/\(ledger.folder)", home: home) == .accept)
            #expect(ledger.file.hasPrefix(ledger.folder + "/"), "the ledger is inside the folder its grant covers")
        }
        for wider in ["\(home)/Desktop/1", "\(home)/Desktop", home, "\(home)/Desktop/1/SafeBeauty-Marketing/captions"] {
            guard case .refuse = MarketingLedgers.decide(wider, home: home) else {
                Issue.record("\(wider) must be refused")
                continue
            }
        }
        #expect(MarketingLedgers.ledger(containing: "\(home)/Desktop/1/SafeBeauty-Marketing/STATUS.md", home: home)?.id == "safebeauty")
    }
}

@Suite("Sidebar: the Archive group")
struct SidebarArchiveTests {
    /// The sidebar's groups as the app lists them (Navigation.swift, `SidebarSection.grouped`), by page id.
    private let groups: [SidebarGroup] = [
        SidebarGroup(title: nil, items: ["desk", "obligations", "money", "sales", "legal", "dashboard", "brief", "monitor", "automation",
                                         "releaseCenter", "platforms", "oversight", "licences", "worktrackCustomers", "operations",
                                         "siteMessages", "vault", "keys", "continuity"]),
        SidebarGroup(title: "Products", items: ["allProducts", "verification", "releases", "roadmap", "issues"]),
        SidebarGroup(title: "Development", items: ["repositories", "builds", "deployments"]),
        SidebarGroup(title: "Stores", items: ["appStore", "googlePlay"]),
        SidebarGroup(title: "Marketing", items: ["marketingQueue", "socialMedia", "contentCalendar"]),
        SidebarGroup(title: "Intelligence", items: ["marketIntelligence", "aiAssistant"]),
        SidebarGroup(title: "Settings", items: ["integrations", "security", "account"]),
    ]

    @Test func theSixManualPagesMoveToALastCollapsedGroup() {
        let arranged = SidebarArchive.arrange(groups)
        let archive = arranged.last
        #expect(archive?.isArchive == true && archive?.title == "Archive")
        #expect(archive?.items == ["releases", "roadmap", "issues", "builds", "deployments", "socialMedia"])
        #expect(arranged.dropLast().allSatisfy { !$0.isArchive })
        #expect(arranged.first { $0.title == "Products" }?.items == ["allProducts", "verification"])
        #expect(arranged.first { $0.title == "Development" }?.items == ["repositories"])
        #expect(arranged.first { $0.title == "Marketing" }?.items == ["marketingQueue", "contentCalendar"])
    }

    @Test func noPageIsLostOrAddedAndTheOthersKeepTheirPlace() {
        let arranged = SidebarArchive.arrange(groups)
        let before = groups.flatMap(\.items)
        let after = arranged.flatMap(\.items)
        #expect(after.count == before.count && Set(after) == Set(before), "every page once, none removed")
        #expect(after.filter { !SidebarArchive.isArchived($0) } == before.filter { !SidebarArchive.isArchived($0) })
        // A group left with no page is dropped; one that never held an archived page is untouched.
        let lone = SidebarArchive.arrange([SidebarGroup(title: "Old", items: ["roadmap", "issues"]), SidebarGroup(title: "Kept", items: ["desk"])])
        #expect(lone.map(\.title) == ["Kept", "Archive"])
        // The Archive never invents a page that was not in the sidebar.
        #expect(SidebarArchive.arrange([SidebarGroup(title: nil, items: ["desk", "builds"])]).last?.items == ["builds"])
        #expect(SidebarArchive.arrange([SidebarGroup(title: nil, items: ["desk"])]).count == 1)
    }

    @Test func everyArchivedPageSaysWhatCoversItNow() {
        #expect(SidebarArchive.ids.count == 6)
        for id in SidebarArchive.ids { #expect(SidebarArchive.coveredBy(id) != nil) }
        #expect(SidebarArchive.coveredBy("desk") == nil)
    }
}
