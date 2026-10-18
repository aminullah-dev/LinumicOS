import Foundation

/// The judgement the app shows for the Sentinel, from one overview. Pure: no clock or network of its own.
public struct SentinelSummary: Sendable, Equatable {
    /// Rounds run every 10 minutes; a last round older than this means the schedule or the function stopped.
    public static let staleAfter: TimeInterval = 25 * 60
    /// Snapshots run weekly; older than this means the weekly job stopped.
    public static let snapshotOverdueAfter: TimeInterval = 8 * 86_400

    public enum Health: Equatable, Sendable {
        /// No round has ever been recorded: the server side is not deployed (or never ran).
        case notRunning
        /// The last round is older than `staleAfter`; what it said may no longer be true.
        case stale(lastRoundAt: Date)
        /// Every target answers correctly.
        case allUp
        /// Some targets are slow, none down.
        case slow(count: Int)
        /// Some targets have failed two rounds in a row or more.
        case down(count: Int)
    }

    public let health: Health
    public let lastRoundAt: Date?
    public let down: [SentinelStatus]
    /// Answering, but slower than the target's threshold in the latest check.
    public let slow: [SentinelStatus]
    /// Failed the latest check once; not counted as down yet.
    public let flapping: [SentinelStatus]
    public let unacknowledged: Int
    /// Targets the app's Monitor checks that the server has not reported (catalog drift, or not run yet).
    public let missingFromServer: [String]
    /// Targets the server reports that the app's Monitor doesn't know.
    public let unknownToApp: [String]
    public let lastSnapshotAt: Date?
    /// True when rounds run but the weekly snapshot is missing or older than `snapshotOverdueAfter`.
    public let snapshotOverdue: Bool

    public static func make(_ overview: SentinelOverview, catalog: [MonitorTarget] = MonitorCatalog.targets, now: Date) -> SentinelSummary {
        let targets = overview.targets
        let down = targets.filter { $0.state == .down }
        let slow = targets.filter { $0.state != .down && $0.lastCheckState == .degraded }
        let flapping = targets.filter { $0.state != .down && $0.lastCheckState == .down }
        let lastRoundAt = overview.lastRound?.finishedAt
        let health: Health
        if let lastRoundAt {
            if now.timeIntervalSince(lastRoundAt) > staleAfter {
                health = .stale(lastRoundAt: lastRoundAt)
            } else if !down.isEmpty {
                health = .down(count: down.count)
            } else if !slow.isEmpty {
                health = .slow(count: slow.count)
            } else {
                health = .allUp
            }
        } else {
            health = .notRunning
        }
        let serverIDs = Set(targets.map(\.targetID))
        let appIDs = Set(catalog.map(\.id))
        let snapshotAt = overview.lastSnapshot?.createdAt
        let snapshotOverdue = lastRoundAt != nil && (snapshotAt.map { now.timeIntervalSince($0) > snapshotOverdueAfter } ?? true)
        return SentinelSummary(health: health, lastRoundAt: lastRoundAt, down: down, slow: slow, flapping: flapping,
                               unacknowledged: overview.unacknowledged,
                               missingFromServer: catalog.map(\.id).filter { !serverIDs.contains($0) },
                               unknownToApp: targets.map(\.targetID).filter { !appIDs.contains($0) },
                               lastSnapshotAt: snapshotAt, snapshotOverdue: snapshotOverdue)
    }

    /// Something the owner should look at: down, stale, unseen events or an overdue snapshot.
    public var needsAttention: Bool {
        switch health {
        case .down, .stale: true
        case .notRunning, .allUp, .slow: unacknowledged > 0 || snapshotOverdue
        }
    }
}
