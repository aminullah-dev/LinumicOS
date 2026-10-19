import Foundation
import Testing
@testable import LinumicCore

// Ledgers: the PRIORITIES.md and NEXT-ACTIONS parsers, the allow-list and the reader. Invented fixtures and an
// in-memory file system only (LedgerTestSupport.swift).

private let now = LedgerFixtures.now
private let home = LedgerFixtures.home
private var utc: Calendar { LedgerFixtures.utc }
private func text(_ name: String) throws -> String { try LedgerFixtures.text(name) }
private typealias FakeFS = FakeLedgerFS

// MARK: - PRIORITIES.md

@Suite("Ledgers: PRIORITIES.md")
struct LedgerParserTests {
    @Test func readsOpenCheckboxesAtAnyIndentAndTheNumberedListUnderPriorities() throws {
        let ledger = LedgerParser.parse(try text("ledger-priorities-sample"))
        #expect(ledger.items.map(\.line) == [12, 14, 16, 17, 21, 25, 29, 32, 39, 40])
        #expect(ledger.items.filter { $0.kind == .numbered }.map(\.line) == [39, 40])
        #expect(ledger.items.first { $0.line == 17 }?.indent == 4)   // a sub-sub-item
        #expect(ledger.ticked == 2)
    }

    @Test func p0IsHighP1NormalAndTheRestInformation() throws {
        let ledger = LedgerParser.parse(try text("ledger-priorities-sample"))
        let severity = Dictionary(uniqueKeysWithValues: ledger.items.map { ($0.line, $0.priority.severity) })
        for l in [12, 14, 16, 17, 21] { #expect(severity[l] == .high) }   // 21 sits under "### …" inside P0
        #expect(severity[25] == .normal && severity[29] == .normal)
        for l in [32, 39, 40] { #expect(severity[l] == .info) }
        #expect(ledger.items.first { $0.line == 21 }?.section == "جزئیات P0")
    }

    @Test func persianDigitsInTheReviewDateAndTheNumbers() throws {
        let ledger = LedgerParser.parse(try text("ledger-priorities-sample"))
        #expect(ledger.reviewedOn == KeyDay("2026-10-02"))   // the first date after the colon, not the earlier review
        #expect(ledger.reviewLine == 5)
        #expect(ledger.items.first { $0.line == 39 }?.title == "بند شماره‌دار با ارقام فارسی")
        #expect(LedgerText.asciiDigits("۲۰۲۶-۱۰-۱۹ و ٣") == "2026-10-19 و 3")
    }

    @Test func brokenLinesAreSetAsideNotGuessed() throws {
        let ledger = LedgerParser.parse(try text("ledger-priorities-sample"))
        #expect(ledger.skippedLines == [26, 27, 28, 41])
        // The fenced block, the link bullet and the numbered line under P0 are not items at all.
        #expect(!ledger.items.contains { [9, 22, 35].contains($0.line) })
    }

    @Test func theBoldLeadIsTheTitle() {
        let ledger = LedgerParser.parse("## P0\n- [ ] **کلیدهای امضا:** همهٔ keystore ها.\n- [ ] بدون عنوان پررنگ")
        #expect(ledger.items[0].title == "کلیدهای امضا")
        #expect(ledger.items[0].detail == "همهٔ keystore ها.")
        #expect(ledger.items[1].title == "بدون عنوان پررنگ")
        #expect(ledger.items[1].detail == nil)
    }

    @Test func aFileWithoutAReviewLineSaysSo() {
        let ledger = LedgerParser.parse("# اولویت‌ها\n\n## وضعیت (۲۰۲۶-۱۰-۱۲)\n- [ ] کار")
        #expect(ledger.reviewLine == nil && ledger.reviewedOn == nil)
        #expect(ledger.items.count == 1 && ledger.items[0].priority == .other)
    }
}

// MARK: - NEXT-ACTIONS

@Suite("Ledgers: NEXT-ACTIONS")
struct NextActionsParserTests {
    @Test func readsOnlyTheOwnersTodayAndThisWeekItems() throws {
        let report = NextActionsParser.parse(try text("next-actions-sample"), fileName: "NEXT-ACTIONS-2026-10-12.md")
        #expect(report.day == KeyDay("2026-10-12"))
        #expect(report.items.map(\.line) == [6, 11, 19, 21])
        #expect(report.items.map(\.section) == [.today, .today, .thisWeek, .thisWeek])
        #expect(report.items.map(\.slug) == ["sample-today-one", "sample-today-two", "sample-week-one", "sample-week-two"])
        #expect(report.items[1].number == 2)   // "۲)"
        #expect(report.items[1].title == "SafeBeauty: کار امروز دوم با شمارهٔ فارسی")
        #expect(report.items[0].body == ["چه کنید:", "- گام نمونه (TEST)."])
        #expect(report.sections == [.today, .thisWeek])
    }

    @Test func anItemWithoutASourceLineIsSetAside() throws {
        let report = NextActionsParser.parse(try text("next-actions-sample"))
        #expect(report.skippedLines == [14])
        #expect(report.day == KeyDay("2026-10-12"))   // from the first line when there is no file name
    }

    @Test func theFirstProductAndSlugOfTheSourceLine() {
        let keys = NextActionsParser.sourceParts("Keys / khayatyar-signing-key و second-offline-copy؛ Talar / x")
        #expect(keys?.product == "Keys" && keys?.slug == "khayatyar-signing-key")
        let site = NextActionsParser.sourceParts("linumic.com / sureforms-abilities؛ Linumic OS / verify")
        #expect(site?.product == "linumic.com" && site?.slug == "sureforms-abilities")
        let wt = NextActionsParser.sourceParts("WorkTrack / first-customer-contract (حافظه)")
        #expect(wt?.product == "WorkTrack" && wt?.slug == "first-customer-contract")
        #expect(NextActionsParser.sourceParts("بدون اسلش") == nil)
    }

    @Test func theNewestReportByTheDayInItsName() {
        #expect(NextActionsParser.newest(["NEXT-ACTIONS-2026-10-09.md", "NEXT-ACTIONS-2026-10-19.md", "notes.md",
                                          "NEXT-ACTIONS-2026-10-19.md.bak", "CLEANUP-2026-10-30.md"]) == "NEXT-ACTIONS-2026-10-19.md")
        #expect(NextActionsParser.newest(["PRIORITIES.md"]) == nil)
    }
}

