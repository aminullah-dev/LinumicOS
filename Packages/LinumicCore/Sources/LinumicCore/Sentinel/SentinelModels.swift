import Foundation

// Sentinel: the Monitor's checks run on Supabase every 10 minutes (pg_cron -> the `sentinel` Edge Function), plus
// the daily licence-expiry sweep and the weekly inventory snapshot, so they keep running while the Mac is off.
// Server side: supabase/migrations/20261018090000_sentinel.sql, supabase/functions/sentinel/. Guide: docs/sentinel.md.

/// One check in the JSON shape the Edge Function sends to `sentinel_record_round()`
/// (supabase/functions/sentinel/evaluate.ts `Check`). The app builds the same shape from a `MonitorResult`.
public struct SentinelCheck: Codable, Sendable, Equatable {
    public let targetID: String
    public let product: String
    public let checkedAt: Date
    public let state: MonitorState
    public let statusCode: Int?
    public let latencyMS: Int?
    public let healthStatus: String?
    public let reason: MonitorReason?
    public let failure: String?

    public init(targetID: String, product: String, checkedAt: Date, state: MonitorState, statusCode: Int? = nil,
                latencyMS: Int? = nil, healthStatus: String? = nil, reason: MonitorReason? = nil, failure: String? = nil) {
        self.targetID = targetID
        self.product = product
        self.checkedAt = checkedAt
        self.state = state
        self.statusCode = statusCode
        self.latencyMS = latencyMS
        self.healthStatus = healthStatus
        self.reason = reason
        self.failure = failure
    }

    public init(_ result: MonitorResult, product: MonitorProduct) {
        self.init(targetID: result.targetID, product: product.rawValue, checkedAt: result.checkedAt, state: result.state,
                  statusCode: result.statusCode, latencyMS: result.latencyMS, healthStatus: result.healthStatus,
                  reason: result.reason, failure: result.failure)
    }
}

/// One server round (`sentinel_rounds`).
public struct SentinelRound: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let startedAt: Date
    public let finishedAt: Date
    /// "cron" (every 10 minutes) or "manual" (Check now from the app).
    public let source: String
    public let targetCount: Int
    public let upCount: Int
    public let degradedCount: Int
    public let downCount: Int
}

/// What the server holds for a target (`sentinel_target_state`).
public enum SentinelTargetState: String, Codable, Sendable {
    /// Not answered yet since the Sentinel started (or one failure on first sight).
    case unknown
    case up
    /// Two failed rounds in a row or more.
    case down
}

/// One target as the server sees it, with the counts of the overview's window (24 hours by default).
public struct SentinelStatus: Codable, Sendable, Equatable, Identifiable {
    public let targetID: String
    public let product: String
    public let state: SentinelTargetState
    public let consecutiveFailures: Int
    /// When the current state began.
    public let since: Date
    public let lastCheckedAt: Date
    public let lastFailureAt: Date?
    public let lastFailure: String?
    /// Checks in the window, and how many answered correctly (up or slow).
    public let samples: Int
    public let available: Int
    public let avgLatencyMS: Int?
    public let lastLatencyMS: Int?
    /// The latest single check: `.degraded` means slow, `.down` can still be a one-off before the target counts as down.
    public let lastCheckState: MonitorState?

    public var id: String { targetID }

    /// Share of checks in the window that answered correctly; nil without samples (never a false 0 %).
    public var uptime: Double? { samples > 0 ? Double(available) / Double(samples) : nil }

    public init(targetID: String, product: String, state: SentinelTargetState, consecutiveFailures: Int = 0, since: Date,
                lastCheckedAt: Date, lastFailureAt: Date? = nil, lastFailure: String? = nil, samples: Int = 0, available: Int = 0,
                avgLatencyMS: Int? = nil, lastLatencyMS: Int? = nil, lastCheckState: MonitorState? = nil) {
        self.targetID = targetID
        self.product = product
        self.state = state
        self.consecutiveFailures = consecutiveFailures
        self.since = since
        self.lastCheckedAt = lastCheckedAt
        self.lastFailureAt = lastFailureAt
        self.lastFailure = lastFailure
        self.samples = samples
        self.available = available
        self.avgLatencyMS = avgLatencyMS
        self.lastLatencyMS = lastLatencyMS
        self.lastCheckState = lastCheckState
    }
}

/// The newest weekly copy of `export_inventory()` (`inventory_snapshots`), without its data.
public struct SentinelSnapshotInfo: Codable, Sendable, Equatable {
    public let id: Int
    public let createdAt: Date
    public let bytes: Int
    public let schemaVersion: Int?
}

/// `sentinel_overview()`: everything the app shows, in one call.
public struct SentinelOverview: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let windowHours: Int
    public let lastRound: SentinelRound?
    public let targets: [SentinelStatus]
    public let unacknowledged: Int
    public let snapshotCount: Int
    public let lastSnapshot: SentinelSnapshotInfo?

    public init(generatedAt: Date, windowHours: Int = 24, lastRound: SentinelRound? = nil, targets: [SentinelStatus] = [],
                unacknowledged: Int = 0, snapshotCount: Int = 0, lastSnapshot: SentinelSnapshotInfo? = nil) {
        self.generatedAt = generatedAt
        self.windowHours = windowHours
        self.lastRound = lastRound
        self.targets = targets
        self.unacknowledged = unacknowledged
        self.snapshotCount = snapshotCount
        self.lastSnapshot = lastSnapshot
    }
}

public enum SentinelEventKind: String, Codable, Sendable, CaseIterable {
    case targetDown, targetRecovered, licenceExpiring, licenceExpired
}

public enum SentinelSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case info, warning, critical

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (a: SentinelSeverity, b: SentinelSeverity) -> Bool { a.rank < b.rank }
}

/// The facts behind an event. Which fields are present depends on the kind.
public struct SentinelEventDetail: Codable, Sendable, Equatable {
    // targetDown
    public let reason: MonitorReason?
    public let statusCode: Int?
    public let failure: String?
    public let failedRounds: Int?
    // targetRecovered
    public let downSince: Date?
    // licenceExpiring / licenceExpired
    public let customer: String?
    /// The licence's expiry day, "YYYY-MM-DD" as stored in the ledger.
    public let expires: String?
    public let daysLeft: Int?
    /// 30, 7, 1 or 0 (expired).
    public let threshold: Int?
    public let edition: String?
}

/// A change the server noticed (`sentinel_events`). Written once per change; acknowledging only marks it seen.
public struct SentinelEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let occurredAt: Date
    public let kind: SentinelEventKind
    public let severity: SentinelSeverity
    /// The target id (targetDown/Recovered) or the licence id (licence events).
    public let subject: String
    /// A `MonitorProduct` raw value for targets, `mediflow` / `khayatyar` for licences.
    public let product: String
    /// English, written by the server; the app builds its own localized line from `kind` and `detail`.
    public let title: String
    public let detail: SentinelEventDetail?
    public let acknowledgedAt: Date?

    public var isAcknowledged: Bool { acknowledgedAt != nil }
}
