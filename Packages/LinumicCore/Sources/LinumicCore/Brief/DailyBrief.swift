import Foundation

// MARK: - Daily Brief (گزارش روز)
//
// One page that summarises what the app has ALREADY read: Monitor, Release Center, the licence ledger, WorkTrack
// customers, Operations queues and Oversight, plus what changed since yesterday. Nothing here makes a request; the
// App layer collects each model's state into `BriefInput` and renders `DailyBrief`. Every line carries its source and
// the time it was read. A source that was never read says so instead of showing zero.

/// Where a line or section comes from. The order is the order of the sections on screen.
public enum BriefSourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case monitor, siteMessages, releases, licences, worktrack, operations, oversight, keys, changes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monitor: L("Monitor")
        case .siteMessages: L("Website messages")
        case .releases: L("Releases")
        case .licences: L("Licences")
        case .worktrack: L("WorkTrack customers")
        case .operations: L("Operations")
        case .oversight: L("Oversight")
        case .keys: L("Keys & Backups")
        case .changes: L("What changed since yesterday")
        }
    }

    public var symbol: String {
        switch self {
        case .monitor: "waveform.path.ecg"
        case .siteMessages: "envelope"
        case .releases: "shippingbox.and.arrow.backward"
        case .licences: "key.horizontal"
        case .worktrack: "person.2.badge.key"
        case .operations: "tray.full"
        case .oversight: "scope"
        case .keys: "externaldrive.badge.checkmark"
        case .changes: "clock.arrow.circlepath"
        }
    }
}

/// The screen a line's button opens. The App maps it to its sidebar and routes.
public enum BriefDestination: Hashable, Sendable {
    case monitor
    case releaseCenter
    case licences
    case licence(String)
    case worktrackCustomers
    case worktrackCompany(String)
    case operations(OperationsProduct?)
    case oversight
    case keys
    case siteMessages
}

public enum BriefSeverity: Int, Codable, Sendable, Comparable {
    /// Needs the owner now: something down, rejected, expired, failing.
    case high = 0
    /// Needs the owner soon: expiring within 30 days, a queue waiting, a PR ready.
    case normal = 1
    /// For information: a change, a staged rollout, a recently issued licence.
    case info = 2

    public static func < (a: BriefSeverity, b: BriefSeverity) -> Bool { a.rawValue < b.rawValue }
}

/// An extra link on a line (open a record on the web, reply by email).
public struct BriefLink: Hashable, Sendable, Identifiable {
    public var title: String
    public var url: URL
    public var symbol: String
    public var id: String { url.absoluteString }

    public init(title: String, url: URL, symbol: String) {
        self.title = title
        self.url = url
        self.symbol = symbol
    }
}

/// One sentence of the brief, with where it was read and when.
public struct BriefLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: BriefSourceKind
    public var severity: BriefSeverity
    public var text: String
    public var detail: String?
    public var source: String
    /// When the underlying fact was read. Nil only for facts of the local ledger that was never synced.
    public var readAt: Date?
    public var destination: BriefDestination
    /// Links shown beside the Open button.
    public var links: [BriefLink]

    public init(id: String, kind: BriefSourceKind, severity: BriefSeverity, text: String, detail: String? = nil,
                source: String, readAt: Date?, destination: BriefDestination, links: [BriefLink] = []) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.text = text
        self.detail = detail
        self.source = source
        self.readAt = readAt
        self.destination = destination
        self.links = links
    }
}

public struct BriefSection: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Never read on this device (not signed in, no key, not checked yet). The reason is shown as is.
        case neverRead(String)
        /// The last reading failed and nothing current is known.
        case unavailable(String)
        /// Read, and nothing to report.
        case allClear
        /// Read, with lines to show.
        case items
    }

    public var kind: BriefSourceKind
    public var state: State
    public var lines: [BriefLine]
    /// The newest read time of what the section is built from.
    public var readAt: Date?
    /// Where the section reads from, e.g. "monitor.json (this device)".
    public var source: String
    /// Partial gaps worth saying: one of three products not signed in, one store without a key.
    public var notes: [String]

    public var id: String { kind.rawValue }

    public init(kind: BriefSourceKind, state: State, lines: [BriefLine] = [], readAt: Date?, source: String, notes: [String] = []) {
        self.kind = kind
        self.state = state
        self.lines = lines
        self.readAt = readAt
        self.source = source
        self.notes = notes
    }

    /// Lines that need the owner (high or normal).
    public var attentionCount: Int { lines.count { $0.severity <= .normal } }
    public var highest: BriefSeverity? { lines.map(\.severity).min() }
}

