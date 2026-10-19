import Foundation
import Testing
@testable import LinumicCore

// The Desk: Brief lines and ledgers as items, buckets, order, the owner's marks and the agent brief. Invented inputs
// only; the one test that reads the owner's real ledgers is opt-in (LCC_LIVE_LEDGERS=1) and only reads.

private let now = LedgerFixtures.now
private let home = LedgerFixtures.home
private var utc: Calendar { LedgerFixtures.utc }
private func text(_ name: String) throws -> String { try LedgerFixtures.text(name) }
private typealias FakeFS = FakeLedgerFS

private func line(_ id: String, _ kind: BriefSourceKind = .monitor, _ severity: BriefSeverity = .high, text: String = "Line",
                  readAt: Date? = now, product: String? = nil, destination: BriefDestination = .monitor) -> BriefLine {
    BriefLine(id: id, kind: kind, severity: severity, text: text, source: "test source", readAt: readAt,
              destination: destination, product: product)
}

private func brief(_ sections: [BriefSection]) -> DailyBrief { DailyBrief(sections: sections, generatedAt: now) }

/// A Brief input with only Operations filled in.
private func opsInput(_ operations: [BriefOperationsInput], at: Date = now) -> BriefInput {
    BriefInput(now: at, monitor: MonitorSnapshot(), monitorTargets: [], releases: ReleaseCenterSnapshot(),
               licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
               worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
               operations: operations, oversight: BriefOversightInput(repos: [], recentChanges: []))
}

private func item(_ id: String = "x", kind: DeskItemKind = .task, domain: DeskDomain = .talar, severity: BriefSeverity = .info,
                  due: KeyDay? = nil, horizon: DeskHorizon? = nil, owner: Bool = false, readAt: Date? = now,
                  hash: String = "h1") -> DeskItem {
    DeskItem(origin: .ledger("talar"), subjectKey: id, kindKey: "checkbox", kind: kind, domain: domain, severity: severity,
             title: "Item \(id)", subject: "s", due: due, horizon: horizon, ownerAction: owner,
             evidence: DeskEvidence(source: "~/x.md", file: "~/x.md", line: 3, readAt: readAt, cadence: 30 * 60),
             factHash: hash, destination: .file(path: "~/x.md", line: 3))
}

// MARK: - Building the Desk

