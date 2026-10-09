import Foundation

// MARK: - Daily snapshot ("what changed since yesterday")

/// A small record of what the app knew on one day, kept on this device only (`brief-snapshots.json`). Each field is
/// nil when its source had not been read, so a source signed in today never looks like a change from zero.
/// Holds states, counts, PR numbers and titles; no names of people, no credentials.
public struct BriefDailySnapshot: Codable, Equatable, Sendable {
    /// Local calendar day, `YYYY-MM-DD`.
    public var day: String
    public var takenAt: Date
    /// Monitor target id -> state.
    public var monitor: [String: MonitorState]?
    /// App Store app name -> "version: phase" of the version in progress, or the live version.
    public var appStore: [String: String]?
    /// "app name · track" -> release status labels.
    public var play: [String: String]?
    /// Repository slug -> open PR number (as text) -> title.
    public var pulls: [String: [String: String]]?
    /// Repository slug -> CI on the default branch.
    public var mainCI: [String: String]?
    public var licenceCount: Int?
    public var licenceActive: Int?
    public var worktrackCompanies: Int?
    public var worktrackExpired: Int?
    /// Operations queue raw value -> count (production and other environments alike, as read).
    public var operations: [String: Int]?

    public init(day: String, takenAt: Date, monitor: [String: MonitorState]? = nil, appStore: [String: String]? = nil,
                play: [String: String]? = nil, pulls: [String: [String: String]]? = nil, mainCI: [String: String]? = nil,
                licenceCount: Int? = nil, licenceActive: Int? = nil, worktrackCompanies: Int? = nil,
                worktrackExpired: Int? = nil, operations: [String: Int]? = nil) {
        self.day = day
        self.takenAt = takenAt
        self.monitor = monitor
        self.appStore = appStore
        self.play = play
        self.pulls = pulls
        self.mainCI = mainCI
        self.licenceCount = licenceCount
        self.licenceActive = licenceActive
        self.worktrackCompanies = worktrackCompanies
        self.worktrackExpired = worktrackExpired
        self.operations = operations
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// What the input knows right now.
    public static func capture(_ input: BriefInput, calendar: Calendar = .current) -> BriefDailySnapshot {
        var s = BriefDailySnapshot(day: dayKey(input.now, calendar: calendar), takenAt: input.now)
        if input.monitor.lastRoundAt != nil {
            var states: [String: MonitorState] = [:]
            for t in input.monitorTargets { if let r = input.monitor.latest[t.id] { states[t.id] = r.state } }
            s.monitor = states
        }
        let r = input.releases
        if r.appStoreReadAt != nil {
            var map: [String: String] = [:]
            for app in r.appStore where app.error == nil {
                for platform in app.platforms {
                    let key = app.platforms.count > 1 ? "\(app.app.name) \(platform)" : app.app.name
                    if let v = app.inProgress(platform: platform) {
                        map[key] = "\(v.versionString): \(v.phase.title)"
                    } else if let v = app.live(platform: platform) {
                        map[key] = "\(v.versionString): \(v.phase.title)"
                    }
                }
            }
            s.appStore = map
        }
        if r.playReadAt != nil {
            var map: [String: String] = [:]
            for app in r.play where app.error == nil {
                for track in app.tracks {
                    let releases = track.releases.filter { !$0.isEmptyDraft }
                    guard !releases.isEmpty else { continue }
                    map["\(app.app.name) · \(track.track)"] = releases.map { "\($0.label) \($0.status.title)" }.joined(separator: ", ")
                }
            }
            s.play = map
        }
        if r.gitHubReadAt != nil {
            var pulls: [String: [String: String]] = [:]
            var ci: [String: String] = [:]
            for repo in r.repos where repo.error == nil {
                pulls[repo.repo.slug] = Dictionary(repo.pulls.map { (String($0.number), $0.title) }, uniquingKeysWith: { a, _ in a })
                ci[repo.repo.slug] = repo.mainCI.rawValue
            }
            s.pulls = pulls
            s.mainCI = ci
        }
        if input.licences.isLoaded {
            s.licenceCount = input.licences.records.count
            s.licenceActive = input.licences.records.count { $0.status == .active }
        }
        if input.worktrack.isSignedIn, input.worktrack.lastRead != nil, input.worktrack.loadError == nil {
            let summary = WTCustomersSummary(companies: input.worktrack.companies)
            s.worktrackCompanies = summary.total
            s.worktrackExpired = summary.expired.count
        }
        let counts = input.operations.filter(\.isSignedIn).flatMap(\.counts)
        if !counts.isEmpty {
            s.operations = Dictionary(counts.map { ($0.queue.rawValue, $0.count) }, uniquingKeysWith: { a, _ in a })
        }
        return s
    }

    /// Fields this snapshot didn't read are taken from `earlier` (the same day's previous snapshot), so a source
    /// that is briefly unread (for example while the app is still signing in) keeps today's last known value.
    public func filling(from earlier: BriefDailySnapshot?) -> BriefDailySnapshot {
        guard let earlier, earlier.day == day else { return self }
        var s = self
        s.monitor = monitor ?? earlier.monitor
        s.appStore = appStore ?? earlier.appStore
        s.play = play ?? earlier.play
        s.pulls = pulls ?? earlier.pulls
        s.mainCI = mainCI ?? earlier.mainCI
        s.licenceCount = licenceCount ?? earlier.licenceCount
        s.licenceActive = licenceActive ?? earlier.licenceActive
        s.worktrackCompanies = worktrackCompanies ?? earlier.worktrackCompanies
        s.worktrackExpired = worktrackExpired ?? earlier.worktrackExpired
        s.operations = (operations ?? [:]).merging(earlier.operations ?? [:], uniquingKeysWith: { now, _ in now })
        if operations == nil, earlier.operations == nil { s.operations = nil }
        return s
    }
}

/// The last few days of snapshots: one per day, the latest of that day.
public struct BriefSnapshotHistory: Codable, Equatable, Sendable {
    public static let keepDays = 8
    public private(set) var snapshots: [BriefDailySnapshot]