public struct DailyBrief: Sendable, Equatable {
    public var sections: [BriefSection]
    public var generatedAt: Date

    public init(sections: [BriefSection], generatedAt: Date) {
        self.sections = sections
        self.generatedAt = generatedAt
    }

    public func section(_ kind: BriefSourceKind) -> BriefSection? { sections.first { $0.kind == kind } }

    /// Every line that needs the owner, most urgent first (then by section order).
    public var attention: [BriefLine] {
        let order = Dictionary(uniqueKeysWithValues: BriefSourceKind.allCases.enumerated().map { ($1, $0) })
        return sections.flatMap(\.lines).filter { $0.severity <= .normal }
            .sorted { ($0.severity, order[$0.kind] ?? 0) < ($1.severity, order[$1.kind] ?? 0) }
    }

    public var attentionCount: Int { attention.count }

    /// Sources that have never been read, by title.
    public var neverRead: [BriefSourceKind] {
        sections.compactMap { if case .neverRead = $0.state { $0.kind } else { nil } }
    }
}

// MARK: - Input (plain values the App collects from its models)

public struct BriefLicenceInput: Sendable {
    public var isLoaded: Bool
    public var records: [LicenceRecord]
    /// The last successful sync with Supabase; nil when the ledger is local only.
    public var lastSyncedAt: Date?