@Suite("Desk: building")
struct DeskBuilderTests {
    @Test func aCorrectionUnderALedgerLineReachesTheRowAndTheAgentBrief() throws {
        var fs = FakeFS()
        fs.files["\(home)/Projects/Multiplatform/Talar/PRIORITIES.md"] = """
        آخرین بازبینی: ۲۰۲۶-۱۰-۱۰
        ## P0 — فوری
        - [ ] **انتشار اندروید.** نسخهٔ release هیچ‌وقت ساخته نشده (versionCode 1).
          - ۲۰۲۶-۱۰-۱۹: این جمله درست نیست. یک APK امضاشدهٔ release عمومی است.
          - keystore ساخته شود.
        """
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: now, calendar: utc)
        let row = try #require(desk.open.first { $0.item.title == "انتشار اندروید" })
        #expect(row.item.notes == ["- ۲۰۲۶-۱۰-۱۹: این جمله درست نیست. یک APK امضاشدهٔ release عمومی است.", "- keystore ساخته شود."])
        #expect(row.item.corrections == ["- ۲۰۲۶-۱۰-۱۹: این جمله درست نیست. یک APK امضاشدهٔ release عمومی است."])
        let text = DeskAgentBrief.text(for: row.item, now: now)
        #expect(text.contains("جزئیات: نسخهٔ release هیچ‌وقت ساخته نشده (versionCode 1)."))
        #expect(text.contains("  - ۲۰۲۶-۱۰-۱۹: این جمله درست نیست."))
        // A note added later changes the fact (a Waiting mark comes back) but not the id (marks still find it).
        var state = DeskState()
        state.markWaiting(row.item, now: now)
        fs.files["\(home)/Projects/Multiplatform/Talar/PRIORITIES.md"]! += "\n  - ۲۰۲۶-۱۰-۲۰: کلید پیدا شد."
        let again = DeskBuilder.build(brief: nil, ledgers: .read(LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)),
                                      state: state, now: now, calendar: utc)
        let back = try #require(again.open.first { $0.item.title == "انتشار اندروید" })
        #expect(back.item.id == row.item.id && back.item.factHash != row.item.factHash)
    }

    @Test func theReportShowsItsOwnCountsAndEveryProductItNames() throws {
        var fs = FakeFS()
        fs.files["\(home)/Projects/Multiplatform/NEXT-ACTIONS-2026-10-12.md"] = try text("next-actions-sample")
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: now, calendar: utc)
        #expect(desk.sources.first { $0.id == "next-actions" }?.state == .report(today: 2, thisWeek: 2, skipped: [14], day: KeyDay("2026-10-12")))
        #expect(desk.sources.first { $0.id == "next-actions" }?.isRead == true)
        let keys = try #require(desk.open.first { $0.item.subjectKey == "keys/sample-week-one" })
        #expect(keys.item.related == [.talar])
        #expect(keys.item.reference == "Keys / sample-week-one و other-slug؛ Talar / sample-week-other")
        #expect(DeskAgentBrief.text(for: keys.item, now: now).contains("منبع در گزارش: Keys / sample-week-one و other-slug؛ Talar / sample-week-other"))
        // An owner item that could not be read is this week's business, not Later's.
        let skipped = try #require(desk.open.first { $0.item.id == "next-actions|source|skipped" })
        #expect(skipped.item.severity == .normal && skipped.bucket == .thisWeek)
    }

    @Test func briefLinesBecomeItemsThatOpenTheirScreen() {
        let b = brief([
            BriefSection(kind: .monitor, state: .items, lines: [line("monitor.down.x", product: "VELRO")], readAt: now, source: "m"),
            BriefSection(kind: .worktrack, state: .neverRead("Not signed in"), readAt: nil, source: "wt"),
            BriefSection(kind: .licences, state: .items, lines: [line("licence.expiring.L1", .licences, .normal, product: "MediFlow",
                                                                       destination: .licence("L1"))], readAt: now, source: "l"),
            BriefSection(kind: .changes, state: .items, lines: [line("changes.a", .changes, .info)], readAt: now, source: "c"),
        ])
        let desk = DeskBuilder.build(brief: b, ledgers: .unsupported, state: DeskState(), now: now, calendar: utc)
        let all = desk.open
        #expect(all.count == 3)   // the "changes" line repeats the others and is left out
        let down = all.first { $0.item.subjectKey == "monitor.down.x" }
        #expect(down?.item.id == "brief.monitor|monitor.down.x|fact")
        #expect(down?.item.domain == .velro)
        #expect(down?.bucket == .today)
        #expect(down?.item.destination == .screen(.monitor))
        let licence = all.first { $0.item.subjectKey == "licence.expiring.L1" }
        #expect(licence?.item.destination == .screen(.licence("L1")))
        #expect(licence?.item.domain == .mediflow)
        #expect(licence?.bucket == .thisWeek)
        // A source that was never read is an item, not a zero.
        let unread = all.first { $0.item.kind == .source }
        #expect(unread?.item.id == "brief.worktrack|section|not-read")
        #expect(unread?.item.domain == .worktrack)
        #expect(unread?.item.destination == .screen(.worktrackCustomers))
        #expect(unread?.item.severity == .normal)   // a focus product's source: this week, not Later
        #expect(unread?.item.wasRead == false)
    }

    @Test func aPartThatWasNotReadIsAnItemEvenWhenTheSectionIsAllClear() throws {
        // Talar signed in and read (nothing waiting); SafeBeauty, a focus product, not signed in; VELRO's read failed.
        let input = opsInput([BriefOperationsInput(product: .talar, isSignedIn: true,
                                                   counts: [OperationsCount(queue: .talarHalls, count: 0, environment: "production", readAt: now)]),
                              BriefOperationsInput(product: .safeBeauty, isSignedIn: false, counts: []),
                              BriefOperationsInput(product: .velro, isSignedIn: true, counts: [], loadError: "offline")])
        let section = DailyBriefBuilder.operations(input)
        #expect(section.state == .allClear)
        #expect(section.gaps.map(\.key) == ["safeBeauty", "velro"])
        #expect(section.notes.count == 2)
        let desk = DeskBuilder.build(brief: brief([section]), ledgers: .unsupported, state: DeskState(), now: now, calendar: utc)
        let parts = desk.open.filter { $0.item.subjectKey.hasPrefix("part.") }
        #expect(parts.map(\.item.id) == ["brief.operations|part.safeBeauty|not-read", "brief.operations|part.velro|not-read"])
        try #require(parts.count == 2)
        let sb = parts[0]
        #expect(sb.item.kind == .source && sb.item.domain == .safeBeauty && sb.item.severity == .normal)
        #expect(sb.bucket == .thisWeek)
        #expect(sb.item.title.contains("SafeBeauty: not signed in, queues unknown."))
        #expect(parts[1].item.severity == .info && parts[1].item.domain == .velro)
        #expect(parts[1].item.title.contains("could not be read (offline)"))
        #expect(sb.item.wasRead == false)
        // Nothing "today", but the badge must not read as all clear: the parts are open source items.
        #expect(desk.today.isEmpty && desk.open.contains { $0.item.kind == .source })
    }

    @Test func bucketRules() {
        let today = KeyDay("2026-10-11")!
        #expect(DeskBuilder.bucket(item(severity: .high), today: today) == .today)
        #expect(DeskBuilder.bucket(item(due: KeyDay("2026-10-11")), today: today) == .today)
        #expect(DeskBuilder.bucket(item(due: KeyDay("2026-10-01")), today: today) == .today)   // overdue
        #expect(DeskBuilder.bucket(item(horizon: .today), today: today) == .today)
        #expect(DeskBuilder.bucket(item(domain: .worktrack, owner: true), today: today) == .today)   // owner's work, focus
        #expect(DeskBuilder.bucket(item(domain: .talar, owner: true), today: today) == .later)
        #expect(DeskBuilder.bucket(item(due: KeyDay("2026-10-17")), today: today) == .thisWeek)
        #expect(DeskBuilder.bucket(item(due: KeyDay("2026-10-30")), today: today) == .later)
        #expect(DeskBuilder.bucket(item(horizon: .thisWeek), today: today) == .thisWeek)
        #expect(DeskBuilder.bucket(item(severity: .normal), today: today) == .thisWeek)
        #expect(DeskBuilder.bucket(item(), today: today) == .later)
    }

    @Test func ledgersBecomeItemsWithFileAndLineInFocusOrder() throws {
        var fs = FakeFS()
        fs.files["\(home)/Projects/Multiplatform/Talar/PRIORITIES.md"] = "آخرین بازبینی: ۲۰۲۶-۱۰-۱۰\n## P1\n- [ ] تالار"
        fs.files["\(home)/Projects/Multiplatform/WorkTrack/PRIORITIES.md"] = "آخرین بازبینی: ۲۰۲۶-۱۰-۱۰\n## P1\n- [ ] ورک‌ترک"
        fs.files["\(home)/Projects/Multiplatform/NEXT-ACTIONS-2026-10-12.md"] = try text("next-actions-sample")
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform", "\(home)/Games/BE-PAYA"], fs: fs, now: now)
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: now, calendar: utc)
        let talar = try #require(desk.open.first { $0.item.title == "تالار" })
        #expect(talar.item.evidence.location == "~/Projects/Multiplatform/Talar/PRIORITIES.md:3")
        #expect(talar.item.destination == .file(path: "~/Projects/Multiplatform/Talar/PRIORITIES.md", line: 3))
        #expect(talar.bucket == .thisWeek)
        let groups = Desk.groups(desk.thisWeek).map(\.domain)
        #expect(groups.first == .worktrack)
        #expect(groups.firstIndex(of: .talar)! < groups.firstIndex(of: .shared) ?? Int.max)
        // NEXT-ACTIONS: TODAY items are due on the report's day; the owner's THIS WEEK work in a focus product is today.
        let sample = desk.open.filter { $0.item.origin == .nextActions && $0.item.kind == .task }
        #expect(sample.count == 4)
        #expect(sample.first { $0.item.subjectKey == "worktrack/sample-today-one" }?.item.due == KeyDay("2026-10-12"))
        #expect(sample.first { $0.item.subjectKey == "worktrack/sample-today-one" }?.bucket == .today)
        #expect(sample.first { $0.item.subjectKey == "velro/sample-week-two" }?.bucket == .thisWeek)
        #expect(sample.first { $0.item.subjectKey == "keys/sample-week-one" }?.item.domain.name == "Keys")
    }

    @Test func aMissingFileIsAnItemNeverZeroOpen() {
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: FakeFS(), now: now)
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: now, calendar: utc)
        let notFound = desk.open.filter { $0.item.kindKey == "not-found" }
        #expect(notFound.count == 8)   // seven PRIORITIES.md in the folder and the NEXT-ACTIONS report
        let notGranted = desk.open.filter { $0.item.kindKey == "not-granted" }
        #expect(notGranted.map(\.item.id) == ["ledger.bepaya|source|not-granted"])
        #expect(notGranted.first?.bucket == .today)
        #expect(notGranted.first?.item.destination == .ledgerAccess)
        #expect(desk.sources.first { $0.id == "talar" }?.state == .notFound)
        let kinds = desk.open.map(\.item.kind)
        #expect(!kinds.contains(.task) && !kinds.contains(.fact))
    }

    @Test func unreadAndUnsupportedLedgers() {
        let notRead = DeskBuilder.build(brief: nil, ledgers: .notRead, state: DeskState(), now: now, calendar: utc)
        let kinds = notRead.open.map(\.item.kindKey)
        #expect(kinds.count == 9 && Set(kinds) == ["not-read"])
        let iPhone = DeskBuilder.build(brief: nil, ledgers: .unsupported, state: DeskState(), now: now, calendar: utc)
        #expect(iPhone.open.isEmpty)
        let states = iPhone.sources.map(\.state)
        #expect(states.allSatisfy { $0 == .unsupported })
    }

    @Test func anOldReviewDateAndSetAsideLinesAreItems() throws {
        var fs = FakeFS()
        fs.files["\(home)/Projects/Multiplatform/WorkTrack/PRIORITIES.md"] = try text("ledger-priorities-sample")   // reviewed 2026-10-02
        fs.files["\(home)/Projects/Multiplatform/Talar/PRIORITIES.md"] = "## P1\n- [ ] بی‌تاریخ"
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)
        let later = Date(timeIntervalSince1970: 1_791_720_000 + 2 * 86_400)   // 2026-10-13: 11 days after the review
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: later, calendar: utc)
        let stale = try #require(desk.open.first { $0.item.id == "ledger.worktrack|source|review-stale" })
        #expect(stale.item.evidence.line == 5)
        #expect(stale.item.title.contains("11"))
        #expect(desk.open.contains { $0.item.id == "ledger.talar|source|review-unknown" })
        let skipped = try #require(desk.open.first { $0.item.id == "ledger.worktrack|source|skipped" })
        #expect(skipped.item.detail?.contains("26, 27, 28, 41") == true)
        // Eleven days later the same fact keeps its hash: a "waiting" mark is not undone by the passing days.
        let next = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: later.addingTimeInterval(86_400), calendar: utc)
        #expect(next.open.first { $0.item.id == stale.item.id }?.item.factHash == stale.item.factHash)
    }

    @Test func staleAfterTwiceTheUsualReadingInterval() {
        let fresh = DeskEvidence(source: "s", readAt: now.addingTimeInterval(-50 * 60), cadence: 30 * 60)
        let old = DeskEvidence(source: "s", readAt: now.addingTimeInterval(-61 * 60), cadence: 30 * 60)
        #expect(!fresh.isStale(now: now))
        #expect(old.isStale(now: now))
        #expect(!DeskEvidence(source: "s", readAt: nil, cadence: 60).isStale(now: now))
    }
}

