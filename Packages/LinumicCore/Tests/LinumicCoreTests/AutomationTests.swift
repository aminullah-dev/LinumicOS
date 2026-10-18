import Foundation
import Testing
@testable import LinumicCore

private let t0 = Date(timeIntervalSince1970: 1_792_281_600) // 2026-10-18T00:00:00Z

private func run(_ job: AutomationJobID, _ outcome: AutomationOutcome, at: Date, duration: TimeInterval = 2,
                 trigger: AutomationTrigger = .schedule) -> AutomationRun {
    AutomationRun(job: job, trigger: trigger, startedAt: at, duration: duration, outcome: outcome)
}

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

@Suite("Automation catalog")
struct AutomationCatalogTests {
    @Test func everyJobHasOneSpecInRunOrder() {
        #expect(AutomationCatalog.jobs.map(\.id) == AutomationJobID.allCases)
        #expect(AutomationCatalog.jobs.last?.id == .brief)   // summarises what the others read
    }

    @Test func localJobsDontNeedTheNetwork() {
        let local = AutomationCatalog.jobs.filter { !$0.needsNetwork }.map(\.id)
        #expect(Set(local) == [.keys, .backup, .brief])
    }

    @Test func retriesAreNeverSlowerThanTheCadence() {
        for spec in AutomationCatalog.jobs { #expect(spec.retryAfter <= spec.cadence) }
    }
}

@Suite("Automation scheduler")
struct AutomationSchedulerTests {
    let stores = AutomationCatalog.spec(.stores)   // 30 min, retry 2 min

    @Test func neverRunIsDueNow() {
        #expect(AutomationScheduler.nextDue(stores, state: nil, lowPower: false) == nil)
        #expect(AutomationScheduler.isDue(stores, state: nil, now: t0, lowPower: false))
    }

    @Test func successWaitsOneCadenceFromTheEnd() {
        var ledger = AutomationLedger()
        ledger.record(run(.stores, .succeeded(nil), at: t0, duration: 10))
        let due = AutomationScheduler.nextDue(stores, state: ledger.states[.stores], lowPower: false)
        #expect(due == t0.addingTimeInterval(10 + 30 * 60))
        #expect(!AutomationScheduler.isDue(stores, state: ledger.states[.stores], now: t0.addingTimeInterval(29 * 60), lowPower: false))
    }

    @Test func lowPowerDoublesTheCadence() {
        var ledger = AutomationLedger()
        ledger.record(run(.stores, .succeeded(nil), at: t0, duration: 0))
        #expect(AutomationScheduler.nextDue(stores, state: ledger.states[.stores], lowPower: true) == t0.addingTimeInterval(60 * 60))
    }

    @Test func failuresBackOffExponentiallyUpToTheCadence() {
        var ledger = AutomationLedger()
        var at = t0
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            ledger.record(run(.stores, .failed("timeout"), at: at, duration: 0))
            let due = AutomationScheduler.nextDue(stores, state: ledger.states[.stores], lowPower: false)!
            waits.append(due.timeIntervalSince(at))
            at = due
        }
        #expect(waits == [120, 240, 480, 960, 1800, 1800])
        #expect(ledger.states[.stores]?.consecutiveFailures == 6)
    }

    @Test func successResetsTheFailureCount() {
        var ledger = AutomationLedger()
        ledger.record(run(.stores, .failed("x"), at: t0))
        ledger.record(run(.stores, .failed("x"), at: t0.addingTimeInterval(200)))
        ledger.record(run(.stores, .partial("1 of 2 stores failed"), at: t0.addingTimeInterval(600)))
        #expect(ledger.states[.stores]?.consecutiveFailures == 0)
        #expect(ledger.states[.stores]?.lastSuccess == t0.addingTimeInterval(602))
    }