    public init(isLoaded: Bool, records: [LicenceRecord], lastSyncedAt: Date?) {
        self.isLoaded = isLoaded
        self.records = records
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct BriefWorkTrackInput: Sendable {
    public var isSignedIn: Bool
    /// The environment's raw value (production, staging, localEmulator).
    public var environment: String?
    public var companies: [WTCompany]
    public var lastRead: Date?
    public var loadError: String?

    public init(isSignedIn: Bool, environment: String?, companies: [WTCompany], lastRead: Date?, loadError: String? = nil) {
        self.isSignedIn = isSignedIn
        self.environment = environment
        self.companies = companies
        self.lastRead = lastRead
        self.loadError = loadError
    }
}

public struct BriefOperationsInput: Sendable {
    public var product: OperationsProduct
    public var isSignedIn: Bool
    public var counts: [OperationsCount]
    public var loadError: String?

    public init(product: OperationsProduct, isSignedIn: Bool, counts: [OperationsCount], loadError: String? = nil) {
        self.product = product
        self.isSignedIn = isSignedIn
        self.counts = counts
        self.loadError = loadError
    }
}

public struct BriefOversightInput: Sendable {
    public var repos: [OversightRepo]
    /// Changes noticed on this device, newest first.
    public var recentChanges: [OversightChange]

    public init(repos: [OversightRepo], recentChanges: [OversightChange]) {
        self.repos = repos
        self.recentChanges = recentChanges
    }
}

/// Keys & Backups as the App holds it: the registry facts plus, on the Mac, the last local check.
public struct BriefKeysInput: Sendable {
    public var check: KeysCheckInput
    /// Scan locations the app may not read (home-relative), shown as a note.
    public var notGranted: [String]

    public init(check: KeysCheckInput, notGranted: [String] = []) {
        self.check = check
        self.notGranted = notGranted
    }
}

/// Website messages as the App holds them: whether a password is stored, the last reading (in memory only) and the
/// ids the owner has seen.
public struct BriefSiteMessagesInput: Sendable {
    public var isConfigured: Bool
    public var reading: SiteMessagesReading?
    public var seenIDs: Set<Int>
    public var loadError: String?

    public init(isConfigured: Bool, reading: SiteMessagesReading?, seenIDs: Set<Int>, loadError: String? = nil) {
        self.isConfigured = isConfigured
        self.reading = reading
        self.seenIDs = seenIDs
        self.loadError = loadError
    }
}

public struct BriefInput: Sendable {
    public var now: Date
    public var monitor: MonitorSnapshot
    public var monitorTargets: [MonitorTarget]
    public var releases: ReleaseCenterSnapshot
    public var licences: BriefLicenceInput
    public var worktrack: BriefWorkTrackInput
    public var operations: [BriefOperationsInput]
    public var oversight: BriefOversightInput
    /// Nil when the Keys & Backups registry has not been loaded.
    public var keys: BriefKeysInput?
    /// Nil when the App has no Website messages model.
    public var siteMessages: BriefSiteMessagesInput?

    public init(now: Date, monitor: MonitorSnapshot, monitorTargets: [MonitorTarget] = MonitorCatalog.targets,
                releases: ReleaseCenterSnapshot, licences: BriefLicenceInput, worktrack: BriefWorkTrackInput,
                operations: [BriefOperationsInput], oversight: BriefOversightInput, keys: BriefKeysInput? = nil,
                siteMessages: BriefSiteMessagesInput? = nil) {
        self.now = now
        self.monitor = monitor
        self.monitorTargets = monitorTargets
        self.releases = releases
        self.licences = licences
        self.worktrack = worktrack
        self.operations = operations
        self.oversight = oversight
        self.keys = keys
        self.siteMessages = siteMessages
    }
}

// MARK: - Building the brief

public enum DailyBriefBuilder {
    /// The window for expiries (certificates, domains, licences, WorkTrack renewals).
    public static let expiryWindowDays = 30
    /// "Recently issued" licences.
    public static let recentDays = 7
    public static let day: TimeInterval = 86_400

    public static func build(_ input: BriefInput, changes: [BriefLine]?) -> DailyBrief {
        var sections = [
            monitor(input),
            siteMessages(input),
            releases(input),
            licences(input),
            worktrack(input),
            operations(input),
            oversight(input),
            keys(input),
        ]
        sections.append(changesSection(changes, now: input.now))
        return DailyBrief(sections: sections, generatedAt: input.now)
    }

    static func finish(_ kind: BriefSourceKind, lines: [BriefLine], readAt: Date?, source: String, notes: [String] = []) -> BriefSection {
        let sorted = lines.sorted { ($0.severity, $0.text) < ($1.severity, $1.text) }
        return BriefSection(kind: kind, state: sorted.isEmpty ? .allClear : .items, lines: sorted, readAt: readAt, source: source, notes: notes)
    }

    // MARK: Monitor

    static func monitor(_ input: BriefInput) -> BriefSection {
        let s = input.monitor
        let source = L("Monitor checks on this device (monitor.json)")
        guard let lastRound = s.lastRoundAt else {
            return BriefSection(kind: .monitor, state: .neverRead(L("Not checked yet. The Monitor checks when the app opens.")),
                                readAt: nil, source: source)
        }
        let now = input.now
        var lines: [BriefLine] = []
        for t in input.monitorTargets {
            let name = "\(t.product.title) \(L(t.name))"
            if let r = s.latest[t.id] {
                switch r.state {
                case .down:
                    lines.append(BriefLine(id: "monitor.down.\(t.id)", kind: .monitor, severity: .high,
                                           text: LF("%@ is down", name), detail: r.failure ?? r.statusCode.map { LF("HTTP %d", $0) },
                                           source: "GET \(t.url.absoluteString)", readAt: r.checkedAt, destination: .monitor))
                case .degraded:
                    lines.append(BriefLine(id: "monitor.slow.\(t.id)", kind: .monitor, severity: .normal,
                                           text: LF("%@ is slow or degraded", name), detail: r.latencyMS.map { LF("%d ms", $0) },
                                           source: "GET \(t.url.absoluteString)", readAt: r.checkedAt, destination: .monitor))
                default: break
                }
            }
            // Downtime in the last 24 hours for a target that is available now.
            let recent = s.history.recent(t.id, now: now)
            let downs = recent.filter { $0.state == .down }
            if !downs.isEmpty, s.latest[t.id]?.state != .down {
                lines.append(BriefLine(id: "monitor.downtime.\(t.id)", kind: .monitor, severity: .info,
                                       text: LF("%@ was down in %d of %d checks in the last 24 hours", name, downs.count, recent.count),
                                       detail: downs.last.map { LF("Last failure %@", $0.at.formatted(date: .omitted, time: .shortened)) },
                                       source: L("Monitor history, last 24 hours (monitor.json)"),
                                       readAt: recent.last?.at, destination: .monitor))
            }
        }
        let hosts = Set(input.monitorTargets.map(\.host))
        for reading in s.certificates.values.filter({ hosts.contains($0.host) }).sorted(by: { $0.host < $1.host }) {
            let days = reading.daysLeft(now: now)
            guard days < expiryWindowDays else { continue }
            lines.append(BriefLine(id: "monitor.cert.\(reading.host)", kind: .monitor, severity: days < 7 ? .high : .normal,
                                   text: days < 0 ? LF("The TLS certificate of %@ has expired", reading.host)
                                                  : LF("The TLS certificate of %@ ends in %d days", reading.host, days),
                                   source: LF("TLS handshake with %@", reading.host), readAt: reading.readAt, destination: .monitor))
        }
        for (name, d) in s.domains.sorted(by: { $0.key < $1.key }) {
            guard let days = d.daysLeft(now: now), days < expiryWindowDays else { continue }
            lines.append(BriefLine(id: "monitor.domain.\(name)", kind: .monitor, severity: days < 7 ? .high : .normal,
                                   text: days < 0 ? LF("The registration of %@ has expired", name)
                                                  : LF("The registration of %@ ends in %d days", name, days),
                                   source: d.sourceURL, readAt: d.fetchedAt, destination: .monitor))
        }
        let unchecked = input.monitorTargets.count { s.latest[$0.id] == nil }
        let notes = unchecked > 0 ? [LF("%d of %d endpoints have not been checked yet.", unchecked, input.monitorTargets.count)] : []
        return finish(.monitor, lines: lines, readAt: lastRound, source: source, notes: notes)
    }

    // MARK: Website messages

    static func siteMessages(_ input: BriefInput) -> BriefSection {
        let source = SiteMessagesSource.sourceText
        guard let m = input.siteMessages, m.isConfigured else {
            return BriefSection(kind: .siteMessages, state: .neverRead(L("Not connected. Add a WordPress application password in Settings → Integrations → Website messages.")),
                                readAt: nil, source: source)
        }
        guard let reading = m.reading else {
            if let error = m.loadError { return BriefSection(kind: .siteMessages, state: .unavailable(error), readAt: nil, source: source) }
            return BriefSection(kind: .siteMessages, state: .neverRead(L("Connected, not read yet. It is read when the app opens and every 30 minutes.")),
                                readAt: nil, source: source)
        }
        let new = SiteMessagesRules.new(reading.messages, seen: m.seenIDs)
        let lines = new.map { msg in
            var links = [BriefLink(title: L("Open in wp-admin"), url: msg.adminURL(), symbol: "safari")]
            if let reply = msg.replyURL { links.append(BriefLink(title: L("Reply by email"), url: reply, symbol: "arrowshape.turn.up.left")) }
            let when = msg.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? msg.createdAtText
            return BriefLine(id: "site.\(msg.id)", kind: .siteMessages, severity: .normal,
                             text: LF("Message from %@, %@", msg.sender, when),
                             detail: msg.excerpt.isEmpty ? nil : msg.excerpt,
                             source: LF("%@, entry %d", source, msg.id), readAt: reading.readAt,
                             destination: .siteMessages, links: links)
        }
        var notes: [String] = []
        if let error = m.loadError { notes.append(LF("The last refresh failed: %@", error)) }
        let seen = reading.messages.count - new.count
        if seen > 0 { notes.append(LF("%d earlier messages already marked seen.", seen)) }
        // Keep newest first rather than sorting by text.
        return BriefSection(kind: .siteMessages, state: lines.isEmpty ? .allClear : .items, lines: lines,
                            readAt: reading.readAt, source: source, notes: notes)
    }

    // MARK: Release Center

    static func releases(_ input: BriefInput) -> BriefSection {
        let s = input.releases
        let source = L("Release Center (release-center.json)")
        let times = [s.appStoreReadAt, s.playReadAt, s.gitHubReadAt].compactMap { $0 }
        guard let newest = times.max() else {
            let reasons = [s.appStoreNote, s.playNote, s.gitHubNote].compactMap { $0 }
            let why = reasons.isEmpty ? L("Not read yet. Open Releases and press Refresh.") : reasons.joined(separator: " ")
            return BriefSection(kind: .releases, state: .neverRead(why), readAt: nil, source: source)
        }
        let lines = s.waiting.map { item in
            BriefLine(id: "releases.\(item.id)", kind: .releases, severity: severity(item.severity),
                      text: "\(item.subject): \(item.title)", detail: item.detail, source: item.source,
                      readAt: item.observedAt, destination: .releaseCenter)
        }
        var notes: [String] = []
        if s.appStoreReadAt == nil { notes.append(s.appStoreNote ?? L("App Store Connect not read yet.")) }
        if s.playReadAt == nil { notes.append(s.playNote ?? L("Google Play not read yet.")) }
        if s.gitHubReadAt == nil { notes.append(s.gitHubNote ?? L("GitHub not read yet.")) }
        return finish(.releases, lines: lines, readAt: newest, source: source, notes: notes)
    }

    static func severity(_ s: WaitingItem.Severity) -> BriefSeverity {
        switch s {
        case .high: .high
        case .normal: .normal
        case .info: .info
        }
    }

    // MARK: Licences

    static func licences(_ input: BriefInput) -> BriefSection {
        let l = input.licences
        let source = l.lastSyncedAt == nil ? L("Licence ledger on this device (not synced)") : L("Licence ledger (synced with Supabase)")
        guard l.isLoaded else {
            return BriefSection(kind: .licences, state: .neverRead(L("The licence ledger has not been read yet.")), readAt: nil, source: source)
        }
        let now = input.now
        var lines: [BriefLine] = []
        for r in l.records {
            if r.isExpired(today: now) {
                lines.append(BriefLine(id: "licence.expired.\(r.licenceID)", kind: .licences, severity: .high,
                                       text: LF("%@ licence %@ for %@ has expired (%@)", r.product.displayName, r.licenceID, r.customer, r.expires ?? "?"),
                                       source: source, readAt: l.lastSyncedAt, destination: .licence(r.licenceID)))
            } else if r.isExpiring(within: expiryWindowDays, today: now), let days = r.daysUntilExpiry(today: now) {
                lines.append(BriefLine(id: "licence.expiring.\(r.licenceID)", kind: .licences, severity: days <= 7 ? .high : .normal,
                                       text: LF("%@ licence %@ for %@ ends in %d days (%@)", r.product.displayName, r.licenceID, r.customer, days, r.expires ?? "?"),
                                       source: source, readAt: l.lastSyncedAt, destination: .licence(r.licenceID)))
            }
            if r.status == .active, now.timeIntervalSince(r.createdAt) < Double(recentDays) * day, r.createdAt <= now {
                lines.append(BriefLine(id: "licence.issued.\(r.licenceID)", kind: .licences, severity: .info,
                                       text: LF("%@ licence %@ issued to %@ on %@", r.product.displayName, r.licenceID, r.customer, r.issued),
                                       detail: r.createdBy, source: source, readAt: r.createdAt, destination: .licence(r.licenceID)))
            }
        }
        let notes = l.records.isEmpty ? [L("The ledger is empty on this device.")] : []
        return finish(.licences, lines: lines, readAt: l.lastSyncedAt, source: source, notes: notes)
    }

    // MARK: WorkTrack

    static func worktrack(_ input: BriefInput) -> BriefSection {
        let w = input.worktrack
        let env = w.environment ?? "?"
        let source = LF("WorkTrack vendor API (%@), /vendor/companies", env)
        guard w.isSignedIn else {
            return BriefSection(kind: .worktrack, state: .neverRead(L("Not signed in to WorkTrack customers, so renewals are unknown.")),
                                readAt: nil, source: source)
        }
        if let error = w.loadError {
            return BriefSection(kind: .worktrack, state: .unavailable(error), readAt: nil, source: source)
        }
        guard let readAt = w.lastRead else {
            return BriefSection(kind: .worktrack, state: .neverRead(L("Signed in, but the company list has not been read yet.")),
                                readAt: nil, source: source)
        }
        let summary = WTCustomersSummary(companies: w.companies, window: expiryWindowDays)
        var lines: [BriefLine] = []
        for c in summary.expired {
            lines.append(BriefLine(id: "worktrack.expired.\(c.companyId)", kind: .worktrack, severity: .high,
                                   text: LF("%@: WorkTrack licence expired (%@)", c.name, c.license.expiresAt ?? "?"),
                                   source: source, readAt: readAt, destination: .worktrackCompany(c.companyId)))
        }
        for c in summary.expiringSoon {
            let days = c.daysUntilExpiry ?? 0
            lines.append(BriefLine(id: "worktrack.expiring.\(c.companyId)", kind: .worktrack, severity: days <= 7 ? .high : .normal,
                                   text: LF("%@: WorkTrack renewal due in %d days (%@)", c.name, days, c.license.expiresAt ?? "?"),
                                   detail: L("Days as counted by WorkTrack at the time of reading."),
                                   source: source, readAt: readAt, destination: .worktrackCompany(c.companyId)))
        }
        let notes = env == "production" ? [] : [LF("Read from the %@ environment, not production.", env)]
        return finish(.worktrack, lines: lines, readAt: readAt, source: source, notes: notes)
    }

    // MARK: Operations

    static func operations(_ input: BriefInput) -> BriefSection {
        let source = L("Operations queue counts (Talar, SafeBeauty, VELRO)")
        let signedIn = input.operations.filter(\.isSignedIn)
        guard !signedIn.isEmpty else {
            return BriefSection(kind: .operations, state: .neverRead(L("Not signed in to Talar, SafeBeauty or VELRO, so their queues are unknown.")),
                                readAt: nil, source: source)
        }
        var lines: [BriefLine] = []
        var notes: [String] = []
        var newest: Date?
        for p in input.operations {
            guard p.isSignedIn else {
                notes.append(LF("%@: not signed in, queues unknown.", p.product.title))
                continue
            }
            if let error = p.loadError, p.counts.isEmpty {
                notes.append(LF("%@: could not be read (%@).", p.product.title, error))
                continue
            }
            if p.counts.isEmpty {
                notes.append(LF("%@: queues not read yet.", p.product.title))
                continue
            }
            for c in p.counts {
                newest = max(newest ?? c.readAt, c.readAt)
                guard c.count > 0 else { continue }
                let where_ = c.isProduction ? p.product.title : "\(p.product.title) (\(c.environment))"
                lines.append(BriefLine(id: "ops.\(c.queue.rawValue)", kind: .operations, severity: c.isProduction ? .normal : .info,
                                       text: c.queue.sentence(c.count), source: LF("%@ admin, %@", where_, c.queue.title),
                                       readAt: c.readAt, destination: .operations(p.product)))
            }
        }
        return finish(.operations, lines: lines, readAt: newest, source: source, notes: notes)
    }

    // MARK: Oversight

    static func oversight(_ input: BriefInput) -> BriefSection {
        let o = input.oversight
        let source = L("Oversight sweep of GitHub (read-only)")
        let summary = OversightSummary(repos: o.repos, now: input.now)
        guard let lastScan = summary.lastScan, summary.scannedRepos > 0 else {
            return BriefSection(kind: .oversight, state: .neverRead(L("No oversight sweep yet. It needs a GitHub token.")),
                                readAt: nil, source: source)
        }
        var lines: [BriefLine] = []
        if summary.openSecurityAlerts > 0 {
            lines.append(BriefLine(id: "oversight.alerts", kind: .oversight, severity: .normal,
                                   text: LF("%d open security alerts in %d repositories", summary.openSecurityAlerts, summary.reposWithOpenAlerts),
                                   source: source, readAt: lastScan, destination: .oversight))
        }
        if summary.unprotectedDefaultBranches > 0 {
            lines.append(BriefLine(id: "oversight.unprotected", kind: .oversight, severity: .info,
                                   text: LF("%d default branches are not protected", summary.unprotectedDefaultBranches),
                                   source: source, readAt: lastScan, destination: .oversight))
        }
        if summary.reposWithUncommittedChanges > 0 {
            lines.append(BriefLine(id: "oversight.uncommitted", kind: .oversight, severity: .info,
                                   text: LF("%d local repositories have uncommitted changes", summary.reposWithUncommittedChanges),
                                   source: L("Local Git scan of the chosen folder"), readAt: lastScan, destination: .oversight))
        }
        for change in o.recentChanges where input.now.timeIntervalSince(change.detectedAt) < day {
            lines.append(BriefLine(id: "oversight.change.\(change.id.uuidString)", kind: .oversight,
                                   severity: change.isImportant ? .normal : .info, text: change.message,
                                   source: source, readAt: change.detectedAt, destination: .oversight))
        }
        return finish(.oversight, lines: lines, readAt: lastScan, source: source)
    }

    // MARK: Keys & Backups

    static func keys(_ input: BriefInput) -> BriefSection {
        let source = L("Keys & Backups registry and local file checks")
        guard let k = input.keys else {
            return BriefSection(kind: .keys, state: .neverRead(L("The Keys & Backups registry has not been loaded yet.")),
                                readAt: nil, source: source)
        }
        let lines = KeysRules.reminders(k.check).map { r in
            BriefLine(id: r.id, kind: .keys, severity: r.severity, text: r.text, detail: r.detail, source: r.source,
                      readAt: r.readAt, destination: .keys)
        }
        var notes: [String] = []
        if k.check.checkedAt == nil {
            notes.append(L("Files on this Mac have not been checked; only the registry facts are used."))
        }
        if !k.notGranted.isEmpty {
            notes.append(LF("Not granted, so not checked: %@.", k.notGranted.joined(separator: ", ")))
        }
        return finish(.keys, lines: lines, readAt: k.check.checkedAt, source: source, notes: notes)
    }

    // MARK: Changes

    static func changesSection(_ changes: [BriefLine]?, now: Date) -> BriefSection {
        let source = L("Daily snapshots on this device (brief-snapshots.json)")
        guard let changes else {
            return BriefSection(kind: .changes, state: .neverRead(L("No snapshot from an earlier day yet. Changes show from tomorrow.")),
                                readAt: nil, source: source)
        }
        // Keep the order the diff produced (grouped by area).
        return BriefSection(kind: .changes, state: changes.isEmpty ? .allClear : .items, lines: changes, readAt: now, source: source)
    }
}

// MARK: - Notification wording

public enum BriefNotificationText {
    /// Title and body of the morning notification. `asOf` is the formatted time the brief was built.
    public static func content(_ brief: DailyBrief, asOf: String) -> (title: String, body: String) {
        let attention = brief.attention
        var parts: [String] = []
        if attention.isEmpty {
            parts.append(L("Nothing needs you in what was last read."))
        } else {
            let top = attention.prefix(3).map(\.text).joined(separator: "; ")
            parts.append(attention.count == 1 ? top : LF("%d items need you: %@", attention.count, top))
        }
        let never = brief.neverRead.filter { $0 != .changes }
        if !never.isEmpty {
            parts.append(LF("Not read: %@.", never.map(\.title).joined(separator: ", ")))
        }
        parts.append(LF("As of %@.", asOf))
        return (L("Daily Brief"), parts.joined(separator: " "))
    }
}

/// When the morning notification fires.
public enum BriefSchedule {
    public static let defaultHour = 8
    public static let defaultMinute = 0

    /// The next time at `hour:minute` strictly after `now`, in `calendar`'s time zone.
    public static func nextFire(after now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        c.second = 0
        let today = calendar.date(from: c) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }
}