    public init(snapshots: [BriefDailySnapshot] = []) {
        self.snapshots = snapshots.sorted { $0.day < $1.day }
    }

    /// Stores today's snapshot (replacing the earlier one of the same day, filling its gaps) and keeps a week.
    public mutating func record(_ snapshot: BriefDailySnapshot) {
        let earlier = snapshots.first { $0.day == snapshot.day }
        snapshots.removeAll { $0.day == snapshot.day }
        snapshots.append(snapshot.filling(from: earlier))
        snapshots.sort { $0.day < $1.day }
        if snapshots.count > Self.keepDays { snapshots.removeFirst(snapshots.count - Self.keepDays) }
    }

    /// The most recent snapshot from a day before `day`: "yesterday", or the last day the app was open.
    public func baseline(before day: String) -> BriefDailySnapshot? {
        snapshots.last { $0.day < day }
    }

    public func snapshot(for day: String) -> BriefDailySnapshot? { snapshots.first { $0.day == day } }
}

/// Reads and writes `brief-snapshots.json` next to the inventory. A file that can't be read starts empty.
public struct BriefSnapshotStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "brief-snapshots.json")
    }

    public func load() -> BriefSnapshotHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return BriefSnapshotHistory() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(BriefSnapshotHistory.self, from: data)) ?? BriefSnapshotHistory()
    }

    public func save(_ history: BriefSnapshotHistory) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(history).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Diff

