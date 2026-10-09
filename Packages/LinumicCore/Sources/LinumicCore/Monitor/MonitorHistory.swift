import Foundation

// MARK: - History (last 24 hours, on this device only)

public struct MonitorSample: Codable, Sendable, Equatable {
    public let at: Date
    public let state: MonitorState
    public let latencyMS: Int?

    public init(at: Date, state: MonitorState, latencyMS: Int?) {
        self.at = at
        self.state = state
        self.latencyMS = latencyMS
    }
}

public struct MonitorHistory: Codable, Sendable, Equatable {
    public static let window: TimeInterval = 24 * 60 * 60
    /// 24 h at one check every 5 minutes is 288; the cap leaves room for manual checks.
    public static let maxSamplesPerTarget = 600

    public private(set) var samples: [String: [MonitorSample]] = [:]

    public init() {}

    public mutating func append(_ result: MonitorResult, now: Date) {
        guard result.state != .unknown else { return }
        var list = samples[result.targetID, default: []]
        list.append(MonitorSample(at: result.checkedAt, state: result.state, latencyMS: result.latencyMS))
        list.sort { $0.at < $1.at }
        samples[result.targetID] = Self.trim(list, now: now)
    }

    /// Drops samples older than 24 hours (and targets no longer in the catalog when `keeping` is given).
    public mutating func prune(now: Date, keeping ids: Set<String>? = nil) {
        for (id, list) in samples {
            if let ids, !ids.contains(id) { samples[id] = nil; continue }
            let trimmed = Self.trim(list, now: now)
            samples[id] = trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func trim(_ list: [MonitorSample], now: Date) -> [MonitorSample] {
        let cutoff = now.addingTimeInterval(-window)
        return Array(list.filter { $0.at >= cutoff }.suffix(maxSamplesPerTarget))
    }

    public func recent(_ targetID: String, now: Date) -> [MonitorSample] {
        let cutoff = now.addingTimeInterval(-Self.window)
        return samples[targetID, default: []].filter { $0.at >= cutoff }
    }

    /// Share of checks in the last 24 hours that found the target available (up or slow), 0...1;
    /// nil with no checks. It is the share of checks, not of time: the app only checks while it runs.
    public func uptime(_ targetID: String, now: Date) -> Double? {
        let list = recent(targetID, now: now)
        guard !list.isEmpty else { return nil }
        return Double(list.count { $0.state.isAvailable }) / Double(list.count)
    }

    /// Latencies for the sparkline, oldest first; nil where the check had no response.
    public func latencies(_ targetID: String, now: Date) -> [Int?] {
        recent(targetID, now: now).map { $0.state.isAvailable ? $0.latencyMS : nil }
    }
}

// MARK: - Alerts (debounced)

public enum MonitorAlert: Equatable, Sendable {
    /// Down on two consecutive checks.
    case down(targetID: String)
    /// Available again after a `.down` alert.
    case recovered(targetID: String)
    case certificate(host: String, level: ExpiryLevel, daysLeft: Int)
    case domain(name: String, level: ExpiryLevel, daysLeft: Int)
}

public struct MonitorAlertState: Codable, Sendable, Equatable {
    public static let failuresBeforeAlert = 2

    public private(set) var consecutiveFailures: [String: Int] = [:]
    public private(set) var alertedDown: Set<String> = []
    /// The last expiry level seen per "cert:<host>" or "domain:<name>".
    public private(set) var expiryLevels: [String: ExpiryLevel] = [:]

    public init() {}

    /// Down alerts need two failures in a row; a recovery is reported only after a down alert.
    public mutating func record(_ result: MonitorResult) -> MonitorAlert? {
        let id = result.targetID
        switch result.state {
        case .down:
            let n = consecutiveFailures[id, default: 0] + 1
            consecutiveFailures[id] = n
            if n >= Self.failuresBeforeAlert, !alertedDown.contains(id) {
                alertedDown.insert(id)
                return .down(targetID: id)
            }
            return nil
        case .up, .degraded:
            consecutiveFailures[id] = 0
            if alertedDown.remove(id) != nil { return .recovered(targetID: id) }
            return nil
        case .unknown:
            return nil
        }
    }

    /// True when the level just got worse and is a warning (entering 30, 14 or 7 days, or expiring).
    /// A renewal lowers the stored level, so the next approach alerts again.
    public mutating func recordExpiry(key: String, level: ExpiryLevel) -> Bool {
        let previous = expiryLevels[key] ?? .ok
        expiryLevels[key] = level
        return level.isWarning && level > previous
    }
}

// MARK: - Schedule

public enum MonitorSchedule {
    /// One round every 5 minutes while the app runs.
    public static let baseInterval: TimeInterval = 5 * 60
    public static let maxInterval: TimeInterval = 30 * 60
    /// Domain registrations change rarely; rdap.org asks clients not to hammer it.
    public static let domainInterval: TimeInterval = 12 * 60 * 60

    /// Doubles after each round in which nothing answered (the Mac is likely offline), up to 30 minutes,
    /// and doubles again in Low Power Mode.
    public static func interval(failedRounds: Int, lowPower: Bool) -> TimeInterval {
        let backoff = baseInterval * pow(2, Double(min(max(failedRounds, 0), 3)))
        return min(backoff * (lowPower ? 2 : 1), maxInterval)
    }

    public static func isDomainCheckDue(lastFetch: Date?, now: Date) -> Bool {
        guard let lastFetch else { return true }
        return now.timeIntervalSince(lastFetch) >= domainInterval
    }
}

// MARK: - Runner

/// Performs one GET for a target. The app implements it with URLSession (and reads the TLS certificate);
/// tests use a stub.
public protocol MonitorProbe: Sendable {
    func probe(_ target: MonitorTarget) async -> MonitorObservation
}

public struct MonitorRound: Sendable {
    public let startedAt: Date
    public let results: [MonitorResult]
    public let certificates: [CertificateReading]
    public let cache: CacheCheck?

    /// Nothing answered at all: probably no network, so the round says nothing about the services.
    public var nothingAnswered: Bool { !results.isEmpty && results.allSatisfy { $0.reason == .transport } }
}

public struct MonitorRunner: Sendable {
    private let probe: MonitorProbe
    private let now: @Sendable () -> Date

    public init(probe: MonitorProbe, now: @escaping @Sendable () -> Date = { .now }) {
        self.probe = probe
        self.now = now
    }

    /// Checks every target at once and judges the answers.
    public func run(_ targets: [MonitorTarget] = MonitorCatalog.targets) async -> MonitorRound {
        let started = now()
        let observations = await withTaskGroup(of: MonitorObservation.self) { group in
            for target in targets { group.addTask { await probe.probe(target) } }
            var all: [MonitorObservation] = []
            for await o in group { all.append(o) }
            return all
        }
        let byID = Dictionary(observations.map { ($0.targetID, $0) }, uniquingKeysWith: { a, _ in a })
        var results: [MonitorResult] = []
        var certificates: [String: CertificateReading] = [:]
        var cache: CacheCheck?
        for target in targets {
            guard let o = byID[target.id] else { continue }
            results.append(MonitorEvaluator.evaluate(o, target: target))
            if let notAfter = o.certificateNotAfter {
                certificates[target.host] = CertificateReading(host: target.host, notAfter: notAfter, readAt: o.checkedAt)
            }
            if target.inspectsCache, o.statusCode != nil {
                cache = CacheCheck(url: target.url.absoluteString, headers: o.headers, checkedAt: o.checkedAt)
            }
        }
        return MonitorRound(startedAt: started, results: results,
                            certificates: certificates.values.sorted { $0.host < $1.host },
                            cache: cache)
    }
}

// MARK: - Snapshot (what is kept on disk)

/// Everything the Monitor remembers, on this device only (`monitor.json`): the last result per target, 24 hours
/// of samples, certificate and domain readings, the linumic.com cache headers and the alert state. All of it is
/// public information; no response body is stored.
public struct MonitorSnapshot: Codable, Sendable, Equatable {
    public var latest: [String: MonitorResult] = [:]
    public var history = MonitorHistory()
    public var certificates: [String: CertificateReading] = [:]
    public var domains: [String: DomainReading] = [:]
    /// The last RDAP error per domain, with its time (shown instead of a reading that is missing).
    public var domainErrors: [String: String] = [:]
    public var cache: CacheCheck?
    public var alerts = MonitorAlertState()
    public var lastRoundAt: Date?
    public var lastDomainFetchAt: Date?
    public var failedRounds = 0

    public init() {}

    /// Folds a round in and returns the alerts to post. A round where nothing answered is recorded in the history
    /// but raises no alert (the Mac is offline, not every service at once).
    public mutating func apply(_ round: MonitorRound, now: Date) -> [MonitorAlert] {
        lastRoundAt = round.startedAt
        var alerts: [MonitorAlert] = []
        let offline = round.nothingAnswered
        failedRounds = offline ? failedRounds + 1 : 0
        for result in round.results {
            latest[result.targetID] = result
            history.append(result, now: now)
            if !offline, let alert = self.alerts.record(result) { alerts.append(alert) }
        }
        for reading in round.certificates {
            certificates[reading.host] = reading
        }
        // Every known certificate is re-judged each round, so one read hours ago still crosses into a window on time.
        for host in MonitorCatalog.hosts {
            guard let reading = certificates[host] else { continue }
            let level = reading.level(now: now)
            if self.alerts.recordExpiry(key: "cert:\(host)", level: level) {
                alerts.append(.certificate(host: host, level: level, daysLeft: reading.daysLeft(now: now)))
            }
        }
        if let cache = round.cache { self.cache = cache }
        history.prune(now: now, keeping: Set(MonitorCatalog.targets.map(\.id)))
        alerts.append(contentsOf: judgeDomains(now: now))
        return alerts
    }

    public mutating func apply(domain reading: DomainReading, now: Date) -> [MonitorAlert] {
        domains[reading.name] = reading
        domainErrors[reading.name] = nil
        return judgeDomains(now: now)
    }

    public mutating func recordDomainError(_ name: String, message: String) {
        domainErrors[name] = message
    }

    private mutating func judgeDomains(now: Date) -> [MonitorAlert] {
        var alerts: [MonitorAlert] = []
        for (name, reading) in domains.sorted(by: { $0.key < $1.key }) {
            guard let level = reading.level(now: now), let days = reading.daysLeft(now: now) else { continue }
            if self.alerts.recordExpiry(key: "domain:\(name)", level: level) {
                alerts.append(.domain(name: name, level: level, daysLeft: days))
            }
        }
        return alerts
    }

    public func certificate(for target: MonitorTarget) -> CertificateReading? { certificates[target.host] }

    public func domain(for target: MonitorTarget) -> DomainReading? {
        MonitorCatalog.domain(for: target.host).flatMap { domains[$0.name] }
    }
}

/// Counts for the dashboard strip.
public struct MonitorSummary: Equatable, Sendable {
    public let up: Int
    public let degraded: Int
    public let down: Int
    public let notChecked: Int
    public let lastRoundAt: Date?
    /// Certificates and domains inside a 30-day window (or expired).
    public let expiryWarnings: Int
    /// The nearest certificate or domain expiry, in days.
    public let soonestExpiryDays: Int?

    public init(snapshot: MonitorSnapshot, targets: [MonitorTarget] = MonitorCatalog.targets, now: Date) {
        let states = targets.map { snapshot.latest[$0.id]?.state ?? .unknown }
        up = states.count { $0 == .up }
        degraded = states.count { $0 == .degraded }
        down = states.count { $0 == .down }
        notChecked = states.count { $0 == .unknown }
        lastRoundAt = snapshot.lastRoundAt
        let hosts = Set(targets.map(\.host))
        let certDays = snapshot.certificates.values.filter { hosts.contains($0.host) }.map { $0.daysLeft(now: now) }
        let domainDays = snapshot.domains.values.compactMap { $0.daysLeft(now: now) }
        let all = certDays + domainDays
        expiryWarnings = all.count { ExpiryLevel.level(daysLeft: $0).isWarning }
        soonestExpiryDays = all.min()
    }

    public var checked: Int { up + degraded + down }
}

/// Reads and writes `monitor.json` next to the inventory. A file that can't be read starts an empty snapshot.
public struct MonitorStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "monitor.json")
    }

    public func load() -> MonitorSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return MonitorSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MonitorSnapshot.self, from: data)) ?? MonitorSnapshot()
    }

    public func save(_ snapshot: MonitorSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
