import Foundation
import Testing
@testable import LinumicCore

// The Desk review findings of 2026-10-19 (Phase 1): lines that were dropped without a trace, a sub-heading that closed
// the owner's section, bold priority headings, Solar Hijri review dates, count lines whose marks hid a growing queue,
// two ids for one product, the agent brief's wording, and marks of ledgers that were not read. Invented inputs only.

private let now = LedgerFixtures.now
private let home = LedgerFixtures.home
private var utc: Calendar { LedgerFixtures.utc }
private let multiplatform = "\(home)/Projects/Multiplatform"

private func briefOf(_ sections: [BriefSection]) -> DailyBrief { DailyBrief(sections: sections, generatedAt: now) }

@Suite("Desk review: ledgers")
struct DeskReviewLedgerTests {
    @Test func directionMarksAndAWideBoxAreNeverDroppedSilently() {
        let ledger = LedgerParser.parse("""
        ## P1
        \u{200F}- [ ] بند با نشانهٔ راست‌به‌چپ
        \u{200E}- [ ] item with a left-to-right mark
          \u{2067}- [ ] زیربند با isolate
        - [  ] two spaces in the box
        > - [  ] quoted, two spaces
        """)
        // The marks are invisible, so those lines are the checkboxes they look like; the wide box is set aside.
        #expect(ledger.items.map(\.line) == [2, 3, 4])
        #expect(ledger.items.map(\.title) == ["بند با نشانهٔ راست‌به‌چپ", "item with a left-to-right mark", "زیربند با isolate"])
        #expect(ledger.items[2].indent == 2)
        #expect(ledger.skippedLines == [5, 6])
    }

    @Test func aBoldOrDecoratedPriorityHeadingStillDecides() {
        let ledger = LedgerParser.parse("""
        ## **P0** — فوری
        - [ ] فوری
        ## __P1__ — این ماه
        - [ ] این ماه
        ## \u{1F525} P0 دوباره
        - [ ] فوری با نشانه
        """)
        #expect(ledger.items.map(\.priority) == [.p0, .p1, .p0])
    }

    @Test func aSolarHijriReviewDateIsNotReadAsAGregorianOne() throws {
        let ledger = LedgerParser.parse("آخرین بازبینی: ۱۴۰۵-۰۷-۲۷\n## P1\n- [ ] کار")
        #expect(ledger.reviewLine == 1)
        #expect(ledger.reviewedOn == nil)
        var fs = FakeLedgerFS()
        fs.files["\(multiplatform)/Talar/PRIORITIES.md"] = "آخرین بازبینی: ۱۴۰۵-۰۷-۲۷\n## P1\n- [ ] کار"
        let reading = LedgerReader.read(home: home, granted: [multiplatform], fs: fs, now: now)
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: now, calendar: utc)
        // Not "reviewed 227,000 days ago": the date is unknown, and the item points at the line.
        #expect(!desk.open.contains { $0.item.kindKey == "review-stale" })
        let unknown = try #require(desk.open.first { $0.item.id == "ledger.talar|source|review-unknown" })
        #expect(unknown.item.evidence.line == 1)
        #expect(unknown.item.title.contains("could not be read"))
        #expect(LedgerText.firstDay(in: "۲۰۲۶-۱۰-۱۹") == KeyDay("2026-10-19"))
        #expect(LedgerText.firstDay(in: "1405-07-27") == nil)
    }

    @Test func aNumberedLineInTheFilesOwnTitleSectionIsNoTask() {
        let ledger = LedgerParser.parse("""
        # اولویت‌های نمونه
        1. یادداشت پیش از اولین بخش
        ## اولویت‌های بعدی
        1. کار شماره‌دار
        """)
        #expect(ledger.items.map(\.line) == [4])
    }

    @Test func aHardLinkIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ledger-hardlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere.md")
        try Data("- [ ] not a ledger".utf8).write(to: elsewhere)
        let link = root.appending(path: "PRIORITIES.md")
        try FileManager.default.linkItem(at: elsewhere, to: link)
        let fs = LocalLedgerFileSystem()
        #expect(try fs.info(atPath: link.path)?.links == 2)
        #expect(throws: LedgerReadError.hardLink) { try fs.readText(atPath: link.path, maxBytes: 1_000, roots: [root.path]) }
        // The reader refuses it before opening, from the file's own count of names.
        var fake = FakeLedgerFS()
        fake.files["\(multiplatform)/Talar/PRIORITIES.md"] = "- [ ] x"
        fake.linkCounts["\(multiplatform)/Talar/PRIORITIES.md"] = 2
        let reading = LedgerReader.read(home: home, granted: [multiplatform], fs: fake, now: now)
        #expect(reading.file("talar")?.status == .unreadable(LedgerReadError.hardLink.errorDescription!))
        #expect(LedgerReader.maxBytes == 256_000)
    }
}

