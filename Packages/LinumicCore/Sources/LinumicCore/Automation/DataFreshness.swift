import Foundation

/// How current each automatic reading is, so an old number is never shown as if it were new.
///
/// `AutomationHealth` answers "is a job failing?". A job with no token is not failing: it is skipped, skips count as
/// neither failure nor success, and the app stays green while its numbers age (found live on 2026-11-02: nine sources
/// had not been read for ten days with no alert). This answers the other question: "can I trust what I see?". It only
/// reads the run log, and changes nothing about how jobs are scheduled.
public struct DataFreshness: Sendable, Hashable {
    public enum Standing: Sendable, Hashable {
        /// Read within its window.
        case fresh
        /// Runs, but its last good reading is too old (for example, it keeps being skipped while offline).
        case stale
        /// Needs a key, token or sign-in this device doesn't have.
        case disconnected
        /// Failed `AutomationHealth.failingAfter` times in a row, or has failed for longer than its window.
        case failing(String)
        /// The server side it reads isn't deployed: a known gap, not something to fix on this device.
        case notDeployed
        /// The owner turned it off.
        case turnedOff
        /// No run recorded yet (a fresh install, or the app has just started).
        case notYetRun
    }

    public struct Source: Sendable, Hashable, Identifiable {
        public var job: AutomationJobID
        public var standing: Standing
        /// The last reading that did the work; nil when there has never been one.
        public var lastGood: Date?
        public var id: AutomationJobID { job }

        /// Whether what this source feeds can't be trusted right now.
        public var isProblem: Bool {
            switch standing {
            case .stale, .disconnected, .failing: true
            case .fresh, .notDeployed, .turnedOff, .notYetRun: false
            }
        }
    }

    /// A reading is out of date after this many cadences...
    public static let staleCadences: Double = 3
    /// ...and never sooner than this, so a Mac waking from the night isn't reported as broken before its first round.
    public static let minimumStaleWindow: TimeInterval = 60 * 60

    public var sources: [Source]

    /// How long a reading of this job stays current. Low Power Mode doubles every cadence, so it doubles this too.
    public static func staleWindow(_ spec: AutomationJobSpec, lowPower: Bool = false) -> TimeInterval {
        max(spec.cadence * (lowPower ? 2 : 1) * staleCadences, minimumStaleWindow)
    }

    public init(ledger: AutomationLedger, specs: [AutomationJobSpec] = AutomationCatalog.jobs, now: Date, lowPower: Bool = false) {
        sources = specs.map { spec in
            let state = ledger.states[spec.id]
            return Source(job: spec.id,
                          standing: Self.standing(spec, state: state, disabled: ledger.disabled.contains(spec.id), now: now, lowPower: lowPower),
                          lastGood: state?.lastSuccess)
        }
    }

    static func standing(_ spec: AutomationJobSpec, state: AutomationJobState?, disabled: Bool, now: Date, lowPower: Bool) -> Standing {
        if disabled { return .turnedOff }
        guard let state, let run = state.lastRun else { return .notYetRun }

        let window = staleWindow(spec, lowPower: lowPower)
        func isCurrent(_ date: Date?) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) <= window
        }

        switch run.outcome {
        case .skipped(.notConnected): return .disconnected
        case .skipped(.notDeployed): return .notDeployed
        case .skipped(.turnedOff): return .turnedOff
        // Looked and found nothing new: the reading it holds is as good as this run, though the log's last success is older.
        case .skipped(.unchanged): return isCurrent(run.finishedAt) ? .fresh : .stale
        case .failed(let message):
            // One timeout on a good reading is not news; the scheduler is already retrying.
            if state.consecutiveFailures < AutomationHealth.failingAfter, isCurrent(state.lastSuccess) { return .fresh }
            return .failing(message)
        case .succeeded, .partial, .skipped(.offline), .skipped(.notReady), .skipped(.alreadyRunning):
            return isCurrent(state.lastSuccess) ? .fresh : .stale
        }
    }

    /// The sources that can't be trusted right now, in catalog order.
    public var problems: [Source] { sources.filter(\.isProblem) }

    /// The sources counted at all: a job that is turned off or not deployed says nothing about what is current.
    public var counted: [Source] {
        sources.filter {
            switch $0.standing {
            case .turnedOff, .notDeployed: false
            case .fresh, .stale, .disconnected, .failing, .notYetRun: true
            }
        }
    }

    /// A source needs a key or sign-in, so the way out is Settings, not the run log.
    public var needsConnection: Bool { problems.contains { $0.standing == .disconnected } }

    /// The oldest good reading among the problems. Sources never read have no date and are not counted here.
    public var oldestGood: Date? { problems.compactMap(\.lastGood).min() }
}
