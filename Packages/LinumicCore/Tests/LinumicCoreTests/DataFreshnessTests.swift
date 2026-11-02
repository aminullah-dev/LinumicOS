import Foundation
import Testing
@testable import LinumicCore

@Suite("DataFreshness")
struct DataFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 60 * 60
    private let spec = AutomationCatalog.spec(.oversight)   // 30 minute cadence: a 90 minute window

    private func ledger(_ job: AutomationJobID = .oversight, runs: [(TimeInterval, AutomationOutcome)]) -> AutomationLedger {
        var ledger = AutomationLedger()
        for (ago, outcome) in runs.sorted(by: { $0.0 > $1.0 }) {
            ledger.record(AutomationRun(job: job, trigger: .schedule, startedAt: now.addingTimeInterval(-ago), duration: 0, outcome: outcome))
        }
        return ledger
    }

    private func standing(_ ledger: AutomationLedger, lowPower: Bool = false) -> DataFreshness.Standing {
        DataFreshness(ledger: ledger, specs: [spec], now: now, lowPower: lowPower).sources[0].standing
    }

    @Test func aRecentReadingIsFresh() {
        #expect(standing(ledger(runs: [(hour, .succeeded(nil))])) == .fresh)
        #expect(standing(ledger(runs: [(hour, .partial("3 read, 1 failed"))])) == .fresh)
    }

    @Test func anOldReadingIsStaleEvenThoughNothingFailed() {
        #expect(standing(ledger(runs: [(2 * hour, .succeeded(nil))])) == .stale)
    }

    @Test func skipsDoNotKeepAReadingCurrent() {
        // The bug this type exists for: the job keeps "running", the log has no failure, and the number is days old.
        let days = ledger(runs: [(24 * hour, .succeeded(nil)), (60, .skipped(.offline))])
        #expect(standing(days) == .stale)
    }

    @Test func aMissingTokenIsDisconnectedAndKeepsItsLastGoodDate() {
        let log = ledger(runs: [(240 * hour, .succeeded(nil)), (60, .skipped(.notConnected))])
        let freshness = DataFreshness(ledger: log, specs: [spec], now: now)
        #expect(freshness.sources[0].standing == .disconnected)
        #expect(freshness.needsConnection)
        #expect(freshness.oldestGood == now.addingTimeInterval(-240 * hour))
        // The run log that hid this: no failure and a healthy level.
        #expect(AutomationHealth(ledger: log, specs: [spec]).level == .ok)
    }

    @Test func aSourceNeverReadHasNoDateAndIsStillAProblem() {
        let freshness = DataFreshness(ledger: ledger(runs: [(60, .skipped(.notConnected))]), specs: [spec], now: now)
        #expect(freshness.problems.count == 1)
        #expect(freshness.sources[0].lastGood == nil)
        #expect(freshness.oldestGood == nil)
    }

    @Test func oneFailureOnAGoodReadingIsNotNews() {
        #expect(standing(ledger(runs: [(hour, .succeeded(nil)), (60, .failed("timeout"))])) == .fresh)
    }

    @Test func repeatedFailuresAreFailing() {
        let log = ledger(runs: [(hour, .succeeded(nil)), (300, .failed("a")), (200, .failed("b")), (100, .failed("c"))])
        #expect(standing(log) == .failing("c"))
    }

    @Test func aFailureOnAnOldReadingIsFailing() {
        #expect(standing(ledger(runs: [(24 * hour, .succeeded(nil)), (60, .failed("timeout"))])) == .failing("timeout"))
    }

    @Test func aFailureWithNoGoodReadingIsFailing() {
        #expect(standing(ledger(runs: [(60, .failed("timeout"))])) == .failing("timeout"))
    }

    @Test func anUnchangedRunCountsAsCurrent() {
        // The backup skips with "unchanged" when the file is identical, so its last success can be days old.
        let backup = AutomationCatalog.spec(.backup)
        let log = ledger(.backup, runs: [(240 * hour, .succeeded(nil)), (hour, .skipped(.unchanged))])
        #expect(DataFreshness(ledger: log, specs: [backup], now: now).sources[0].standing == .fresh)
    }

    @Test func turnedOffNotDeployedAndNotYetRunAreNotProblems() {
        var off = ledger(runs: [(240 * hour, .succeeded(nil))])
        off.disabled = [.oversight]
        #expect(standing(off) == .turnedOff)
        #expect(standing(ledger(runs: [(60, .skipped(.turnedOff))])) == .turnedOff)
        #expect(standing(ledger(runs: [(60, .skipped(.notDeployed))])) == .notDeployed)
        #expect(standing(AutomationLedger()) == .notYetRun)
        for log in [off, AutomationLedger()] {
            #expect(DataFreshness(ledger: log, specs: [spec], now: now).problems.isEmpty)
        }
    }

    @Test func onlyWhatCanBeReadIsCounted() {
        var log = ledger(runs: [(60, .skipped(.notDeployed))])
        log.disabled = [.platforms]
        let freshness = DataFreshness(ledger: log, specs: [spec, AutomationCatalog.spec(.platforms), AutomationCatalog.spec(.releases)], now: now)
        #expect(freshness.counted.map(\.job) == [.releases])
    }

    @Test func theWindowHasAFloorAndFollowsLowPower() {
        let monitor = AutomationCatalog.spec(.monitor)   // 5 minutes: three cadences would be 15 minutes
        #expect(DataFreshness.staleWindow(monitor) == DataFreshness.minimumStaleWindow)
        #expect(DataFreshness.staleWindow(spec) == 90 * 60)
        #expect(DataFreshness.staleWindow(spec, lowPower: true) == 180 * 60)
        #expect(standing(ledger(runs: [(2 * hour, .succeeded(nil))]), lowPower: true) == .fresh)
    }

    @Test func problemsStayInCatalogOrder() {
        var log = ledger(.releases, runs: [(60, .skipped(.notConnected))])
        log.record(AutomationRun(job: .monitor, trigger: .schedule, startedAt: now.addingTimeInterval(-60), duration: 0, outcome: .skipped(.notConnected)))
        #expect(DataFreshness(ledger: log, now: now).problems.map(\.job) == [.monitor, .releases])
    }
}