@Suite("Desk review: NEXT-ACTIONS")
struct DeskReviewNextActionsTests {
    @Test func aSubHeadingInsideTheOwnersSectionDoesNotCloseIt() {
        let report = NextActionsParser.parse("""
        گزارش ۲۰۲۶-۱۰-۱۹
        ## امروز (TODAY)
        1) WorkTrack: اول
           منبع: WorkTrack / one
        ### جزئیات
        2) SafeBeauty: دوم، زیر سرفصل فرعی
           منبع: SafeBeauty / two
        ## این هفته (This Week)
        1) Talar: با برچسب حروف کوچک
           منبع: Talar / three
        """)
        #expect(report.items.map(\.slug) == ["one", "two", "three"])
        #expect(report.items.map(\.section) == [.today, .today, .thisWeek])
        #expect(report.skippedLines == [5])   // the sub-heading itself, set aside
        #expect(report.sections == [.today, .thisWeek])
    }

    @Test func aHeadingAtTheSectionsLevelEndsItAndWhatFollowsIsSetAside() {
        let report = NextActionsParser.parse("""
        ۱. امروز (TODAY)
        1) WorkTrack: اول
           منبع: WorkTrack / one
        ## یادداشت‌ها
        2) Talar: بعد از سرفصل ناشناخته
           منبع: Talar / two
        ۲. کارهای Claude (CLAUDE CAN DO NOW)
        1) Linumic OS: کار Claude
           منبع: Linumic OS / claude
        """)
        #expect(report.items.map(\.slug) == ["one"])
        #expect(report.skippedLines == [5, 6])
    }

    @Test func tagsAreReadWithoutRegardToCase() {
        #expect(NextActionsParser.heading("## Today (today)")?.section == .today)
        #expect(NextActionsParser.heading("2. merge the branch (PR)") == nil)
        #expect(NextActionsParser.heading("## Notes")?.known == false)
    }
}

@Suite("Desk review: items and marks")
struct DeskReviewItemTests {
    @Test func aMarkOnACountLineHoldsWithinItsBucketOnly() throws {
        func ops(_ count: Int) -> DailyBrief {
            let input = BriefInput(now: now, monitor: MonitorSnapshot(), monitorTargets: [], releases: ReleaseCenterSnapshot(),
                                   licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                                   worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                                   operations: [BriefOperationsInput(product: .talar, isSignedIn: true,
                                                                     counts: [OperationsCount(queue: .talarHalls, count: count, environment: "production", readAt: now)])],
                                   oversight: BriefOversightInput(repos: [], recentChanges: []))
            return briefOf([DailyBriefBuilder.operations(input)])
        }
        var state = DeskState()
        let three = try #require(DeskBuilder.build(brief: ops(3), ledgers: .unsupported, state: state, now: now, calendar: utc).open.first)
        state.markWaiting(three.item, now: now)
        #expect(DeskBuilder.build(brief: ops(2), ledgers: .unsupported, state: state, now: now, calendar: utc).open.isEmpty)
        #expect(DeskBuilder.build(brief: ops(3), ledgers: .unsupported, state: state, now: now, calendar: utc).open.isEmpty)
        // Four is a new fact: the queue grew past its bucket, so the line is back.
        #expect(DeskBuilder.build(brief: ops(4), ledgers: .unsupported, state: state, now: now, calendar: utc).open.count == 1)
        #expect(DeskBuilder.build(brief: ops(30), ledgers: .unsupported, state: state, now: now, calendar: utc).open.count == 1)
        #expect([0, 1, 2, 3, 4, 7, 8, 30].map(BriefLine.countBucket) == ["0", "1", "2-3", "2-3", "4-7", "4-7", "8-15", "16-31"])
    }