// MARK: - Allow-list and reading

@Suite("Ledgers: allow-list and reading")
struct LedgerReaderTests {
    @Test func onlyTheListedFilesMayBeOpened() {
        for s in LedgerAllowList.priorities { #expect(LedgerAllowList.allows(s.path)) }
        #expect(LedgerAllowList.allows("Projects/Multiplatform/NEXT-ACTIONS-2026-10-19.md"))
        #expect(!LedgerAllowList.allows("Projects/Multiplatform/WorkTrack/.env"))
        #expect(!LedgerAllowList.allows("Projects/Multiplatform/WorkTrack/../Velro/PRIORITIES.md"))
        #expect(!LedgerAllowList.allows("Projects/Multiplatform/./PRIORITIES.md"))
        #expect(!LedgerAllowList.allows("/Users/owner/Projects/Multiplatform/PRIORITIES.md"))
        #expect(!LedgerAllowList.allows("~/Projects/Multiplatform/PRIORITIES.md"))
        #expect(!LedgerAllowList.allows("Projects/Multiplatform/Velro/NEXT-ACTIONS-2026-10-19.md"))
        #expect(!LedgerAllowList.allows("Projects/Multiplatform/NEXT-ACTIONS-latest.md"))
        #expect(!LedgerAllowList.allows("Projects/Multiplatform/AfghanJama/PRIORITIES.md"))
        #expect(LedgerAllowList.priorities.count == 8)
    }

    @Test func notGrantedNotFoundLinksAndReadFiles() throws {
        var fs = FakeFS()
        fs.files["\(home)/Projects/Multiplatform/PRIORITIES.md"] = "آخرین بازبینی: 2026-10-10\n## P0\n- [ ] یک"
        fs.files["\(home)/Projects/Multiplatform/WorkTrack/PRIORITIES.md"] = try text("ledger-priorities-sample")
        fs.links.insert("\(home)/Projects/Multiplatform/Velro/PRIORITIES.md")
        fs.files["\(home)/Projects/Multiplatform/DukanPro/PRIORITIES.md"] = "x"
        fs.sizes["\(home)/Projects/Multiplatform/DukanPro/PRIORITIES.md"] = 5_000_000
        fs.files["\(home)/Projects/Multiplatform/NEXT-ACTIONS-2026-10-09.md"] = "old"
        fs.files["\(home)/Projects/Multiplatform/NEXT-ACTIONS-2026-10-12.md"] = try text("next-actions-sample")
        fs.files["\(home)/Games/BE-PAYA/PRIORITIES.md"] = "## اولویت‌های بعدی\n1. یک"
        // Only ~/Projects/Multiplatform is granted.
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform/"], fs: fs, now: now)
        #expect(reading.files.count == 9)
        #expect(reading.file("bepaya")?.status == .notGranted)
        #expect(reading.file("talar")?.status == .notFound)
        #expect(reading.file("safebeauty")?.status == .notFound)
        guard case .unreadable = reading.file("velro")?.status else { Issue.record("a link is not followed"); return }
        guard case .unreadable = reading.file("dukanpro")?.status else { Issue.record("too large"); return }
        guard case .read(.priorities(let wt)) = reading.file("worktrack")?.status else { Issue.record("WorkTrack read"); return }
        #expect(wt.items.count == 10)
        let next = try #require(reading.file("next-actions"))
        #expect(next.path == "Projects/Multiplatform/NEXT-ACTIONS-2026-10-12.md")
        guard case .read(.nextActions(let n)) = next.status else { Issue.record("newest NEXT-ACTIONS read"); return }
        #expect(n.items.count == 4)
    }

    @Test func noReportInTheFolderIsNotFound() {
        let fs = FakeFS(files: ["\(home)/Projects/Multiplatform/PRIORITIES.md": "x"])
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)
        #expect(reading.file("next-actions")?.status == .notFound)
        #expect(reading.file("next-actions")?.displayPath == "~/Projects/Multiplatform/NEXT-ACTIONS-*.md")
    }

