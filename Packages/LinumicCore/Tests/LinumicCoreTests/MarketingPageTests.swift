import Foundation
import Testing
@testable import LinumicCore

// The Marketing page (owner, 2026-11-13): every marketing obligation is on it, none is on the Brief, the Desk, the
// Center, the Obligations page or a project's readiness, the old pages lead to it, and the Mac's text size maps to the
// type scale. All fixtures are SAMPLE rows or the recorded seed; nothing is read.

private let now = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
private let utc = Calendar.utc
private func day(_ s: String) -> KeyDay { KeyDay(s)! }
private var today: KeyDay { KeyDay(now, calendar: utc) }

private func sample(_ id: String, area: ObligationArea, product: String? = "WorkTrack", due: String?, done: Bool = false) -> Obligation {
    Obligation(id: id, title: "SAMPLE \(id)", product: product, area: area, due: due.map(day), source: "sample.md:1", recordedOn: day("2026-10-20"),
               origin: .owner,
               completion: done ? ObligationCompletion(obligationID: id, due: due.map(day), on: day("2026-11-01"), evidence: "sample receipt", enteredAt: now) : nil)
}

/// The recorded seed (with its five marketing rows) plus two SAMPLE rows of the owner's: one marketing, one not.
private func register() -> ObligationsRegister {
    var file = ObligationsFile()
    _ = try? file.add(title: "SAMPLE: post the launch reel", product: "WorkTrack", area: .marketing, due: day("2026-11-01"),
                      consequence: nil, source: "sample note", now: now, calendar: utc)
    _ = try? file.add(title: "SAMPLE: renew the domain", product: "WorkTrack", area: .domains, due: day("2026-11-01"),
                      consequence: nil, source: "sample bill", now: now, calendar: utc)
    return ObligationsBuilder.build(file: file, live: ObligationLiveInput(), now: now, calendar: utc)
}

private func briefInput(_ register: ObligationsRegister) -> BriefInput {
    BriefInput(now: now, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
               licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
               worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
               operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []),
               obligations: BriefObligationsInput(register: register))
}

private func marketingIDs(_ r: ObligationsRegister) -> Set<String> { Set(r.obligations.filter { $0.area == .marketing }.map(\.id)) }

@Suite("Marketing page: marketing is shown there and nowhere else")
struct MarketingScopeTests {
    @Test func theFixtureHoldsMarketingRowsOfTheSeedAndOfTheOwner() {
        let r = register()
        #expect(r.issues.isEmpty)
        #expect(marketingIDs(r).count == 6, "five seed rows and the owner's SAMPLE row")
        #expect(r.obligations.contains { $0.title == "SAMPLE: renew the domain" })
    }

