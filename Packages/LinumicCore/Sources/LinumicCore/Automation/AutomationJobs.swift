import Foundation

// MARK: - Jobs

/// Every piece of work the app does on its own. The engine (App layer) owns the timing; each job only says what it
/// did. Listed in run order: the Brief goes last because it summarises what the others just read.
public enum AutomationJobID: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case monitor
    case stores
    case oversight
    case platforms
    case releases
    case licences
    case worktrack
    case operations
    case siteMessages
    case keys
    case backup
    case brief

    public var id: String { rawValue }
}

/// What a job is and how often it runs. Titles and details are English; the app localizes them with `L(_:)`.
public struct AutomationJobSpec: Sendable, Hashable, Identifiable {
    public let id: AutomationJobID
    public let title: String
    public let detail: String
    /// Time between successful runs.
    public let cadence: TimeInterval
    /// First retry after a failure; doubles with each further failure, never beyond `cadence`.
    public let retryAfter: TimeInterval
    /// Skipped (not failed) while the device is offline, and run as soon as the network comes back.
    public let needsNetwork: Bool
    /// iOS background refresh gets a few seconds of time: only light jobs run there.
    public let runsInBackground: Bool
    /// The old per-feature switch in Settings that this job still honours (nil: always on unless paused).
    public let settingsKey: String?

    public init(id: AutomationJobID, title: String, detail: String, cadence: TimeInterval, retryAfter: TimeInterval = 2 * 60,
                needsNetwork: Bool = true, runsInBackground: Bool = false, settingsKey: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.cadence = cadence
        self.retryAfter = retryAfter
        self.needsNetwork = needsNetwork
        self.runsInBackground = runsInBackground
        self.settingsKey = settingsKey
    }
}

public enum AutomationCatalog {
    public static let jobs: [AutomationJobSpec] = [
        AutomationJobSpec(id: .monitor, title: "Monitor",
                          detail: "Public health, TLS and domain checks of every platform.",
                          cadence: 5 * 60, retryAfter: 5 * 60, runsInBackground: true),
        AutomationJobSpec(id: .stores, title: "Store listings",
                          detail: "Public App Store data, then App Store Connect and Google Play when their keys are saved.",
                          cadence: 30 * 60, settingsKey: "LCCAutoRefreshStores"),
        AutomationJobSpec(id: .oversight, title: "Oversight sweep",
                          detail: "Every repository on GitHub, plus the local working copies when a folder is chosen.",
                          cadence: 30 * 60, settingsKey: "LCCAutoRefreshOversight"),
        AutomationJobSpec(id: .platforms, title: "Platforms",
                          detail: "Versions on main, releases, CI and open pull requests per product.",
                          cadence: 30 * 60, settingsKey: "LCCAutoRefreshPlatforms"),
        AutomationJobSpec(id: .releases, title: "Release Center",
                          detail: "App Store versions and builds, Play tracks, pull requests and CI.",
                          cadence: 30 * 60, settingsKey: "LCCAutoRefreshReleases"),
        AutomationJobSpec(id: .licences, title: "Licence sync",
                          detail: "The licence ledger with the cloud, and expiry reminders.",
                          cadence: 30 * 60),
        AutomationJobSpec(id: .worktrack, title: "WorkTrack customers",
                          detail: "Companies, plans and renewals from the WorkTrack vendor API.",
                          cadence: 6 * 60 * 60, retryAfter: 10 * 60),
        AutomationJobSpec(id: .operations, title: "Operations",
                          detail: "Talar, SafeBeauty and VELRO queues and counts.",
                          cadence: 30 * 60),
        AutomationJobSpec(id: .siteMessages, title: "Website messages",
                          detail: "New linumic.com contact form entries.",
                          cadence: 30 * 60),
        AutomationJobSpec(id: .keys, title: "Keys & Backups",
                          detail: "Dates and sizes of key files in the granted folders. No network.",
                          cadence: 60 * 60, needsNetwork: false),
        AutomationJobSpec(id: .backup, title: "Local inventory backup",
                          detail: "A daily copy of the inventory on this device, read back to prove it restores.",
                          cadence: 24 * 60 * 60, retryAfter: 30 * 60, needsNetwork: false),
        AutomationJobSpec(id: .brief, title: "Daily Brief",
                          detail: "Today's snapshot and the morning notification, from what the jobs above read.",
                          cadence: 30 * 60, needsNetwork: false, runsInBackground: true),
    ]

    public static func spec(_ id: AutomationJobID) -> AutomationJobSpec {
        jobs.first { $0.id == id }!
    }
}

// MARK: - Outcomes

public enum AutomationTrigger: String, Codable, Sendable, Hashable {
    /// The job was due.
    case schedule
    /// "Run now" or "Run all now".
    case manual
    /// The app just started.
    case launch
    /// The Mac woke from sleep.
    case wake
    /// The network came back.
    case network
    /// iOS background app refresh.
    case background
}

public enum AutomationSkipReason: String, Codable, Sendable, Hashable {
    /// No network connection.
    case offline
    /// Its switch in Settings is off.
    case turnedOff
    /// It needs a key, token or sign-in that this device doesn't have.
    case notConnected
    /// The inventory hasn't loaded yet.
    case notReady
    /// The same work was already running (started from its own screen).
    case alreadyRunning
    /// Nothing to do (for example, the backup is identical to the last one).
    case unchanged
}

public enum AutomationOutcome: Codable, Sendable, Hashable {
    /// Done. The note says what was read ("12 repositories"), in English, for the app to localize.
    case succeeded(String?)
    /// Done, but part of it failed (some repositories or one of several sources).
    case partial(String)
    case skipped(AutomationSkipReason)
    case failed(String)

    public var isFailure: Bool { if case .failed = self { true } else { false } }
    public var isSkip: Bool { if case .skipped = self { true } else { false } }
}

// MARK: - Run log

/// One run of one job, as recorded on this device.
public struct AutomationRun: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var job: AutomationJobID
    public var trigger: AutomationTrigger
    public var startedAt: Date
    public var duration: TimeInterval
    public var outcome: AutomationOutcome

    public init(id: UUID = UUID(), job: AutomationJobID, trigger: AutomationTrigger, startedAt: Date, duration: TimeInterval,
                outcome: AutomationOutcome) {
        self.id = id
        self.job = job
        self.trigger = trigger
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
    }

    public var finishedAt: Date { startedAt.addingTimeInterval(duration) }
}

/// Where each job stands.
public struct AutomationJobState: Codable, Sendable, Hashable {
    public var lastRun: AutomationRun?
    /// The last run that did the work (succeeded or partial).
    public var lastSuccess: Date?
    /// Failures since the last run that did the work; skips don't count either way.
    public var consecutiveFailures: Int = 0

    public init(lastRun: AutomationRun? = nil, lastSuccess: Date? = nil, consecutiveFailures: Int = 0) {
        self.lastRun = lastRun
        self.lastSuccess = lastSuccess
        self.consecutiveFailures = consecutiveFailures
    }
}
