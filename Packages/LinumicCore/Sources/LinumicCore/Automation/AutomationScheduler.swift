import Foundation

// MARK: - Conditions

/// What the device allows right now. Read by the engine; the scheduler itself is pure.
public struct AutomationConditions: Sendable, Hashable {
    public var online: Bool
    public var lowPower: Bool
    /// Everything waits until this time ("Pause for 1 hour").
    public var pausedUntil: Date?

    public init(online: Bool = true, lowPower: Bool = false, pausedUntil: Date? = nil) {
        self.online = online
        self.lowPower = lowPower
        self.pausedUntil = pausedUntil
    }

    public func isPaused(at now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > now
    }
}

// MARK: - Scheduler

/// Decides when each job runs next. Pure: the same inputs give the same answer, so it is fully testable.
public enum AutomationScheduler {
    /// Longest the engine sleeps between looks, so a changed setting or a missed wake is noticed.
    public static let maxSleep: TimeInterval = 5 * 60
    /// How soon after a run that did the work the job runs again when what it left on disk is gone.
    public static let artifactRecheck: TimeInterval = 60

    /// When `job` is next due. Never run: now. After work was done or skipped: one cadence after the last run
    /// (twice as long in Low Power Mode). After a failure: `retryAfter`, doubling with each further failure,
    /// capped at the cadence. `cadence` overrides the job's own (the Monitor stretches its own after silent rounds).
    ///
    /// `artifactMissing`: what the last successful run left on disk is gone (a backup file deleted after the run). The
    /// job is then due `artifactRecheck` after that run, not a cadence later; after a failure or a skip the usual timing
    /// holds. Either way it can't spin: at most one extra run a minute, and only while the last run did the work.
    public static func nextDue(_ spec: AutomationJobSpec, state: AutomationJobState?, lowPower: Bool,
                               cadence: TimeInterval? = nil, artifactMissing: Bool = false) -> Date? {
        guard let last = state?.lastRun else { return nil }   // nil = due now
        if artifactMissing, state?.lastRunDidTheWork == true { return last.finishedAt.addingTimeInterval(artifactRecheck) }
        let base = (cadence ?? spec.cadence) * (lowPower ? 2 : 1)
        let failures = state?.consecutiveFailures ?? 0
        if last.outcome.isFailure, failures > 0 {
            let backoff = spec.retryAfter * pow(2, Double(min(failures - 1, 10)))
            return last.finishedAt.addingTimeInterval(min(backoff, base))
        }
        return last.finishedAt.addingTimeInterval(base)
    }

    public static func isDue(_ spec: AutomationJobSpec, state: AutomationJobState?, now: Date, lowPower: Bool,
                             cadence: TimeInterval? = nil, artifactMissing: Bool = false) -> Bool {
        guard let due = nextDue(spec, state: state, lowPower: lowPower, cadence: cadence, artifactMissing: artifactMissing) else { return true }
        return due <= now
    }

    /// The jobs to run now, in catalog order. Nothing while paused; jobs that need the network wait while offline
    /// (they are not recorded as skipped on every look: the engine runs them when the network returns).
    /// `missingArtifacts`: jobs whose last successful run's file is gone (see `nextDue`).
    public static func dueJobs(_ specs: [AutomationJobSpec], states: [AutomationJobID: AutomationJobState],
                               disabled: Set<AutomationJobID>, conditions: AutomationConditions, now: Date,
                               cadences: [AutomationJobID: TimeInterval] = [:],
                               missingArtifacts: Set<AutomationJobID> = []) -> [AutomationJobID] {
        guard !conditions.isPaused(at: now) else { return [] }
        return specs.filter { spec in
            !disabled.contains(spec.id)
                && (conditions.online || !spec.needsNetwork)
                && isDue(spec, state: states[spec.id], now: now, lowPower: conditions.lowPower, cadence: cadences[spec.id],
                         artifactMissing: missingArtifacts.contains(spec.id))
        }.map(\.id)
    }

    /// How long to sleep before the next look: until the earliest job is due, the pause ends, or `maxSleep`.
    public static func sleepInterval(_ specs: [AutomationJobSpec], states: [AutomationJobID: AutomationJobState],
                                     disabled: Set<AutomationJobID>, conditions: AutomationConditions, now: Date,
                                     cadences: [AutomationJobID: TimeInterval] = [:],
                                     missingArtifacts: Set<AutomationJobID> = []) -> TimeInterval {
        if let until = conditions.pausedUntil, until > now { return min(until.timeIntervalSince(now), maxSleep) }
        var earliest = maxSleep
        for spec in specs where !disabled.contains(spec.id) && (conditions.online || !spec.needsNetwork) {
            guard let due = nextDue(spec, state: states[spec.id], lowPower: conditions.lowPower, cadence: cadences[spec.id],
                                    artifactMissing: missingArtifacts.contains(spec.id)) else { return 0 }
            earliest = min(earliest, max(0, due.timeIntervalSince(now)))
        }
        return earliest
    }
}

// MARK: - Ledger