// MARK: - The owner's marks

@Suite("Desk: marks")
struct DeskStateTests {
    private func briefWith(_ l: BriefLine, readAt: Date) -> DailyBrief {
        brief([BriefSection(kind: l.kind, state: .items, lines: [l], readAt: readAt, source: "m")])
    }

    @Test func doneOnABriefLineLastsUntilTheNextReading() {
        var state = DeskState()
        let first = DeskBuilder.build(brief: briefWith(line("monitor.down.x", readAt: now), readAt: now), ledgers: .unsupported,
                                      state: state, now: now, calendar: utc)
        state.markDone(first.today[0].item, now: now.addingTimeInterval(60))
        let same = DeskBuilder.build(brief: briefWith(line("monitor.down.x", readAt: now), readAt: now), ledgers: .unsupported,
                                     state: state, now: now.addingTimeInterval(120), calendar: utc)
        #expect(same.open.isEmpty && same.hidden.count == 1)
        // Read again five minutes later and still down: back, saying so.
        let later = now.addingTimeInterval(300)
        let again = DeskBuilder.build(brief: briefWith(line("monitor.down.x", readAt: later), readAt: later), ledgers: .unsupported,
                                      state: state, now: later, calendar: utc)
        #expect(again.today.count == 1)
        #expect(again.today[0].stillOpenNote == "Still open according to test source")
    }