    @Test func aLineWithoutACountKeepsTheHashItAlwaysHad() {
        let line = BriefLine(id: "monitor.down.x", kind: .monitor, severity: .high, text: "x", source: "s", readAt: now,
                             destination: .monitor)
        #expect(DeskBuilder.factHash(line) == DeskHash.of("monitor.down.x", "0"))
    }

    @Test func twoSpellingsOfOneUnknownProductAreOneGroup() {
        func row(_ name: String, _ id: String) -> DeskRow {
            let item = DeskItem(origin: .nextActions, subjectKey: id, kindKey: "owner", kind: .task, domain: .named(name),
                                severity: .normal, title: id, subject: name, ownerAction: true,
                                evidence: DeskEvidence(source: "s", readAt: now), factHash: id, destination: .file(path: "~/x", line: 1))
            return DeskRow(item: item, bucket: .thisWeek, resolution: .open, isStale: false)
        }
        let groups = Desk.groups([row("Signing Keys", "a"), row("Signing-Keys", "b")])
        #expect(groups.count == 1)
        #expect(groups.first?.domain.name == "Signing Keys")
        #expect(groups.first?.rows.count == 2)
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func repositorySlugsWithoutTheProductsNameStillFindIt() {
        #expect(DeskDomain.named("aminullah-dev/stealth-service-vault-") == .safeBeauty)
        #expect(DeskDomain.named("aminullah-dev/talar-releases") == .talar)
    }

    @Test func theAgentBriefSaysCheckedForAnUnreadSourceAndNamesCorrectionsOnlyWhenThereAreSome() throws {
        let unread = DeskItem(origin: .ledger("talar"), subjectKey: "source", kindKey: "not-granted", kind: .source, domain: .talar,
                              severity: .high, title: "Ledger not granted", subject: "~/x", ownerAction: true,
                              evidence: DeskEvidence(source: "~/x", file: "~/x", readAt: now), factHash: "h", destination: .ledgerAccess)
        let text = DeskAgentBrief.text(for: unread, now: now)
        #expect(text.contains("زمان بررسی (خوانده نشد): "))
        #expect(!text.contains("زمان خواندن: "))

        let plain = DeskItem(origin: .ledger("talar"), subjectKey: "k", kindKey: "checkbox", kind: .task, domain: .talar,
                             severity: .normal, title: "کار", subject: "s", ownerAction: false,
                             evidence: DeskEvidence(source: "~/x", file: "~/x", line: 3, readAt: now), factHash: "h",
                             destination: .file(path: "~/x", line: 3), notes: ["- زیربند ساده"])
        let plainText = DeskAgentBrief.text(for: plain, now: now)
        #expect(!plainText.contains("اصلاح"))
        #expect(plainText.contains("سطرهای زیر همین مورد در دفتر، به همان ترتیب:"))
        #expect(plainText.contains("زمان خواندن: "))

        var corrected = plain
        corrected.notes = ["- ۲۰۲۶-۱۰-۱۹: این جمله درست نیست.", "- زیربند ساده"]
        let correctedText = DeskAgentBrief.text(for: corrected, now: now)
        #expect(correctedText.contains("اصلاح‌های تاریخ‌دار زیر همین مورد در دفتر"))
        #expect(correctedText.contains("سطرهای دیگر زیر همین مورد در دفتر"))
    }

    /// A ledger that was not read this time (not granted, unreadable, not found) keeps the marks on its lines; only a
    /// ledger that was read and no longer has the line drops them.
    @Test func aLedgerThatWasNotReadKeepsItsMarks() throws {
        var fs = FakeLedgerFS()
        fs.files["\(multiplatform)/WorkTrack/PRIORITIES.md"] = "آخرین بازبینی: 2026-10-10\n## P1\n- [ ] کار ورک‌ترک"
        let first = LedgerReader.read(home: home, granted: [multiplatform], fs: fs, now: now)
        let item = try #require(DeskBuilder.build(brief: nil, ledgers: .read(first), state: DeskState(), now: now, calendar: utc)
            .open.first { $0.item.title == "کار ورک‌ترک" }).item
        var state = DeskState()
        state.markWaiting(item, now: now)
        let worktrack = try #require(LedgerAllowList.priorities.first { $0.id == "worktrack" })
        for status in [LedgerFileStatus.notGranted, .unreadable("Operation not permitted"), .notFound] {
            let reading = LedgerReading(readAt: now.addingTimeInterval(3600),
                                        files: [LedgerFileReading(source: worktrack, path: worktrack.path, status: status)])
            let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: state, now: now.addingTimeInterval(3600), calendar: utc)
            #expect(desk.obsoleteMarks.isEmpty, "status \(status) must keep the mark")
        }
        // Read, and the line is gone: now the mark goes.
        fs.files["\(multiplatform)/WorkTrack/PRIORITIES.md"] = "آخرین بازبینی: 2026-10-10\n## P1\n- [ ] کار دیگر"
        let gone = LedgerReader.read(home: home, granted: [multiplatform], fs: fs, now: now.addingTimeInterval(3600))
        #expect(DeskBuilder.build(brief: nil, ledgers: .read(gone), state: state, now: now.addingTimeInterval(3600), calendar: utc)
            .obsoleteMarks == [item.id])
    }
}