    @Test func skipsNeitherCountAsFailureNorSuccess() {
        var ledger = AutomationLedger()
        ledger.record(run(.stores, .failed("x"), at: t0))
        ledger.record(run(.stores, .skipped(.notConnected), at: t0.addingTimeInterval(300)))
        #expect(ledger.states[.stores]?.consecutiveFailures == 1)
        #expect(ledger.states[.stores]?.lastSuccess == nil)
        // A skip waits a full cadence: no point retrying a missing key every two minutes.
        #expect(AutomationScheduler.nextDue(stores, state: ledger.states[.stores], lowPower: false) == t0.addingTimeInterval(302 + 1800))
    }

    @Test func cadenceOverrideIsUsed() {
        var ledger = AutomationLedger()
        ledger.record(run(.monitor, .succeeded(nil), at: t0, duration: 0))
        let due = AutomationScheduler.nextDue(AutomationCatalog.spec(.monitor), state: ledger.states[.monitor], lowPower: false, cadence: 20 * 60)
        #expect(due == t0.addingTimeInterval(20 * 60))
    }

    @Test func offlineHoldsBackNetworkJobsOnly() {
        let due = AutomationScheduler.dueJobs(AutomationCatalog.jobs, states: [:], disabled: [],
                                              conditions: AutomationConditions(online: false), now: t0)
        #expect(due == [.keys, .backup, .brief])
    }

    @Test func pauseHoldsEverythingUntilItEnds() {
        let conditions = AutomationConditions(pausedUntil: t0.addingTimeInterval(3600))
        #expect(AutomationScheduler.dueJobs(AutomationCatalog.jobs, states: [:], disabled: [], conditions: conditions, now: t0).isEmpty)
        #expect(AutomationScheduler.dueJobs(AutomationCatalog.jobs, states: [:], disabled: [], conditions: conditions,
                                            now: t0.addingTimeInterval(3601)).count == AutomationCatalog.jobs.count)
        // While paused the engine sleeps until the pause ends, at most `maxSleep`.
        #expect(AutomationScheduler.sleepInterval(AutomationCatalog.jobs, states: [:], disabled: [], conditions: conditions, now: t0)
                == AutomationScheduler.maxSleep)
    }

    @Test func disabledJobsNeverRun() {
        let due = AutomationScheduler.dueJobs(AutomationCatalog.jobs, states: [:], disabled: [.worktrack, .operations],
                                              conditions: AutomationConditions(), now: t0)
        #expect(!due.contains(.worktrack) && !due.contains(.operations))
        #expect(due.first == .monitor && due.last == .brief)
    }

    @Test func sleepsUntilTheEarliestDueJob() {
        var ledger = AutomationLedger()
        for spec in AutomationCatalog.jobs { ledger.record(run(spec.id, .succeeded(nil), at: t0, duration: 0)) }
        // Monitor (5 min) is the earliest.
        #expect(AutomationScheduler.sleepInterval(AutomationCatalog.jobs, states: ledger.states, disabled: [],
                                                  conditions: AutomationConditions(), now: t0.addingTimeInterval(60)) == 240)
        // With the Monitor off, the 30-minute jobs are capped by `maxSleep`.
        #expect(AutomationScheduler.sleepInterval(AutomationCatalog.jobs, states: ledger.states, disabled: [.monitor],
                                                  conditions: AutomationConditions(), now: t0) == AutomationScheduler.maxSleep)
        // Something never run: look again at once.
        #expect(AutomationScheduler.sleepInterval(AutomationCatalog.jobs, states: [:], disabled: [],
                                                  conditions: AutomationConditions(), now: t0) == 0)
    }
}