    @Test func waitingOnOthersHidesUntilTheFactChanges() {
        var state = DeskState()
        let a = item("a", hash: "v1")
        state.markWaiting(a, now: now)
        #expect(state.resolve(a, now: now.addingTimeInterval(30 * 86_400)) == .hidden(state.marks[a.id]!))
        #expect(state.resolve(item("a", hash: "v2"), now: now) == .open)
    }

    @Test func doneOnALedgerLineWaitsForTheLedgerToBeTicked() {
        var state = DeskState()
        let line = item("t", kind: .task, readAt: now)
        state.markDone(line, now: now)
        // Read again later, same text: still "you marked it, the ledger isn't ticked yet", not hidden, not reopened.
        var reread = line
        reread.evidence.readAt = now.addingTimeInterval(3600)
        guard case .markedNotTicked = state.resolve(reread, now: now.addingTimeInterval(3600)) else {
            Issue.record("expected markedNotTicked")
            return
        }
        // The line's text changed: the mark no longer applies.
        #expect(state.resolve(item("t", kind: .task, hash: "edited"), now: now) == .open)
    }

    @Test func snoozeHidesUntilItsTimeAndThenIsObsolete() {
        var state = DeskState()
        let l = line("monitor.slow.x", .monitor, .normal)
        let b = briefWith(l, readAt: now)
        let first = DeskBuilder.build(brief: b, ledgers: .unsupported, state: state, now: now, calendar: utc)
        state.snooze(first.open[0].item, until: now.addingTimeInterval(86_400), now: now)
        let during = DeskBuilder.build(brief: b, ledgers: .unsupported, state: state, now: now.addingTimeInterval(3600), calendar: utc)
        #expect(during.open.isEmpty && during.hidden.count == 1)
        let after = DeskBuilder.build(brief: b, ledgers: .unsupported, state: state, now: now.addingTimeInterval(86_401), calendar: utc)
        #expect(after.open.count == 1)
        #expect(after.obsoleteMarks == [first.open[0].item.id])
    }