    @Test func nothingGrantedMeansEveryLedgerIsNotGranted() {
        let reading = LedgerReader.read(home: home, granted: [], fs: FakeFS(), now: now)
        let statuses = reading.files.map(\.status)
        #expect(statuses.allSatisfy { $0 == .notGranted })
    }
}

// MARK: - Domains

@Suite("Desk: products")
struct DeskDomainTests {
    @Test func namesOfRecordMapToProductsAndUnknownNamesStayAsTheyAre() {
        #expect(DeskDomain.named("WorkTrack") == .worktrack)
        #expect(DeskDomain.named("Safe beauty") == .safeBeauty)
        #expect(DeskDomain.named("aminullah-dev/WorkTrack") == .worktrack)
        #expect(DeskDomain.named("VELRO Driver") == .velro)
        #expect(DeskDomain.named("linumic.com") == .website)
        #expect(DeskDomain.named("Linumic OS") == .linumicOS)
        #expect(DeskDomain.named(nil) == .shared)
        let keys = DeskDomain.named("Keys")
        #expect(keys.key == "other:keys" && keys.name == "Keys")
    }

    @Test func focusProductsComeFirstAndAllProductsLast() {
        let sorted = [DeskDomain.shared, .velro, .safeBeauty, .named("GitHub"), .worktrack, .bePaya].sorted(by: DeskDomain.order)
        #expect(sorted.map(\.key) == ["worktrack", "safebeauty", "bepaya", "other:github", "velro", "shared"])
    }
}
