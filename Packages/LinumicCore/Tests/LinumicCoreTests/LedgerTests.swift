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

/// The same text with Windows line endings: a CRLF copy of an LF fixture, made here so it can't be normalised away.
private func crlf(_ lf: String) -> String {
    let t = lf.replacingOccurrences(of: "\n", with: "\r\n")
    precondition(t.utf8.contains(13) && !lf.utf8.contains(13))
    return t
}

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

    @Test func windowsLineEndingsGiveTheSameItemsAndLines() throws {
        let lf = try text("ledger-priorities-sample")
        let a = LedgerParser.parse(lf), b = LedgerParser.parse(crlf(lf))
        #expect(b.items.map(\.line) == a.items.map(\.line))
        #expect(b.items.map(\.text) == a.items.map(\.text))
        #expect(b.items.map(\.notes) == a.items.map(\.notes))
        #expect(b.ticked == 2 && b.skippedLines == a.skippedLines && b.reviewLine == 5 && b.reviewedOn == a.reviewedOn)
        #expect(b == a)
        // A lone carriage return (old Mac) is a line break too.
        #expect(LedgerParser.parse("## P0\r- [ ] یک\r- [ ] دو").items.map(\.line) == [2, 3])
    }

    @Test func theLinesUnderAnItemTravelWithIt() throws {
        let ledger = LedgerParser.parse("""
        آخرین بازبینی: ۲۰۲۶-۱۰-۱۹
        ## P0 — فوری
        - [ ] **انتشار اندروید.** نسخهٔ release هیچ‌وقت ساخته نشده.
          - ۲۰۲۶-۱۰-۱۹: این جمله درست نیست. APK امضاشده عمومی است.
          - keystore ساخته شود.
            - ۲۰۲۶-۱۰-۱۹: کلید از قبل هست؛ کلید تازه آپدیت را ناممکن می‌کند.

          - بعد از یک سطر خالی هنوز زیر همین مورد.
        - [ ] **کمبودهای شناخته‌شده:**
          - حذف نرم ندارد.
          - [x] شناسهٔ درخواست — انجام‌شده.
            - مدرک: زیر بند تیک‌خورده، نه زیر بند بالا.
          - ثبت تاریخچه خطا را نادیده می‌گیرد.
          - [ ] زیربند باز
            - یادداشت زیربند
        متن بی‌تورفتگی، زیر هیچ موردی نیست.
        - [ ] بی‌یادداشت
        """)
        #expect(ledger.items.map(\.line) == [3, 9, 14, 17])
        try #require(ledger.items.count == 4)
        #expect(ledger.items[0].notes == ["- ۲۰۲۶-۱۰-۱۹: این جمله درست نیست. APK امضاشده عمومی است.", "- keystore ساخته شود.",
                                          "- ۲۰۲۶-۱۰-۱۹: کلید از قبل هست؛ کلید تازه آپدیت را ناممکن می‌کند.",
                                          "- بعد از یک سطر خالی هنوز زیر همین مورد."])
        #expect(ledger.items[1].notes == ["- حذف نرم ندارد.", "- ثبت تاریخچه خطا را نادیده می‌گیرد."])
        #expect(ledger.items[2].notes == ["- یادداشت زیربند"])
        #expect(ledger.items[3].notes.isEmpty)
        #expect(ledger.items[0].notes.filter(LedgerText.isCorrection).count == 2)
        #expect(LedgerText.isCorrection("**۲۰۲۶-۱۰-۱۹:** چیزی"))
        #expect(LedgerText.isCorrection("- این بند اصلاح شد"))
        #expect(!LedgerText.isCorrection("- آماده‌شده (۲۰۲۶-۱۰-۰۷): سیم‌کشی"))
    }

    @Test func checkboxesInQuotesListsAndTablesAreSetAsideNotLost() {
        let ledger = LedgerParser.parse("""
        ## P1
        > - [ ] در نقل‌قول
        1. [ ] شماره‌دار با چک‌باکس
        | - [ ] در جدول | x |
        > [x] تیک در نقل‌قول
        - [ ] درست
        > متن نقل‌قول بی‌چک‌باکس
        | ستون | [PR](https://example.com) |
        """)
        #expect(ledger.items.map(\.line) == [6])
        #expect(ledger.skippedLines == [2, 3, 4, 5])
    }

    @Test func aSectionTheLedgerPutsFirstCountsAsP1() {
        let ledger = LedgerParser.parse("""
        # اولویت‌ها
        ## مشترک در همهٔ محصولات (اول این‌ها)
        - [ ] مشترک
        ## P0 — قبل از هر فروش
        - [ ] فوری
        ## یادداشت‌ها
        - [ ] دیگر
        """)
        #expect(ledger.items.map(\.priority) == [.p1, .p0, .other])
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

    @Test func windowsLineEndingsGiveTheSameReport() throws {
        let lf = try text("next-actions-sample")
        let a = NextActionsParser.parse(lf, fileName: "NEXT-ACTIONS-2026-10-12.md")
        let b = NextActionsParser.parse(crlf(lf), fileName: "NEXT-ACTIONS-2026-10-12.md")
        #expect(b.items.map(\.line) == [6, 11, 19, 21])
        #expect(b.items.map(\.sourceLine) == a.items.map(\.sourceLine))
        #expect(b.items.map(\.body) == a.items.map(\.body))
        #expect(b == a)
        #expect(NextActionsParser.parse(crlf(lf)).day == KeyDay("2026-10-12"))
    }

    @Test func aChangedFormatIsSetAsideNeverDroppedSilently() throws {
        let report = NextActionsParser.parse("""
        گزارش ۲۰۲۶-۱۰-۱۲
        ۱. امروز (TODAY)
        1) WorkTrack: اول
           منبع: WorkTrack / one
        2. merge the branch (PR)
        2) SafeBeauty: دوم، بعد از سطری که شبیه سرفصل است
           - منبع: SafeBeauty / two
        3) Talar: سوم
        **منبع:** Talar / three (یادداشت)
        4) VELRO: چهارم
           منبع : VELRO / four
        1. سبک دیگر شماره‌گذاری
        **5)** سبک پررنگ
        منبع: Keys / orphan
        ## THIS WEEK بدون پرانتز
        1) در بخش ناشناخته، خوانده نمی‌شود
           منبع: X / y
        ۲. این هفته (THIS WEEK)
        1) DukanPro: این هفته
           منبع: DukanPro / week
           منبع: DukanPro / second-source
        ۳. کارهای Claude (CLAUDE CAN DO NOW)
        1) Linumic OS: کار Claude
           منبع: Linumic OS / claude
        """)
        #expect(report.items.map(\.slug) == ["one", "two", "three", "four", "week"])
        try #require(report.items.count == 5)
        #expect(report.items.map(\.section) == [.today, .today, .today, .today, .thisWeek])
        #expect(report.items[2].sourceText == "Talar / three (یادداشت)")
        // "2. merge…", "1. …", "**5)** …", the «منبع» with no item, and the second «منبع» of one item.
        #expect(report.skippedLines == [5, 12, 13, 14, 21])
        #expect(report.sections == [.today, .thisWeek])
    }

    @Test func everyProductTheSourceLineNames() throws {
        let report = NextActionsParser.parse(try text("next-actions-sample"), fileName: "NEXT-ACTIONS-2026-10-12.md")
        try #require(report.items.count == 4)
        #expect(report.items[2].product == "Keys" && report.items[2].otherProducts == ["Talar"])
        #expect(report.items[0].otherProducts.isEmpty)
        let pairs = NextActionsParser.sourcePairs("Keys / khayatyar-signing-key و second-offline-copy؛ Talar / create-release-key (اصلاح‌شده)؛ NerkhTimes / nt-find-upload-key")
        #expect(pairs.map(\.product) == ["Keys", "Talar", "NerkhTimes"])
        // File paths in parentheses are not products.
        let paths = NextActionsParser.sourcePairs("Keys / github-recovery-and-vault (~/Keys/README.md:33؛ LinumicCommandCenter/PRIORITIES.md:45-47)")
        #expect(paths.map(\.product) == ["Keys"])
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

    @Test func aDeniedCheckIsUnreadableNotMissing() {
        var fs = FakeFS()
        fs.denied.insert("\(home)/Projects/Multiplatform/Talar/PRIORITIES.md")
        fs.denied.insert("\(home)/Projects/Multiplatform")
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)
        guard case .unreadable(let why) = reading.file("talar")?.status else { Issue.record("a denied check is not 'not found'"); return }
        #expect(why == "Operation not permitted")
        guard case .unreadable = reading.file("next-actions")?.status else { Issue.record("a denied listing is not 'not found'"); return }
        #expect(reading.file("velro")?.status == .notFound)
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

// MARK: - The real file system (a temporary folder)

@Suite("Ledgers: reading files on disk")
struct LocalLedgerFileSystemTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ledger-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsARegularFileInsideTheGrant() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "PRIORITIES.md")
        try Data("- [ ] یک\r\n".utf8).write(to: file)
        let fs = LocalLedgerFileSystem()
        #expect(try fs.info(atPath: file.path)?.isRegularFile == true)
        #expect(try fs.info(atPath: root.appending(path: "missing.md").path) == nil)
        #expect(try fs.readText(atPath: file.path, maxBytes: 1_000, roots: [root.path]) == "- [ ] یک\r\n")
        #expect(throws: LedgerReadError.tooLarge(4)) { try fs.readText(atPath: file.path, maxBytes: 4, roots: [root.path]) }
        try Data([0xFF, 0xFE, 0x00]).write(to: file)
        #expect(throws: LedgerReadError.notUTF8) { try fs.readText(atPath: file.path, maxBytes: 1_000, roots: [root.path]) }
    }

    @Test func aLinkAsTheFileIsRefused() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "elsewhere.md")
        try Data("secret".utf8).write(to: target)
        let link = root.appending(path: "PRIORITIES.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fs = LocalLedgerFileSystem()
        #expect(try fs.info(atPath: link.path)?.isSymbolicLink == true)
        #expect(throws: LedgerReadError.symbolicLink) { try fs.readText(atPath: link.path, maxBytes: 1_000, roots: [root.path]) }
    }

    @Test func aFolderOnTheWayThatLeadsOutOfTheGrantIsRefused() throws {
        // A home with ~/Projects/Multiplatform granted, where Velro is a link to ~/Keys (outside the grant), and Talar
        // a link to a folder inside it.
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let granted = home.appending(path: "Projects/Multiplatform")
        let outside = home.appending(path: "Keys")
        let inside = granted.appending(path: "TalarReal")
        for dir in [granted, outside, inside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("آخرین بازبینی: 2026-10-19\n- [ ] outside".utf8).write(to: outside.appending(path: "PRIORITIES.md"))
        try Data("آخرین بازبینی: 2026-10-19\n- [ ] inside".utf8).write(to: inside.appending(path: "PRIORITIES.md"))
        try FileManager.default.createSymbolicLink(at: granted.appending(path: "Velro"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: granted.appending(path: "Talar"), withDestinationURL: inside)
        let fs = LocalLedgerFileSystem()
        let velro = granted.appending(path: "Velro/PRIORITIES.md").path
        #expect(throws: LedgerReadError.outsideGrant) { try fs.readText(atPath: velro, maxBytes: 1_000, roots: [granted.path]) }

        let reading = LedgerReader.read(home: home.path, granted: [granted.path], fs: fs, now: now)
        guard case .unreadable(let why) = reading.file("velro")?.status else { Issue.record("a folder link out of the grant is refused"); return }
        #expect(why == LedgerReadError.outsideGrant.errorDescription)
        guard case .read(.priorities(let talar)) = reading.file("talar")?.status else { Issue.record("a link inside the grant is read"); return }
        #expect(talar.items.map(\.text) == ["inside"])
        #expect(reading.file("worktrack")?.status == .notFound)
    }
}
