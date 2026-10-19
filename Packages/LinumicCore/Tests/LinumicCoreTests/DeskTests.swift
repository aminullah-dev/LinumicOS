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
        var state = DeskState()
        state.markDone(item("a", kind: .task), now: now)
        state.snooze(item("b"), until: now.addingTimeInterval(86_400), now: now)
        try store.save(state)
        guard case .loaded(let back) = store.load() else { Issue.record("saved state reads back"); return }
        #expect(back == state)
        #expect(back.marks[item("b").id]?.until == now.addingTimeInterval(86_400))
        try Data("{ not json".utf8).write(to: store.fileURL)
        guard case .unreadable = store.load() else { Issue.record("a damaged file is reported, not replaced"); return }
    }

    @Test func theAgentBriefIsDariWithFileAndLine() {
        let text = DeskAgentBrief.text(for: item("z"), now: now)
        #expect(text.contains("اول PRIORITIES.md را بخوان: ~/Projects/Multiplatform/Talar/PRIORITIES.md"))
        #expect(text.contains("منبع: ~/x.md:3"))
        #expect(text.contains("کار: Item z"))
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
            case .read(.nextActions(let r)):
                owner = r.items.count
                let today = r.items.count { $0.section == .today }
                print("LIVE \(file.displayPath): \(today) TODAY + \(r.items.count - today) THIS WEEK, skipped \(r.skippedLines)")
                for i in r.items { print("LIVE   \(i.section.rawValue) line \(i.line): \(i.product) / \(i.slug)") }
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