@Suite("Desk review: Brief parts")
struct DeskReviewBriefTests {
    private func input(oversight: [OversightRepo] = [], licences: BriefLicenceInput) -> BriefInput {
        BriefInput(now: now, monitor: MonitorSnapshot(), monitorTargets: [], releases: ReleaseCenterSnapshot(),
                   licences: licences,
                   worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                   operations: [], oversight: BriefOversightInput(repos: oversight, recentChanges: []))
    }

    @Test func repositoriesNotScannedYetAreAGapNotAllClear() {
        let snap = RepositorySnapshot(slug: "o/a", defaultBranch: "main", fetchedAt: now)
        let section = DailyBriefBuilder.oversight(input(oversight: [OversightRepo(slug: "o/a", snapshot: snap, observedAt: now),
                                                                    OversightRepo(slug: "o/b", observedAt: now)],
                                                        licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil)))
        #expect(section.gaps.map(\.key) == ["neverScanned"])
        #expect(section.gaps.first?.text == "1 of 2 repositories not scanned yet.")
        let desk = DeskBuilder.build(brief: briefOf([section]), ledgers: .unsupported, state: DeskState(), now: now, calendar: utc)
        #expect(desk.open.contains { $0.item.id == "brief.oversight|part.neverScanned|not-read" })
    }

    @Test func anEmptyLedgerIsAGapOnlyWhenItWasNeverSynced() {
        let local = DailyBriefBuilder.licences(input(licences: BriefLicenceInput(isLoaded: true, records: [], lastSyncedAt: nil)))
        #expect(local.gaps.map(\.key) == ["empty"])
        let synced = DailyBriefBuilder.licences(input(licences: BriefLicenceInput(isLoaded: true, records: [], lastSyncedAt: now)))
        #expect(synced.gaps.isEmpty)
        #expect(synced.notes == ["The ledger is empty, also in the cloud."])
        #expect(synced.state == .allClear)
    }
}