    @Test func theBriefAndSoTheDeskAndTheCenterLeaveMarketingOut() {
        let r = register()
        let section = DailyBriefBuilder.obligations(briefInput(r))
        let lineIDs = Set(section.lines.compactMap(\.obligationID))
        #expect(lineIDs.isDisjoint(with: marketingIDs(r)))
        #expect(lineIDs.contains(r.obligations.first { $0.title == "SAMPLE: renew the domain" }!.id), "the other areas stay")
        for o in r.obligations where o.area == .marketing { #expect(!ObligationsBriefRules.showsInBrief(o, today: today)) }

        let brief = DailyBrief(sections: [section], generatedAt: now)
        let desk = DeskBuilder.build(brief: brief, ledgers: .unsupported, state: DeskState(), now: now, calendar: utc)
        let deskIDs = Set((desk.today + desk.thisWeek + desk.later).compactMap(\.item.obligationID))
        #expect(deskIDs.isDisjoint(with: marketingIDs(r)))
        #expect(!deskIDs.isEmpty)

        let center = CenterBuilder.build(desk: desk, products: ProductsReport(cards: [], generatedAt: now, nothingRead: false), today: today,
                                         marketing: MarketingSummary(register: r, today: today))
        let centerIDs = Set((center.waiting + center.alsoToday).compactMap(\.item.obligationID))
        #expect(centerIDs.isDisjoint(with: marketingIDs(r)))
        // The Center's one line: how many marketing rows are overdue, nothing more.
        #expect(center.marketingOverdue == 4, "WorkTrack's queue end, the two clock-change rows and the SAMPLE reel")
        #expect(!center.isAllClear(staleSources: 0))
    }

    @Test func theCenterSaysNothingAboutMarketingWhenNothingIsOverdue() {
        let r = ObligationsRegister(obligations: [sample("m.soon", area: .marketing, due: "2026-11-20"),
                                                  sample("m.done", area: .marketing, due: "2026-10-01", done: true)],
                                    accounts: [], issues: [], builtAt: now)
        let empty = Desk(generatedAt: now, today: [], thisWeek: [], later: [], markedNotTicked: [], hidden: [], sources: [], obsoleteMarks: [])
        let center = CenterBuilder.build(desk: empty, products: ProductsReport(cards: [], generatedAt: now, nothingRead: false), today: today,
                                         marketing: MarketingSummary(register: r, today: today))
        #expect(center.marketingOverdue == 0)
        #expect(center.isAllClear(staleSources: 0))
    }

    @Test func theObligationsPageIsBuiltWithoutMarketingAndTheMarketingPageHoldsAllOfIt() {
        let r = register()
        let page = MarketingScope.withoutMarketing(r)
        #expect(page.obligations.allSatisfy { $0.area != .marketing })
        #expect(page.obligations.count == r.obligations.count - marketingIDs(r).count, "nothing else is dropped")
        #expect(page.accounts == r.accounts && page.issues == r.issues && page.unread == r.unread)
        let lanes = page.lanes(today: today).values.flatMap { $0 }
        #expect(lanes.allSatisfy { $0.area != .marketing })

        #expect(Set(MarketingScope.marketing(r).map(\.id)) == marketingIDs(r))
        let brands = MarketingQueue.build(register: r, files: [:], calendar: utc)
        #expect(Set(brands.flatMap(\.obligations).map(\.id)) == marketingIDs(r), "every marketing row is on the page, once")
        #expect(brands.flatMap(\.obligations).count == marketingIDs(r).count)
    }

    @Test func aMarketingRowOpensOnTheMarketingPage() {
        let r = register()
        for o in r.obligations where o.area == .marketing { #expect(o.destination == .marketing(o.id)) }
        let other = r.obligations.first { $0.title == "SAMPLE: renew the domain" }!
        #expect(other.destination == .obligation(other.id))
    }

    @Test func readinessCountsOnlyTheOtherAreas() {
        let product = CompanyProduct(id: "worktrack", title: "WorkTrack", inventoryID: nil, tracks: [], source: "fixture")
        let card = ProductCard(product: product, tracks: [], level: .level, repos: [], pulls: .unknown("not read"), ci: .unknown("not read"),
                               licences: nil, health: .unknown("not read"), readAt: nil)
        func check(_ rows: [Obligation]) -> ReadinessResult {
            let input = ReadinessInput(now: now, calendar: utc, cards: [card], ledgers: [], keys: nil, keyResults: [:],
                                       obligations: ObligationsRegister(obligations: rows, accounts: [], issues: [], builtAt: now),
                                       continuity: nil, installed: nil)
            return ReadinessBuilder.build(input)[0].result(.obligations)!
        }
        // Before 2026-11-13 an overdue post made WorkTrack read "Failed".
        let posts = check([sample("m.queue", area: .marketing, due: "2026-10-26"), sample("m.dst", area: .marketing, due: nil)])
        #expect(posts.state == .notApplicable, "only marketing rows: nothing recorded for readiness")
        let bill = check([sample("m.queue", area: .marketing, due: "2026-10-26"), sample("a.bill", area: .accounts, due: "2027-01-01")])
        #expect(bill.state == .passed)
        #expect(!bill.evidence.contains("SAMPLE m.queue"))
        let late = check([sample("m.queue", area: .marketing, due: "2026-12-30"), sample("a.bill", area: .accounts, due: "2026-11-01")])
        #expect(late.state == .failed, "an overdue row of another area still fails")
    }

    @Test func theSummaryCountsOpenRowsByWhereTheyStand() {
        let r = ObligationsRegister(obligations: [sample("a", area: .marketing, due: "2026-11-01"), sample("b", area: .marketing, due: "2026-11-15"),
                                                  sample("c", area: .marketing, due: nil), sample("d", area: .marketing, due: "2026-10-01", done: true),
                                                  sample("e", area: .accounts, due: "2026-10-01")],
                                    accounts: [], issues: [], builtAt: now)
        let s = MarketingSummary(register: r, today: today)
        #expect(s.overdue == 1 && s.dueThisWeek == 1 && s.dateUnknown == 1 && s.open == 3 && s.done == 1)
    }

    @Test func theBrandWithTheOldestOverdueRowComesFirst() {
        let brands = MarketingQueue.urgentFirst(MarketingQueue.build(register: register(), files: [:], calendar: utc), today: today)
        // WorkTrack's queue ended 2026-10-26, SafeBeauty's oldest open row is 2026-10-30, VELRO has no date recorded.
        #expect(brands.map(\.brand) == ["WorkTrack", "SafeBeauty", "VELRO"])
        let quiet = MarketingQueueBrand(ledger: nil, brand: "SAMPLE quiet", obligations: [], file: nil, changedSince: [])
        let late = MarketingQueueBrand(ledger: nil, brand: "SAMPLE late", obligations: [sample("x", area: .marketing, due: "2026-09-01")],
                                       file: nil, changedSince: [])
        #expect(MarketingQueue.urgentFirst([quiet] + brands + [late], today: today).map(\.brand)
                == ["SAMPLE late", "WorkTrack", "SafeBeauty", "VELRO", "SAMPLE quiet"])
    }
}

@Suite("Marketing page: the old pages lead to it")
struct MarketingRedirectTests {
    @Test func eachOldPageOpensItsTab() {
        #expect(MarketingTab.replacing(pageID: "marketingQueue") == .queue)
        #expect(MarketingTab.replacing(pageID: "contentCalendar") == .posts)
        #expect(MarketingTab.replacing(pageID: "socialMedia") == .posts)
        #expect(MarketingTab.replacing(pageID: "marketIntelligence") == .research)
        for id in ["marketing", "center", "obligations", "aiAssistant", ""] { #expect(MarketingTab.replacing(pageID: id) == nil) }
        #expect(Set(MarketingTab.replacedPageIDs.compactMap(MarketingTab.replacing(pageID:))) == Set(MarketingTab.allCases))
    }

    @Test func theSidebarHasOneMarketingPageAmongTheDailyOnes() {
        #expect(SidebarDaily.contains("marketing"))
        #expect(SidebarDaily.ids.firstIndex(of: "marketing") == SidebarDaily.ids.firstIndex(of: "productBoard")! + 1)
        for id in MarketingTab.replacedPageIDs {
            #expect(!SidebarDaily.contains(id) && !SidebarArchive.isArchived(id) && SidebarArchive.coveredBy(id) == nil)
        }
    }
}

@Suite("Text size on the Mac")
struct TextSizeTests {
    @Test func largeIsTheDefaultAndAnUnknownValueFallsBackToIt() {
        #expect(TextSizeSetting.default == .large)
        #expect(TextSizeSetting(stored: nil) == .large)
        #expect(TextSizeSetting(stored: "huge") == .large)
        #expect(TextSizeSetting(stored: "standard") == .standard)
        #expect(TextSizeSetting(stored: "larger") == .larger)
    }

