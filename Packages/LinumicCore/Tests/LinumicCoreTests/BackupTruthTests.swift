import Foundation
import Testing
@testable import LinumicCore

// The incident of 2026-10-19: the run log said "Copy saved and read back: 12 products" (00:00:01Z) while Backups/ was
// empty; the folder's change time (20:01:06 EDT, 65 s after the run) shows the file was removed after the run. A
// backup is what Backups/ holds, read back; the log alone never stands for one.

private let t0 = Date(timeIntervalSince1970: 1_792_281_600) // 2026-10-18T00:00:00Z

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func run(_ outcome: AutomationOutcome, at: Date) -> AutomationRun {
    AutomationRun(job: .backup, trigger: .schedule, startedAt: at, duration: 1, outcome: outcome)
}

private func setUp() throws -> (InventoryBackup, URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "backup-truth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appending(path: "inventory.json")
    try InventoryCoding.encoder().encode(Inventory(seedRevision: 5, products: [])).write(to: source)
    return (InventoryBackup(source: source, folder: dir.appending(path: "Backups")), dir)
}

@Suite("Backup truth: the folder, not the log")
struct BackupTruthTests {
    private let spec = AutomationCatalog.spec(.backup)

    @Test func aMissingFileMakesTheJobDueAgainWithinAMinute() {
        var ledger = AutomationLedger()
        ledger.record(run(.succeeded("saved"), at: t0), artifact: "inventory-2026-10-18.json")
        let state = ledger.states[.backup]
        #expect(state?.artifact == "inventory-2026-10-18.json")
        let normal = AutomationScheduler.nextDue(spec, state: state, lowPower: false)
        #expect(normal == t0.addingTimeInterval(1 + spec.cadence))
        let missing = AutomationScheduler.nextDue(spec, state: state, lowPower: false, artifactMissing: true)
        #expect(missing == t0.addingTimeInterval(1 + AutomationScheduler.artifactRecheck))
        let later = t0.addingTimeInterval(65)
        #expect(AutomationScheduler.dueJobs([spec], states: ledger.states, disabled: [], conditions: AutomationConditions(), now: later,
                                            missingArtifacts: [.backup]) == [.backup])
        #expect(AutomationScheduler.dueJobs([spec], states: ledger.states, disabled: [], conditions: AutomationConditions(), now: later).isEmpty)
        #expect(AutomationScheduler.sleepInterval([spec], states: ledger.states, disabled: [], conditions: AutomationConditions(),
                                                  now: t0.addingTimeInterval(30), missingArtifacts: [.backup]) == 31)
    }

    @Test func afterAFailureTheUsualBackoffHoldsSoItCannotSpin() {
        var ledger = AutomationLedger()
        ledger.record(run(.succeeded("saved"), at: t0), artifact: "inventory-2026-10-18.json")
        ledger.record(run(.failed("disk full"), at: t0.addingTimeInterval(120)))
        let state = ledger.states[.backup]
        // A failure keeps the artifact of the last run that did the work, but the timing is the failure's.
        #expect(state?.artifact == "inventory-2026-10-18.json")
        #expect(AutomationScheduler.nextDue(spec, state: state, lowPower: false, artifactMissing: true)
                == t0.addingTimeInterval(121 + spec.retryAfter))
    }

    @Test func whatCountsAsMissing() {
        var ledger = AutomationLedger()
        #expect(!InventoryBackup.artifactMissing(nil, fileNames: []))
        ledger.record(run(.succeeded("saved"), at: t0), artifact: "inventory-2026-10-18.json")
        let state = ledger.states[.backup]
        #expect(!InventoryBackup.artifactMissing(state, fileNames: ["inventory-2026-10-18.json"]))
        #expect(InventoryBackup.artifactMissing(state, fileNames: ["inventory-2026-10-17.json"]))
        #expect(InventoryBackup.artifactMissing(state, fileNames: []))
        // A ledger written before artifacts were recorded (the owner's, 2026-10-19): gone when no file is named for the
        // day that run ran, an empty folder among them.
        var old = AutomationLedger()
        old.record(run(.succeeded("Copy saved and read back: 12 products"), at: t0))
        #expect(old.states[.backup]?.artifact == nil)
        #expect(InventoryBackup.artifactMissing(old.states[.backup], fileNames: [], calendar: utc))
        #expect(!InventoryBackup.artifactMissing(old.states[.backup], fileNames: ["inventory-2026-10-18.json"], calendar: utc))
        // The newest file deleted, an older copy left: also gone, not a full day's wait.
        #expect(InventoryBackup.artifactMissing(old.states[.backup], fileNames: ["inventory-2026-10-10.json"], calendar: utc))
        // After a failed or skipped run nothing is vouched for.
        old.record(run(.skipped(.notReady), at: t0.addingTimeInterval(60)))
        #expect(!InventoryBackup.artifactMissing(old.states[.backup], fileNames: [], calendar: utc))
    }

    @Test func theFolderIsReadNotTheLog() throws {
        let (backup, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No folder yet: not an error, and empty.
        #expect(try backup.files() == nil)
        var status = backup.status(now: t0)
        #expect(status.isEmpty && status.newest == nil && status.listError == nil)

        let result = try backup.run(now: t0, calendar: utc)
        status = backup.status(now: t0)
        #expect(status.files == 1)
        #expect(status.names == ["inventory-2026-10-18.json"])
        #expect(status.newest?.name == result.file.lastPathComponent)
        #expect(status.newest?.day == KeyDay("2026-10-18"))
        #expect(status.restores)
        #expect(status.newestCheck == .restores(products: 0))
        #expect(status.matchesInventory == true)

        // The inventory changes: the copy still restores, but it is not the inventory as it is now.
        try InventoryCoding.encoder().encode(Inventory(seedRevision: 6, products: [])).write(to: backup.source)
        #expect(backup.status(now: t0).matchesInventory == false)

        // A damaged copy is said to be one.
        try Data("{\"schemaVersion\": 2".utf8).write(to: result.file)
        guard case .fails? = backup.status(now: t0).newestCheck else {
            Issue.record("a damaged copy must not count as restoring")
            return
        }
    }

    @Test func theIncidentFromStartToFinish() throws {
        let (backup, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = AutomationLedger()
        let first = try backup.run(now: t0, calendar: utc)
        ledger.record(run(.succeeded("Copy saved and read back: 0 products"), at: t0), artifact: first.file.lastPathComponent)

        // Someone deletes the file a minute later.
        try FileManager.default.removeItem(at: first.file)
        let names = try #require(try backup.files()).map(\.name)
        #expect(InventoryBackup.artifactMissing(ledger.states[.backup], fileNames: names))
        let status = backup.status(now: t0.addingTimeInterval(65))
        let lines = BackupRules.lines(status, state: ledger.states[.backup], now: t0.addingTimeInterval(65), calendar: utc)
        #expect(lines.map(\.id) == ["automation.backup.empty"])
        #expect(lines.first?.severity == .high)
        #expect(lines.first?.destination == .automation)

        // The job runs again and the copy is back: nothing to say any more.
        let second = try backup.run(now: t0.addingTimeInterval(70), calendar: utc)
        ledger.record(run(.succeeded("saved"), at: t0.addingTimeInterval(70)), artifact: second.file.lastPathComponent)
        let after = try #require(try backup.files()).map(\.name)
        #expect(!InventoryBackup.artifactMissing(ledger.states[.backup], fileNames: after))
        #expect(BackupRules.lines(backup.status(now: t0.addingTimeInterval(80)), state: ledger.states[.backup],
                                  now: t0.addingTimeInterval(80), calendar: utc).isEmpty)
    }

    @Test func aCopyConfirmedByTheJobIsNotOld() throws {
        let (backup, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = AutomationLedger()
        let first = try backup.run(now: t0, calendar: utc)
        ledger.record(run(.succeeded("saved"), at: t0), artifact: first.file.lastPathComponent)
        // Three days on, the inventory has not changed: the job confirms the copy instead of writing a new one.
        let later = t0.addingTimeInterval(3 * 86_400)
        let second = try backup.run(now: later, calendar: utc)
        #expect(second.kind == .unchanged && second.file.lastPathComponent == first.file.lastPathComponent)
        ledger.record(run(.succeeded("unchanged"), at: later), artifact: second.file.lastPathComponent)
        let status = backup.status(now: later.addingTimeInterval(5))
        #expect(status.matchesInventory == true && status.newest?.day == KeyDay("2026-10-18"))
        #expect(BackupRules.lines(status, state: ledger.states[.backup], now: later.addingTimeInterval(5), calendar: utc).isEmpty)
        // Without a run that vouched for it since, the same copy is old.
        var stale = AutomationLedger()
        stale.record(run(.succeeded("saved"), at: t0), artifact: first.file.lastPathComponent)
        let lines = BackupRules.lines(status, state: stale.states[.backup], now: later.addingTimeInterval(5), calendar: utc)
        #expect(lines.map(\.id) == ["automation.backup.old"])
        // Confirmed, but long ago: old, counted from the confirmation.
        let muchLater = later.addingTimeInterval(4 * 86_400)
        let confirmedLongAgo = BackupRules.lines(backup.status(now: muchLater), state: ledger.states[.backup], now: muchLater, calendar: utc)
        #expect(confirmedLongAgo.map(\.id) == ["automation.backup.old"])
        #expect(confirmedLongAgo.first?.text.contains("2026-10-21") == true)
    }

    @Test func aConfirmationStopsCountingOnceTheCopyIsNotTheInventory() {
        // The job vouched for the newest file an hour ago, but the inventory has changed since: that file is not the
        // inventory as it is now, so the confirmation does not count, and the copy is as old as its own day.
        let now = t0.addingTimeInterval(5 * 86_400)   // 2026-10-23
        var ledger = AutomationLedger()
        ledger.record(run(.succeeded("unchanged"), at: now.addingTimeInterval(-3600)), artifact: "inventory-2026-10-18.json")
        let newest = BackupFile(name: "inventory-2026-10-18.json", day: KeyDay("2026-10-18"))
        func status(matches: Bool?) -> BackupFolderStatus {
            BackupFolderStatus(checkedAt: now, files: 1, names: [newest.name], newest: newest, newestCheck: .restores(products: 0),
                               matchesInventory: matches)
        }
        let lines = BackupRules.lines(status(matches: false), state: ledger.states[.backup], now: now, calendar: utc)
        #expect(lines.map(\.id) == ["automation.backup.old"])
        #expect(lines.first?.text == "The newest backup is from 2026-10-18 (5 days ago)")
        // Not known whether it matches: not counted either.
        #expect(BackupRules.lines(status(matches: nil), state: ledger.states[.backup], now: now, calendar: utc).map(\.id)
                == ["automation.backup.old"])
        // The same file, still the inventory: the confirmation counts.
        #expect(BackupRules.lines(status(matches: true), state: ledger.states[.backup], now: now, calendar: utc).isEmpty)
    }

    @Test func whatTheEmptyLineSaysAboutTheNextRun() {
        var ledger = AutomationLedger()
        ledger.record(run(.succeeded("saved"), at: t0), artifact: "inventory-2026-10-18.json")
        let empty = BackupFolderStatus(checkedAt: t0.addingTimeInterval(65), files: 0)
        func detail(jobOff: Bool = false, paused: Date? = nil) -> String {
            BackupRules.lines(empty, state: ledger.states[.backup], now: t0.addingTimeInterval(65), calendar: utc, jobOff: jobOff,
                              pausedUntil: paused).first?.detail ?? ""
        }
        #expect(detail().contains("within 5 minutes"))
        #expect(!detail().contains("within a minute"))
        #expect(detail(jobOff: true).contains("turned off"))
        #expect(detail(paused: t0.addingTimeInterval(3600)).contains("paused"))
        // A pause that has ended changes nothing.
        #expect(detail(paused: t0).contains("within 5 minutes"))
    }

    @Test func linesForEachState() {
        let now = t0.addingTimeInterval(5 * 86_400)   // 2026-10-23
        var ledger = AutomationLedger()
        // Never run, nothing there.
        #expect(BackupRules.lines(BackupFolderStatus(checkedAt: now, files: 0), state: nil, now: now, calendar: utc).map(\.id)
                == ["automation.backup.none"])
        #expect(BackupRules.lines(nil, state: nil, now: now, calendar: utc).isEmpty)
        // The folder can't be listed: not the same as empty.
        #expect(BackupRules.lines(BackupFolderStatus(checkedAt: now, files: 0, listError: "Permission denied"), state: nil,
                                  now: now, calendar: utc).map(\.id) == ["automation.backup.unreadable"])
        // An old copy that no longer restores, and the file the log recorded is gone.
        ledger.record(run(.succeeded("saved"), at: t0.addingTimeInterval(4 * 86_400)), artifact: "inventory-2026-10-22.json")
        let old = BackupFile(name: "inventory-2026-10-18.json", day: KeyDay("2026-10-18"))
        let status = BackupFolderStatus(checkedAt: now, files: 1, names: [old.name], newest: old, newestCheck: .fails("bad JSON"))
        let lines = BackupRules.lines(status, state: ledger.states[.backup], now: now, calendar: utc)
        #expect(lines.map(\.id) == ["automation.backup.restore", "automation.backup.old", "automation.backup.gone"])
        #expect(lines.map(\.severity) == [.high, .normal, .normal])
        // Fresh and restoring: no line.
        let fresh = BackupFile(name: "inventory-2026-10-22.json", day: KeyDay("2026-10-22"))
        let good = BackupFolderStatus(checkedAt: now, files: 2, names: [fresh.name, old.name], newest: fresh,
                                      newestCheck: .restores(products: 12))
        #expect(BackupRules.lines(good, state: ledger.states[.backup], now: now, calendar: utc).isEmpty)
    }

    @Test func theBriefSaysWhatTheFolderHolds() {
        var ledger = AutomationLedger()
        ledger.record(run(.succeeded("Copy saved and read back: 12 products"), at: t0))
        func input(_ backup: BackupFolderStatus?) -> BriefInput {
            BriefInput(now: t0.addingTimeInterval(3600), monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                       licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                       worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                       operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []), automation: ledger,
                       backup: backup)
        }
        // Not looked at: a part not read, never "all clear" on the log's word.
        let unchecked = DailyBriefBuilder.automation(input(nil))
        #expect(unchecked.gaps.map(\.key) == ["backupFolder"])
        // Looked at and empty: a high line, which the Desk puts under Today.
        let empty = DailyBriefBuilder.automation(input(BackupFolderStatus(checkedAt: t0.addingTimeInterval(3600), files: 0)))
        #expect(empty.lines.map(\.id) == ["automation.backup.empty"])
        let desk = DeskBuilder.build(brief: DailyBrief(sections: [empty], generatedAt: t0), ledgers: .unsupported, state: DeskState(),
                                     now: t0.addingTimeInterval(3600), calendar: utc)
        #expect(desk.today.map(\.item.subjectKey) == ["automation.backup.empty"])
    }
}