@Suite("Automation ledger")
struct AutomationLedgerTests {
    @Test func keepsNewestFirstAndPrunesByAgeAndCount() {
        var ledger = AutomationLedger()
        ledger.record(run(.keys, .succeeded(nil), at: t0))
        ledger.record(run(.keys, .succeeded(nil), at: t0.addingTimeInterval(15 * 24 * 3600)))
        #expect(ledger.runs.count == 1)   // the first is older than 14 days by now
        for i in 0..<(AutomationLedger.maxRuns + 20) {
            ledger.record(run(.monitor, .succeeded(nil), at: t0.addingTimeInterval(15 * 24 * 3600 + Double(i))))
        }
        #expect(ledger.runs.count == AutomationLedger.maxRuns)
        #expect(ledger.runs.first!.startedAt > ledger.runs.last!.startedAt)
    }

    @Test func roundTripsAndDropsUnknownJobs() throws {
        var ledger = AutomationLedger()
        ledger.record(run(.oversight, .partial("2 repositories failed"), at: t0))
        ledger.record(run(.backup, .skipped(.unchanged), at: t0))
        ledger.disabled = [.siteMessages]
        ledger.pausedUntil = t0
        ledger.quietHours = QuietHours(enabled: false, start: 60, end: 120)
        let data = try InventoryCoding.encoder().encode(ledger)
        #expect(try InventoryCoding.decoder().decode(AutomationLedger.self, from: data) == ledger)

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var runs = try #require(json["runs"] as? [[String: Any]])
        runs[0]["job"] = "retired"
        json["runs"] = runs
        json["disabled"] = ["siteMessages", "retired"]
        let edited = try JSONSerialization.data(withJSONObject: json)
        let decoded = try InventoryCoding.decoder().decode(AutomationLedger.self, from: edited)
        #expect(decoded.runs.count == 1)
        #expect(decoded.disabled == [.siteMessages])
    }

    @Test func storeSavesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "automation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AutomationStore(fileURL: dir.appending(path: "automation.json"))
        #expect(store.load() == AutomationLedger())
        var ledger = AutomationLedger()
        ledger.record(run(.brief, .succeeded(nil), at: t0))
        try store.save(ledger)
        #expect(store.load() == ledger)
    }
}

@Suite("Automation health")
struct AutomationHealthTests {
    @Test func okAttentionAndFailing() {
        var ledger = AutomationLedger()
        ledger.record(run(.stores, .succeeded(nil), at: t0))
        #expect(AutomationHealth(ledger: ledger).level == .ok)
        ledger.record(run(.platforms, .failed("HTTP 502"), at: t0))
        #expect(AutomationHealth(ledger: ledger).level == .attention)
        ledger.record(run(.platforms, .failed("HTTP 502"), at: t0.addingTimeInterval(200)))
        ledger.record(run(.platforms, .failed("HTTP 502"), at: t0.addingTimeInterval(500)))
        let health = AutomationHealth(ledger: ledger)
        #expect(health.level == .failing)
        #expect(health.failing == [.init(job: .platforms, count: 3, message: "HTTP 502")])
        // Turning the job off clears it from the health line.
        ledger.disabled = [.platforms]
        #expect(AutomationHealth(ledger: ledger).level == .ok)
    }

    @Test func notConnectedIsListedButNotAFailure() {
        var ledger = AutomationLedger()
        ledger.record(run(.worktrack, .skipped(.notConnected), at: t0))
        let health = AutomationHealth(ledger: ledger)
        #expect(health.level == .ok)
        #expect(health.notConnected == [.worktrack])
    }
}

@Suite("Quiet hours")
struct QuietHoursTests {
    private func at(_ h: Int, _ m: Int = 0) -> Date { t0.addingTimeInterval(Double(h * 3600 + m * 60)) }

    @Test func wrapsPastMidnight() {
        let q = QuietHours(enabled: true, start: 23 * 60, end: 7 * 60)
        #expect(q.contains(at(23), calendar: utc))
        #expect(q.contains(at(3), calendar: utc))
        #expect(!q.contains(at(7), calendar: utc))
        #expect(!q.contains(at(12), calendar: utc))
    }