    @Test func dismissNeedsAReason() {
        var state = DeskState()
        let blank = state.dismiss(item("d"), reason: "  ", now: now)
        #expect(!blank)
        #expect(state.marks.isEmpty)
        let given = state.dismiss(item("d"), reason: "Not ours", now: now)
        #expect(given)
        #expect(state.marks[item("d").id]?.reason == "Not ours")
    }

    @Test func marksOfItemsGoneFromAReadSourceAreObsoleteOthersStay() {
        var state = DeskState()
        state.markWaiting(item("gone"), now: now)   // ledger.talar|gone|checkbox
        state.markDone(DeskItem(origin: .brief(.monitor), subjectKey: "monitor.down.y", kindKey: "fact", kind: .fact,
                                domain: .velro, severity: .high, title: "y", subject: "y", ownerAction: true,
                                evidence: DeskEvidence(source: "s", readAt: now), factHash: "h", destination: .screen(.monitor)), now: now)
        // Talar's ledger was read and no longer has the line; the Monitor section was not read this time.
        var fs = FakeFS()
        fs.files["\(home)/Projects/Multiplatform/Talar/PRIORITIES.md"] = "آخرین بازبینی: 2026-10-10"
        let reading = LedgerReader.read(home: home, granted: ["\(home)/Projects/Multiplatform"], fs: fs, now: now)
        let b = brief([BriefSection(kind: .monitor, state: .neverRead("not yet"), readAt: nil, source: "m")])
        let desk = DeskBuilder.build(brief: b, ledgers: .read(reading), state: state, now: now, calendar: utc)
        #expect(desk.obsoleteMarks == ["ledger.talar|gone|checkbox"])
    }

    @Test func doneAndSnoozeSurviveARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "desk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeskStateStore(fileURL: dir.appending(path: "desk-state.json"))
        guard case .empty = store.load() else { Issue.record("no file yet"); return }
        // A real clock has fractions of a second; the file keeps whole seconds.
        let at = now.addingTimeInterval(0.75)
        var state = DeskState()
        state.markDone(item("a", kind: .task), now: at)
        state.snooze(item("b"), until: at.addingTimeInterval(86_400), now: at)
        #expect(state.marks[item("a").id]?.at == now.addingTimeInterval(1))   // rounded up, never down
        try store.save(state)
        guard case .loaded(let back) = store.load() else { Issue.record("saved state reads back"); return }
        #expect(back == state)
        #expect(back.marks[item("b").id]?.until == now.addingTimeInterval(86_401))
        try Data("{ not json".utf8).write(to: store.fileURL)
        guard case .unreadable = store.load() else { Issue.record("a damaged file is reported, not replaced"); return }
    }

    @Test func theAgentBriefIsDariWithFileAndLine() {
        let text = DeskAgentBrief.text(for: item("z"), now: now)
        #expect(text.contains("اول PRIORITIES.md را بخوان: ~/Projects/Multiplatform/Talar/PRIORITIES.md"))
        #expect(text.contains("منبع: ~/x.md:3"))
        #expect(text.contains("کار: Item z"))
        #expect(text.contains("محصول: Talar"))
        #expect(DeskAgentBrief.text(for: item("s", domain: .shared), now: now).contains("محصول: همهٔ محصولات"))
    }

    // MARK: Offline readings never delete marks

    private func opsSection(talar: BriefOperationsInput, safeBeauty: BriefOperationsInput, at: Date) -> BriefSection {
        DailyBriefBuilder.operations(opsInput([talar, safeBeauty, BriefOperationsInput(product: .velro, isSignedIn: false, counts: [])], at: at))
    }

    @Test func aFailedReadingKeepsTheMarksOnLinesItCouldNotSee() throws {
        let halls = OperationsCount(queue: .talarHalls, count: 3, environment: "production", readAt: now)
        let kyc = OperationsCount(queue: .safeBeautyKYC, count: 2, environment: "production", readAt: now)
        let first = opsSection(talar: BriefOperationsInput(product: .talar, isSignedIn: true, counts: [halls]),
                               safeBeauty: BriefOperationsInput(product: .safeBeauty, isSignedIn: true, counts: [kyc]), at: now)
        var state = DeskState()
        let built = DeskBuilder.build(brief: brief([first]), ledgers: .unsupported, state: state, now: now, calendar: utc)
        let hallsItem = try #require(built.open.first { $0.item.subjectKey == "ops.talarHalls" }).item
        let kycItem = try #require(built.open.first { $0.item.subjectKey == "ops.safeBeautyKYC" }).item
        state.markWaiting(hallsItem, now: now.addingTimeInterval(10))
        state.dismiss(kycItem, reason: "Handled by phone", now: now.addingTimeInterval(10))

        // Next launch, offline: Talar signed in but its read failed, SafeBeauty not read yet. All clear, no read time.
        let later = now.addingTimeInterval(3600)
        let offline = opsSection(talar: BriefOperationsInput(product: .talar, isSignedIn: true, counts: [], loadError: "offline"),
                                 safeBeauty: BriefOperationsInput(product: .safeBeauty, isSignedIn: true, counts: []), at: later)
        #expect(offline.state == .allClear && offline.readAt == nil)
        let a = DeskBuilder.build(brief: brief([offline]), ledgers: .unsupported, state: state, now: later, calendar: utc)
        #expect(a.obsoleteMarks.isEmpty)

        // SafeBeauty read again (its queue is empty now), Talar still failing: only the SafeBeauty mark goes.
        let partly = opsSection(talar: BriefOperationsInput(product: .talar, isSignedIn: true, counts: [], loadError: "offline"),
                                safeBeauty: BriefOperationsInput(product: .safeBeauty, isSignedIn: true,
                                                                 counts: [OperationsCount(queue: .safeBeautyKYC, count: 0, environment: "production", readAt: later)]),
                                at: later)
        let b = DeskBuilder.build(brief: brief([partly]), ledgers: .unsupported, state: state, now: later, calendar: utc)
        #expect(b.obsoleteMarks == [kycItem.id])

        // A reading made before the mark can't say the line is gone.
        let early = opsSection(talar: BriefOperationsInput(product: .talar, isSignedIn: true,
                                                           counts: [OperationsCount(queue: .talarHalls, count: 0, environment: "production", readAt: now)]),
                               safeBeauty: BriefOperationsInput(product: .safeBeauty, isSignedIn: true, counts: [kyc]), at: now)
        #expect(DeskBuilder.build(brief: brief([early]), ledgers: .unsupported, state: state, now: later, calendar: utc).obsoleteMarks.isEmpty)

        // Talar read again after the mark: its queue is empty, so the Waiting mark goes, and when the queue fills again
        // the line is new.
        let fresh = opsSection(talar: BriefOperationsInput(product: .talar, isSignedIn: true,
                                                           counts: [OperationsCount(queue: .talarHalls, count: 0, environment: "production", readAt: later)]),
                               safeBeauty: BriefOperationsInput(product: .safeBeauty, isSignedIn: true, counts: [kyc]), at: later)
        #expect(DeskBuilder.build(brief: brief([fresh]), ledgers: .unsupported, state: state, now: later, calendar: utc).obsoleteMarks == [hallsItem.id])
    }

    @Test func aMarkOnAPartNotReadGoesWhenThePartIsRead() throws {
        var state = DeskState()
        let gap = BriefSection(kind: .releases, state: .allClear, readAt: now, source: "r",
                               gaps: [BriefGap(key: "play", text: "Google Play not read yet.")])
        let first = DeskBuilder.build(brief: brief([gap]), ledgers: .unsupported, state: state, now: now, calendar: utc)
        let part = try #require(first.open.first { $0.item.subjectKey == "part.play" })
        state.markWaiting(part.item, now: now)
        let read = BriefSection(kind: .releases, state: .allClear, readAt: now.addingTimeInterval(60), source: "r")
        #expect(DeskBuilder.build(brief: brief([read]), ledgers: .unsupported, state: state, now: now, calendar: utc).obsoleteMarks == [part.item.id])
        let unread = BriefSection(kind: .releases, state: .neverRead("no key"), readAt: nil, source: "r")
        #expect(DeskBuilder.build(brief: brief([unread]), ledgers: .unsupported, state: state, now: now, calendar: utc).obsoleteMarks.isEmpty)
    }

    // MARK: No customer data on disk or on the clipboard

    @Test func marksKeepNoTitleSoNoCustomerNameReachesTheDisk() throws {
        let msg = BriefLine(id: "site.42", kind: .siteMessages, severity: .normal,
                            text: "Message from Jane Customer <jane.customer@example.com>, 19 Oct 2026",
                            detail: "Please call me at 0700 000 000 about the demo", source: "Website messages, entry 42",
                            readAt: now, destination: .siteMessages, product: "linumic.com")
        let b = brief([BriefSection(kind: .siteMessages, state: .items, lines: [msg], readAt: now, source: "w")])
        let row = try #require(DeskBuilder.build(brief: b, ledgers: .unsupported, state: DeskState(), now: now, calendar: utc).open.first)
        var state = DeskState()
        state.markDone(row.item, now: now)
        state.markWaiting(item("w"), now: now)
        state.dismiss(item("d"), reason: "Not ours", now: now)
        let dir = FileManager.default.temporaryDirectory.appending(path: "desk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeskStateStore(fileURL: dir.appending(path: "desk-state.json"))
        try store.save(state)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("brief.siteMessages|site.42|fact"))
        for leak in ["Jane", "jane.customer", "example.com", "0700", "Item w", "\"title\""] { #expect(!json.contains(leak)) }

        // The agent brief for it names the entry, not the customer.
        let text = DeskAgentBrief.text(for: row.item, now: now)
        #expect(text.contains("site.42"))
        for leak in ["Jane", "jane.customer", "0700"] { #expect(!text.contains(leak)) }

        // A file written before titles were dropped still reads.
        try Data(#"{"version":1,"marks":{"x|y|z":{"kind":"done","at":"2026-10-11T12:00:00Z","factHash":"h","title":"Old"}}}"#.utf8)
            .write(to: store.fileURL)
        guard case .loaded(let old) = store.load() else { Issue.record("an older file still loads"); return }
        #expect(old.marks["x|y|z"]?.kind == .done)
    }

    @Test func doneOnAFactWithNoReadTimeIsHiddenUntilItChanges() throws {
        var state = DeskState()
        let l = line("licence.expired.L1", .licences, .high, readAt: nil, product: "MediFlow", destination: .licence("L1"))
        let b = brief([BriefSection(kind: .licences, state: .items, lines: [l], readAt: nil, source: "local")])
        let first = DeskBuilder.build(brief: b, ledgers: .unsupported, state: state, now: now, calendar: utc)
        state.markDone(try #require(first.today.first).item, now: now)
        let later = DeskBuilder.build(brief: b, ledgers: .unsupported, state: state, now: now.addingTimeInterval(86_400), calendar: utc)
        #expect(later.hidden.count == 1 && later.obsoleteMarks.isEmpty)
        #expect(later.hidden.first?.item.evidence.readAt == nil)
    }
}

// MARK: - The owner's real ledgers (opt-in, read-only)

@Suite("Ledgers: live (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["LCC_LIVE_LEDGERS"] == "1"))
struct LiveLedgerTests {
    /// Reads the real files on this Mac (never writes) and prints what each yields:
    /// `LCC_LIVE_LEDGERS=1 swift test --package-path Packages/LinumicCore --filter LiveLedgerTests`
    @Test func readTheRealLedgers() {
        let home = NSHomeDirectory()
        let reading = LedgerReader.read(home: home, granted: LedgerAllowList.folders.map { "\(home)/\($0)" },
                                        fs: LocalLedgerFileSystem(), now: .now)
        var checkboxes = 0, numbered = 0, owner = 0
        for file in reading.files {
            switch file.status {
            case .read(.priorities(let p)):
                let c = p.items.count { $0.kind == .checkbox }, n = p.items.count { $0.kind == .numbered }
                checkboxes += c
                numbered += n
                print("LIVE \(file.displayPath): \(c) open checkboxes, \(n) numbered, \(p.ticked) ticked, reviewed \(p.reviewedOn?.description ?? "unknown"), skipped \(p.skippedLines)")
                let severities = Dictionary(grouping: p.items, by: \.priority).mapValues(\.count)
                print("LIVE   P0 \(severities[.p0] ?? 0), P1 \(severities[.p1] ?? 0), other \(severities[.other] ?? 0); with notes \(p.items.count { !$0.notes.isEmpty }), with corrections \(p.items.count { !$0.notes.filter(LedgerText.isCorrection).isEmpty }), empty detail and notes only \(p.items.count { $0.detail == nil && !$0.notes.isEmpty })")
                for i in p.items where !i.notes.filter(LedgerText.isCorrection).isEmpty {
                    print("LIVE   correction under line \(i.line) (\(i.priority.rawValue)): \(i.title.prefix(40)) — \(i.notes.filter(LedgerText.isCorrection).count)")
                }
            case .read(.nextActions(let r)):
                owner = r.items.count
                let today = r.items.count { $0.section == .today }
                print("LIVE \(file.displayPath): \(today) TODAY + \(r.items.count - today) THIS WEEK, skipped \(r.skippedLines)")
                for i in r.items { print("LIVE   \(i.section.rawValue) line \(i.line): \(i.product) / \(i.slug)\(i.otherProducts.isEmpty ? "" : " + " + i.otherProducts.joined(separator: ", "))") }
            default:
                print("LIVE \(file.displayPath): \(file.status)")
            }
        }
        let desk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: DeskState(), now: .now)
        print("LIVE totals: \(checkboxes) open checkboxes, \(numbered) numbered, \(owner) NEXT-ACTIONS owner items")
        print("LIVE desk: today \(desk.today.count), this week \(desk.thisWeek.count), later \(desk.later.count)")
        let unread = reading.files.filter { !$0.isRead }.map(\.displayPath)
        #expect(unread.isEmpty)
    }
}