public enum BriefDiff {
    /// What changed between `old` and `new`, grouped by area. Only fields read in both snapshots are compared.
    public static func lines(from old: BriefDailySnapshot, to new: BriefDailySnapshot,
                             targets: [MonitorTarget] = MonitorCatalog.targets) -> [BriefLine] {
        let source = LF("Snapshot of %@ compared with now", old.takenAt.formatted(date: .abbreviated, time: .shortened))
        var out: [BriefLine] = []
        func add(_ id: String, _ severity: BriefSeverity, _ text: String, _ destination: BriefDestination) {
            out.append(BriefLine(id: "changes.\(id)", kind: .changes, severity: severity, text: text, source: source,
                                 readAt: new.takenAt, destination: destination))
        }

        if let a = old.monitor, let b = new.monitor {
            for t in targets {
                guard let was = a[t.id], let now = b[t.id], was != now else { continue }
                let name = "\(t.product.title) \(L(t.name))"
                add("monitor.\(t.id)", now == .down ? .normal : .info,
                    LF("%@: %@ → %@", name, stateTitle(was), stateTitle(now)), .monitor)
            }
        }
        if let a = old.appStore, let b = new.appStore {
            for key in Set(a.keys).union(b.keys).sorted() {
                let was = a[key], now = b[key]
                guard was != now else { continue }
                add("appstore.\(key)", .info, LF("%@ on the App Store: %@ → %@", key, was ?? "–", now ?? "–"), .releaseCenter)
            }
        }
        if let a = old.play, let b = new.play {
            for key in Set(a.keys).union(b.keys).sorted() {
                let was = a[key], now = b[key]
                guard was != now else { continue }
                add("play.\(key)", .info, LF("%@ on Google Play: %@ → %@", key, was ?? "–", now ?? "–"), .releaseCenter)
            }
        }
        if let a = old.mainCI, let b = new.mainCI {
            for slug in Set(a.keys).intersection(b.keys).sorted() {
                guard let was = a[slug], let now = b[slug], was != now else { continue }
                add("ci.\(slug)", now == CIRollup.failure.rawValue ? .normal : .info,
                    LF("%@: CI on the default branch %@ → %@", slug, ciTitle(was), ciTitle(now)), .releaseCenter)
            }
        }
        if let a = old.pulls, let b = new.pulls {
            for slug in Set(a.keys).intersection(b.keys).sorted() {
                let was = a[slug] ?? [:], now = b[slug] ?? [:]
                for n in Set(now.keys).subtracting(was.keys).sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                    add("pr.new.\(slug).\(n)", .info, LF("%@: new PR #%@, %@", slug, n, now[n] ?? ""), .releaseCenter)
                }
                for n in Set(was.keys).subtracting(now.keys).sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                    add("pr.gone.\(slug).\(n)", .info, LF("%@: PR #%@ was merged or closed, %@", slug, n, was[n] ?? ""), .releaseCenter)
                }
            }
        }
        if let a = old.licenceCount, let b = new.licenceCount, a != b {
            add("licences.count", .info, LF("Licences in the ledger: %d → %d", a, b), .licences)
        }
        if let a = old.licenceActive, let b = new.licenceActive, a != b {
            add("licences.active", .info, LF("Active licences: %d → %d", a, b), .licences)
        }
        if let a = old.worktrackCompanies, let b = new.worktrackCompanies, a != b {
            add("worktrack.companies", .info, LF("WorkTrack companies: %d → %d", a, b), .worktrackCustomers)
        }
        if let a = old.worktrackExpired, let b = new.worktrackExpired, a != b {
            add("worktrack.expired", b > a ? .normal : .info, LF("Expired WorkTrack licences: %d → %d", a, b), .worktrackCustomers)
        }
        if let a = old.operations, let b = new.operations {
            for q in OperationsQueue.allCases {
                guard let was = a[q.rawValue], let now = b[q.rawValue], was != now else { continue }
                add("ops.\(q.rawValue)", .info, LF("%@: %d → %d", q.title, was, now), .operations(q.product))
            }
        }
        return out
    }

    static func stateTitle(_ s: MonitorState) -> String {
        switch s {
        case .up: L("Up")
        case .degraded: L("Slow")
        case .down: L("Down")
        case .unknown: L("Not checked")
        }
    }

    static func ciTitle(_ raw: String) -> String {
        CIRollup(rawValue: raw)?.title ?? raw
    }
}