/// Everything the engine remembers, on this device only (`automation.json`).
public struct AutomationLedger: Codable, Sendable, Hashable {
    /// Runs kept for the history list: the newest 500, none older than 14 days.
    public static let maxRuns = 500
    public static let runWindow: TimeInterval = 14 * 24 * 60 * 60

    public var states: [AutomationJobID: AutomationJobState] = [:]
    /// Newest first.
    public private(set) var runs: [AutomationRun] = []
    public var disabled: Set<AutomationJobID> = []
    public var pausedUntil: Date?
    public var quietHours = QuietHours()

    public init() {}

    /// Records a finished run and updates the job's state. `artifact` is what a run that did the work left on disk
    /// (the backup's file name); it replaces the one recorded before.
    public mutating func record(_ run: AutomationRun, artifact: String? = nil) {
        var state = states[run.job] ?? AutomationJobState()
        state.lastRun = run
        switch run.outcome {
        case .succeeded, .partial:
            state.lastSuccess = run.finishedAt
            state.consecutiveFailures = 0
            if let artifact { state.artifact = artifact }
        case .failed:
            state.consecutiveFailures += 1
        case .skipped:
            break
        }
        states[run.job] = state
        runs.insert(run, at: 0)
        prune(now: run.finishedAt)
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.runWindow)
        runs = Array(runs.filter { $0.startedAt >= cutoff }.prefix(Self.maxRuns))
    }

    public func runs(of job: AutomationJobID) -> [AutomationRun] { runs.filter { $0.job == job } }

    // Dictionaries keyed by an enum encode as arrays; keep the file readable with string keys.
    private enum CodingKeys: String, CodingKey { case states, runs, disabled, pausedUntil, quietHours }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: AutomationJobState].self, forKey: .states) ?? [:]
        states = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in AutomationJobID(rawValue: k).map { ($0, v) } })
        // A run of a job this version no longer knows is dropped, not a decoding error.
        runs = (try c.decodeIfPresent([LossyRun].self, forKey: .runs) ?? []).compactMap(\.run)
        disabled = Set((try c.decodeIfPresent([String].self, forKey: .disabled) ?? []).compactMap(AutomationJobID.init(rawValue:)))
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) }), forKey: .states)
        try c.encode(runs, forKey: .runs)
        try c.encode(disabled.map(\.rawValue).sorted(), forKey: .disabled)
        try c.encodeIfPresent(pausedUntil, forKey: .pausedUntil)
        try c.encode(quietHours, forKey: .quietHours)
    }

    private struct LossyRun: Decodable {
        let run: AutomationRun?
        init(from decoder: Decoder) throws { run = try? AutomationRun(from: decoder) }
    }
}

public struct AutomationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "automation.json")
    }

    public func load() -> AutomationLedger {
        guard let data = try? Data(contentsOf: fileURL) else { return AutomationLedger() }
        return (try? InventoryCoding.decoder().decode(AutomationLedger.self, from: data)) ?? AutomationLedger()
    }

    public func save(_ ledger: AutomationLedger) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(ledger).write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Health

/// The one-line answer to "is the automation healthy?", for the menu bar, the dashboard and the Brief.
public struct AutomationHealth: Sendable, Hashable {
    public enum Level: Int, Sendable, Comparable {
        case ok = 0, attention = 1, failing = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Jobs that failed this many times in a row are "failing".
    public static let failingAfter = 3

    public var level: Level
    public struct Failing: Sendable, Hashable {
        public var job: AutomationJobID
        /// Failures in a row.
        public var count: Int
        public var message: String
    }

    /// Enabled jobs whose last run failed.
    public var failing: [Failing]
    /// Enabled jobs that can't run here (no key or sign-in), so the owner knows what's not covered.
    public var notConnected: [AutomationJobID]
    public var lastRunAt: Date?

    public init(ledger: AutomationLedger, specs: [AutomationJobSpec] = AutomationCatalog.jobs) {
        var failing: [Failing] = []
        var notConnected: [AutomationJobID] = []
        for spec in specs where !ledger.disabled.contains(spec.id) {
            guard let state = ledger.states[spec.id], let run = state.lastRun else { continue }
            switch run.outcome {
            case .failed(let message): failing.append(Failing(job: spec.id, count: state.consecutiveFailures, message: message))
            case .skipped(.notConnected): notConnected.append(spec.id)
            default: break
            }
        }
        self.failing = failing
        self.notConnected = notConnected
        lastRunAt = ledger.runs.first?.finishedAt
        if failing.contains(where: { $0.count >= Self.failingAfter }) {
            level = .failing
        } else {
            level = failing.isEmpty ? .ok : .attention
        }
    }
}

// MARK: - Quiet hours

/// Night hours when notifications arrive silently (in Notification Center, no banner or sound). Checks still run.
public struct QuietHours: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Minutes after midnight, local time.
    public var start: Int
    public var end: Int

    public init(enabled: Bool = true, start: Int = 23 * 60, end: Int = 7 * 60) {
        self.enabled = enabled
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, start != end else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        // 23:00–07:00 wraps past midnight; 13:00–14:00 doesn't.
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }
}