    @Test func standardIsTheMacsOwnScale() {
        let mac: [TextStyleName: Double] = [.largeTitle: 26, .title: 22, .title2: 17, .title3: 15, .headline: 13, .body: 13, .callout: 12,
                                             .subheadline: 11, .footnote: 10, .caption: 10, .caption2: 10]
        for style in TextStyleName.allCases { #expect(style.points(.standard) == mac[style]) }
        #expect(TextSizeSetting.standard.spacingScale == 1)
    }

    @Test func largeIsAboutOneStepUpAndLargerOneMore() {
        for style in TextStyleName.allCases {
            let standard = style.points(.standard), large = style.points(.large), larger = style.points(.larger)
            let growth = large / standard - 1
            #expect(growth >= 0.09 && growth <= 0.21, "\(style): +\(Int(growth * 100))%")
            #expect(larger > large, "\(style) grows again at Larger")
            #expect(large == large.rounded() && larger == larger.rounded(), "whole points")
        }
        #expect(TextStyleName.body.points(.large) == 15 && TextStyleName.caption.points(.large) == 12)
        // The order of the scale holds at every size: a section title stays above a row's, a caption below.
        for size in TextSizeSetting.allCases {
            #expect(TextStyleName.title3.points(size) > TextStyleName.callout.points(size))
            #expect(TextStyleName.callout.points(size) > TextStyleName.caption.points(size))
            #expect(TextStyleName.title2.points(size) > TextStyleName.title3.points(size))
        }
        #expect(TextStyleName.headline.isBold && !TextStyleName.body.isBold)
    }

    @Test func stepsGoUpAndDownAndStopAtTheEnds() {
        #expect(TextSizeSetting.standard.larger == .large && TextSizeSetting.large.larger == .larger && TextSizeSetting.larger.larger == nil)
        #expect(TextSizeSetting.larger.smaller == .large && TextSizeSetting.large.smaller == .standard && TextSizeSetting.standard.smaller == nil)
        #expect(TextSizeSetting.large.spacingScale > 1 && TextSizeSetting.larger.spacingScale > TextSizeSetting.large.spacingScale)
    }
}