    @Test func sameDayRangeAndOff() {
        let q = QuietHours(enabled: true, start: 13 * 60, end: 14 * 60)
        #expect(q.contains(at(13, 30), calendar: utc))
        #expect(!q.contains(at(14), calendar: utc))
        #expect(!QuietHours(enabled: false).contains(at(3), calendar: utc))
        #expect(!QuietHours(enabled: true, start: 60, end: 60).contains(at(1), calendar: utc))
    }
}

@Suite("Inventory backup")
struct InventoryBackupTests {
    private func setUp() throws -> (InventoryBackup, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appending(path: "inventory.json")
        try InventoryCoding.encoder().encode(Inventory(seedRevision: 5, products: [])).write(to: source)
        return (InventoryBackup(source: source, folder: dir.appending(path: "Backups"), keep: 3), dir)
    }

    @Test func writesVerifiesAndSkipsIdenticalCopies() throws {
        let (backup, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try backup.run(now: t0, calendar: utc)
        #expect(first.kind == .written)
        #expect(first.file.lastPathComponent == "inventory-2026-10-18.json")
        let second = try backup.run(now: t0.addingTimeInterval(86_400), calendar: utc)
        #expect(second.kind == .unchanged)
        #expect(backup.existing().count == 1)
    }

    @Test func keepsOnlyTheNewestCopies() throws {
        let (backup, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        for day in 0..<5 {
            try InventoryCoding.encoder().encode(Inventory(seedRevision: 5 + day, products: [])).write(to: backup.source)
            _ = try backup.run(now: t0.addingTimeInterval(Double(day) * 86_400), calendar: utc)
        }
        #expect(backup.existing().map(\.lastPathComponent) == ["inventory-2026-10-22.json", "inventory-2026-10-21.json", "inventory-2026-10-20.json"])
    }

    @Test func refusesACorruptCopy() throws {
        let (backup, dir) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{\"schemaVersion\": 1".utf8).write(to: backup.source)
        #expect(throws: InventoryBackup.BackupError.self) { try backup.run(now: t0, calendar: utc) }
    }

    @Test func noInventoryYet() {
        let backup = InventoryBackup(source: URL(filePath: "/nonexistent/inventory.json"), folder: URL(filePath: "/nonexistent/Backups"))
        #expect(throws: InventoryBackup.BackupError.noInventory) { try backup.run(now: t0) }
    }
}

@Suite("Automation in the Daily Brief")
struct AutomationBriefTests {
    private func input(_ ledger: AutomationLedger?) -> BriefInput {
        BriefInput(now: t0.addingTimeInterval(3600), monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                   licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                   worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                   operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []), automation: ledger)
    }

    @Test func neverRunUntilTheEngineRecordsSomething() {
        for ledger in [nil, AutomationLedger()] {
            guard case .neverRead = DailyBriefBuilder.automation(input(ledger)).state else {
                Issue.record("\(String(describing: ledger)) should be never read")
                continue
            }
        }
    }

    @Test func failingJobsBecomeLinesAndTheRestNotes() {
        var ledger = AutomationLedger()
        ledger.record(run(.stores, .succeeded(nil), at: t0))
        #expect(DailyBriefBuilder.automation(input(ledger)).state == .allClear)
        for i in 0..<3 { ledger.record(run(.oversight, .failed("HTTP 401"), at: t0.addingTimeInterval(Double(i) * 300))) }
        ledger.record(run(.worktrack, .skipped(.notConnected), at: t0))
        ledger.disabled = [.siteMessages]
        ledger.pausedUntil = t0.addingTimeInterval(7200)
        let section = DailyBriefBuilder.automation(input(ledger))
        #expect(section.state == .items)
        #expect(section.lines.count == 1)
        #expect(section.lines[0].severity == .high)
        #expect(section.lines[0].destination == .automation)
        #expect(section.lines[0].detail == "HTTP 401")
        #expect(section.notes.count == 3)
    }
}
