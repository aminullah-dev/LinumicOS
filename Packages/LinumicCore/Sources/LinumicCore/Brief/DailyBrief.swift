import Foundation

// MARK: - Daily Brief (گزارش روز)
//
// One page that summarises what the app has ALREADY read: Monitor, Release Center, the licence ledger, WorkTrack
// customers, Operations queues, Money, Sales and Oversight, plus what changed since yesterday. Nothing here makes a request; the
// App layer collects each model's state into `BriefInput` and renders `DailyBrief`. Every line carries its source and
// the time it was read. A source that was never read says so instead of showing zero.

/// Where a line or section comes from. The order is the order of the sections on screen.
public enum BriefSourceKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case monitor, siteMessages, releases, licences, worktrack, operations, money, sales, oversight, keys, obligations, automation, changes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monitor: L("Monitor")
        case .siteMessages: L("Website messages")
        case .releases: L("Releases")
        case .licences: L("Licences")
        case .worktrack: L("WorkTrack customers")
        case .operations: L("Operations")
        case .money: L("Money")
        case .sales: L("Sales")
        case .oversight: L("Oversight")
        case .keys: L("Keys & Backups")
        case .obligations: L("Obligations")
        case .automation: L("Automation")
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
        case .money: "banknote"
        case .sales: "phone.arrow.up.right"
        case .oversight: "scope"
        case .keys: "externaldrive.badge.checkmark"
        case .obligations: "calendar.badge.exclamationmark"
        case .automation: "gearshape.2"
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
    case automation
    /// The Obligations & accounts screen.
    case obligations
    /// One obligation on that screen.
    case obligation(String)
    /// The Continuity screen (the encrypted export).
    case continuity
    /// The Money screen.
    case money
    /// The Sales screen, with one row to show (a `SalesKey`), or none.
    case sales(String?)
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
    /// The product the line is about, as its source names it ("WorkTrack", an app name, a repository), when it is known.
    /// The Desk groups by it; nil when the line is about several products or none.
    public var product: String?
    /// What else makes the fact, beside the line's id and severity: a coarse bucket of a count ("3 halls waiting"), so
    /// that a "Waiting on others" mark on 3 does not hide 30. Nil for a line whose id says it all.
    public var factKey: String?
    /// The day it is due, when the source gives one (an obligation). The Desk puts it in Today, This week or Later by it.
    public var due: KeyDay?
    /// Today or this week by the source's own day rule, when that rule is not this device's calendar (a WorkTrack follow-up
    /// is due by Kabul's day): the Desk puts the line there without comparing a day of its own. Not part of the fact.
    public var horizon: DeskHorizon?
    /// The obligation the line is about, when it is one. Its Done is recorded on the Obligations screen, with evidence,
    /// unless `closesAtSource`.
    public var obligationID: String?
    /// A live obligation (the continuity export, a restore test, a licence, a domain): it closes only when its source
    /// records it, so its Done goes to that source's screen, never to the evidence sheet or a Desk mark.
    public var closesAtSource: Bool

    public init(id: String, kind: BriefSourceKind, severity: BriefSeverity, text: String, detail: String? = nil,
                source: String, readAt: Date?, destination: BriefDestination, links: [BriefLink] = [], product: String? = nil,
                factKey: String? = nil, due: KeyDay? = nil, horizon: DeskHorizon? = nil, obligationID: String? = nil,
                closesAtSource: Bool = false) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.text = text
        self.detail = detail
        self.source = source
        self.readAt = readAt
        self.destination = destination
        self.links = links
        self.product = product
        self.factKey = factKey
        self.due = due
        self.horizon = horizon
        self.obligationID = obligationID
        self.closesAtSource = closesAtSource
    }

    /// A count's power-of-two bucket ("1", "2-3", "4-7", "8-15", …): a queue that grows from 3 to 4 or to 30 is a new
    /// fact for the Desk, one that moves between 2 and 3 is not.
    public static func countBucket(_ n: Int) -> String {
        guard n > 1 else { return n <= 0 ? "0" : "1" }
        var low = 1
        while low * 2 <= n { low *= 2 }
        return "\(low)-\(low * 2 - 1)"
    }
}

/// A part of a section's source that was not read this time: a product not signed in, a store without a key, endpoints
/// not checked yet. The section can still be "all clear" for what was read; for this part nothing is known. Or a caveat
/// on a part that was read (not production, a limit reached, no TEST mark): its figures are shown, with this beside them.
public struct BriefGap: Hashable, Sendable {
    /// Stable within its section ("safeBeauty", "appStore", "unchecked"), so a mark on it follows it between readings.
    public var key: String
    /// The sentence, as shown among the section's notes.
    public var text: String
    /// The product the part belongs to, as its source names it, when it is one.
    public var product: String?
    /// A caveat on a part that was read, not a part that was not read: its Desk item does not say "unknown, not zero".
    public var isCaveat: Bool
    /// False when another section already raises the same Desk item (Money's 2000-account limit, the WorkTrack
    /// environment): the sentence is among the notes and still keeps marks on the part's lines, but makes no second item.
    public var isDeskItem: Bool

    public init(key: String, text: String, product: String? = nil, isCaveat: Bool = false, isDeskItem: Bool = true) {
        self.key = key
        self.text = text
        self.product = product
        self.isCaveat = isCaveat
        self.isDeskItem = isDeskItem
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
    /// What is worth saying beside the lines: the gaps' sentences first, then information ("3 earlier messages seen").
    public var notes: [String]
    /// Parts of the source that were not read this time, and caveats on parts that were (also among `notes`). Lines of
    /// the parts not read may be missing.
    public var gaps: [BriefGap]

    public var id: String { kind.rawValue }

    /// `notes` are information only; the gaps' sentences are put before them.
    public init(kind: BriefSourceKind, state: State, lines: [BriefLine] = [], readAt: Date?, source: String, notes: [String] = [],
                gaps: [BriefGap] = []) {
        self.kind = kind
        self.state = state
        self.lines = lines
        self.readAt = readAt
        self.source = source
        self.notes = gaps.map(\.text) + notes
        self.gaps = gaps
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
    /// The automation engine's run ledger; nil before the engine has loaded it.
    public var automation: AutomationLedger?
    /// What `Backups/` holds, read from the disk; nil before it was checked.
    public var backup: BackupFolderStatus?
    /// The obligations register; nil before it was built.
    public var obligations: BriefObligationsInput?
    /// Money as the App collected it; nil when it was not collected.
    public var money: MoneyInput?

    public init(now: Date, monitor: MonitorSnapshot, monitorTargets: [MonitorTarget] = MonitorCatalog.targets,
                releases: ReleaseCenterSnapshot, licences: BriefLicenceInput, worktrack: BriefWorkTrackInput,
                operations: [BriefOperationsInput], oversight: BriefOversightInput, keys: BriefKeysInput? = nil,
                siteMessages: BriefSiteMessagesInput? = nil, automation: AutomationLedger? = nil,
                backup: BackupFolderStatus? = nil, obligations: BriefObligationsInput? = nil, money: MoneyInput? = nil) {
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
        self.automation = automation
        self.backup = backup
        self.obligations = obligations
        self.money = money
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
            money(input),
            sales(input),
            oversight(input),
            keys(input),
            obligations(input),
            automation(input),
        ]
        sections.append(changesSection(changes, now: input.now))
        return DailyBrief(sections: sections, generatedAt: input.now)
    }

    static func finish(_ kind: BriefSourceKind, lines: [BriefLine], readAt: Date?, source: String, gaps: [BriefGap] = []) -> BriefSection {
        let sorted = lines.sorted { ($0.severity, $0.text) < ($1.severity, $1.text) }
        return BriefSection(kind: kind, state: sorted.isEmpty ? .allClear : .items, lines: sorted, readAt: readAt, source: source, gaps: gaps)
    }

    // MARK: Automation

    /// Jobs whose last run failed (high after three in a row), what `Backups/` really holds (never the run log alone),
    /// and, as notes, jobs this device can't run.
    static func automation(_ input: BriefInput) -> BriefSection {
        let source = L("Automation run log on this device (automation.json)")
        let now = input.now
        guard let ledger = input.automation, let last = AutomationHealth(ledger: ledger).lastRunAt else {
            return BriefSection(kind: .automation, state: .neverRead(L("No automatic run yet.")), readAt: nil, source: source)
        }
        let health = AutomationHealth(ledger: ledger)
        var lines = health.failing.map { f in
            let spec = AutomationCatalog.spec(f.job)
            return BriefLine(id: "automation.\(f.job.rawValue)", kind: .automation,
                             severity: f.count >= AutomationHealth.failingAfter ? .high : .normal,
                             text: LF("%@ failed %d times in a row", L(spec.title), f.count), detail: f.message,
                             source: source, readAt: ledger.states[f.job]?.lastRun?.finishedAt, destination: .automation,
                             product: "Linumic OS")
        }
        lines += BackupRules.lines(input.backup, state: ledger.states[.backup], now: now, jobOff: ledger.disabled.contains(.backup),
                                   pausedUntil: ledger.pausedUntil)
        var gaps: [BriefGap] = []
        // The log says the backup ran, but the folder was not looked at: the log alone never stands for a copy.
        if input.backup == nil, ledger.states[.backup]?.lastRun != nil {
            gaps.append(BriefGap(key: "backupFolder", text: L("The backup job ran, but Backups/ has not been checked yet, so whether a copy is there is unknown."),
                                 product: "Linumic OS"))
        }
        if !health.notConnected.isEmpty {
            gaps.append(BriefGap(key: "notConnected", text: LF("Not connected on this device: %@.", health.notConnected.map { L(AutomationCatalog.spec($0).title) }.joined(separator: ", "))))
        }
        if ledger.disabled.count > 0 {
            gaps.append(BriefGap(key: "turnedOff", text: LF("Turned off: %@.", AutomationCatalog.jobs.filter { ledger.disabled.contains($0.id) }.map { L($0.title) }.joined(separator: ", "))))
        }
        if ledger.pausedUntil.map({ $0 > now }) == true {
            gaps.append(BriefGap(key: "paused", text: LF("Paused until %@.", ledger.pausedUntil!.formatted(date: .omitted, time: .shortened))))
        }
        return finish(.automation, lines: lines, readAt: last, source: source, gaps: gaps)
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
                                           source: "GET \(t.url.absoluteString)", readAt: r.checkedAt, destination: .monitor,
                                           product: t.product.title))
                case .degraded:
                    lines.append(BriefLine(id: "monitor.slow.\(t.id)", kind: .monitor, severity: .normal,
                                           text: LF("%@ is slow or degraded", name), detail: r.latencyMS.map { LF("%d ms", $0) },
                                           source: "GET \(t.url.absoluteString)", readAt: r.checkedAt, destination: .monitor,
                                           product: t.product.title))
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
                                       readAt: recent.last?.at, destination: .monitor, product: t.product.title,
                                       factKey: BriefLine.countBucket(downs.count)))
            }
        }
        let hosts = Set(input.monitorTargets.map(\.host))
        for reading in s.certificates.values.filter({ hosts.contains($0.host) }).sorted(by: { $0.host < $1.host }) {
            let days = reading.daysLeft(now: now)
            guard days < expiryWindowDays else { continue }
            lines.append(BriefLine(id: "monitor.cert.\(reading.host)", kind: .monitor, severity: days < 7 ? .high : .normal,
                                   text: days < 0 ? LF("The TLS certificate of %@ has expired", reading.host)
                                                  : LF("The TLS certificate of %@ ends in %d days", reading.host, days),
                                   source: LF("TLS handshake with %@", reading.host), readAt: reading.readAt, destination: .monitor,
                                   product: input.monitorTargets.first { $0.host == reading.host }?.product.title))
        }
        for (name, d) in s.domains.sorted(by: { $0.key < $1.key }) {
            guard let days = d.daysLeft(now: now), days < expiryWindowDays else { continue }
            lines.append(BriefLine(id: "monitor.domain.\(name)", kind: .monitor, severity: days < 7 ? .high : .normal,
                                   text: days < 0 ? LF("The registration of %@ has expired", name)
                                                  : LF("The registration of %@ ends in %d days", name, days),
                                   source: d.sourceURL, readAt: d.fetchedAt, destination: .monitor,
                                   product: input.monitorTargets.first { $0.host == name }?.product.title))
        }
        let unchecked = input.monitorTargets.count { s.latest[$0.id] == nil }
        let gaps = unchecked > 0 ? [BriefGap(key: "unchecked", text: LF("%d of %d endpoints have not been checked yet.", unchecked, input.monitorTargets.count))] : []
        return finish(.monitor, lines: lines, readAt: lastRound, source: source, gaps: gaps)
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
                             destination: .siteMessages, links: links, product: MonitorProduct.website.title)
        }
        let gaps = m.loadError.map { [BriefGap(key: "refresh", text: LF("The last refresh failed: %@", $0), product: MonitorProduct.website.title)] } ?? []
        var notes: [String] = []
        let seen = reading.messages.count - new.count
        if seen > 0 { notes.append(LF("%d earlier messages already marked seen.", seen)) }
        // Keep newest first rather than sorting by text.
        return BriefSection(kind: .siteMessages, state: lines.isEmpty ? .allClear : .items, lines: lines,
                            readAt: reading.readAt, source: source, notes: notes, gaps: gaps)
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
                      readAt: item.observedAt, destination: .releaseCenter, product: item.subject)
        }
        var gaps: [BriefGap] = []
        if s.appStoreReadAt == nil { gaps.append(BriefGap(key: "appStore", text: s.appStoreNote ?? L("App Store Connect not read yet."))) }
        if s.playReadAt == nil { gaps.append(BriefGap(key: "play", text: s.playNote ?? L("Google Play not read yet."))) }
        if s.gitHubReadAt == nil { gaps.append(BriefGap(key: "gitHub", text: s.gitHubNote ?? L("GitHub not read yet."))) }
        return finish(.releases, lines: lines, readAt: newest, source: source, gaps: gaps)
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
                                       source: source, readAt: l.lastSyncedAt, destination: .licence(r.licenceID),
                                       product: r.product.displayName))
            } else if r.isExpiring(within: expiryWindowDays, today: now), let days = r.daysUntilExpiry(today: now) {
                lines.append(BriefLine(id: "licence.expiring.\(r.licenceID)", kind: .licences, severity: days <= 7 ? .high : .normal,
                                       text: LF("%@ licence %@ for %@ ends in %d days (%@)", r.product.displayName, r.licenceID, r.customer, days, r.expires ?? "?"),
                                       source: source, readAt: l.lastSyncedAt, destination: .licence(r.licenceID),
                                       product: r.product.displayName))
            }
            if r.status == .active, now.timeIntervalSince(r.createdAt) < Double(recentDays) * day, r.createdAt <= now {
                lines.append(BriefLine(id: "licence.issued.\(r.licenceID)", kind: .licences, severity: .info,
                                       text: LF("%@ licence %@ issued to %@ on %@", r.product.displayName, r.licenceID, r.customer, r.issued),
                                       // The read time is the ledger's, not the licence's creation (that is in the text).
                                       detail: r.createdBy, source: source, readAt: l.lastSyncedAt, destination: .licence(r.licenceID),
                                       product: r.product.displayName))
            }
        }
        // Empty and never synced: whether licences exist elsewhere is unknown, a part not read. Empty after a sync with
        // the cloud: read, and none there (a note, not a gap).
        let gaps = l.records.isEmpty && l.lastSyncedAt == nil
            ? [BriefGap(key: "empty", text: L("The ledger is empty on this device and has never been synced, so whether licences exist elsewhere is unknown."))]
            : []
        let notes = l.records.isEmpty && l.lastSyncedAt != nil ? [L("The ledger is empty, also in the cloud.")] : []
        let section = finish(.licences, lines: lines, readAt: l.lastSyncedAt, source: source, gaps: gaps)
        return BriefSection(kind: .licences, state: section.state, lines: section.lines, readAt: section.readAt, source: source,
                            notes: notes, gaps: gaps)
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
                                   source: source, readAt: readAt, destination: .worktrackCompany(c.companyId),
                                   product: MonitorProduct.workTrack.title))
        }
        for c in summary.expiringSoon {
            let days = c.daysUntilExpiry ?? 0
            lines.append(BriefLine(id: "worktrack.expiring.\(c.companyId)", kind: .worktrack, severity: days <= 7 ? .high : .normal,
                                   text: LF("%@: WorkTrack renewal due in %d days (%@)", c.name, days, c.license.expiresAt ?? "?"),
                                   detail: L("Days as counted by WorkTrack at the time of reading."),
                                   source: source, readAt: readAt, destination: .worktrackCompany(c.companyId),
                                   product: MonitorProduct.workTrack.title))
        }
        let gaps = env == "production" ? [] : [BriefGap(key: "production", text: LF("Read from the %@ environment, not production.", env),
                                                         product: MonitorProduct.workTrack.title, isCaveat: true)]
        return finish(.worktrack, lines: lines, readAt: readAt, source: source, gaps: gaps)
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
        var gaps: [BriefGap] = []
        var newest: Date?
        for p in input.operations {
            // The key is the product's raw value, so the Desk knows which queues were not read.
            func gap(_ text: String) { gaps.append(BriefGap(key: p.product.rawValue, text: text, product: p.product.title)) }
            guard p.isSignedIn else {
                gap(LF("%@: not signed in, queues unknown.", p.product.title))
                continue
            }
            if let error = p.loadError, p.counts.isEmpty {
                gap(LF("%@: could not be read (%@).", p.product.title, error))
                continue
            }
            if p.counts.isEmpty {
                gap(LF("%@: queues not read yet.", p.product.title))
                continue
            }
            for c in p.counts {
                newest = max(newest ?? c.readAt, c.readAt)
                guard c.count > 0 else { continue }
                let where_ = c.isProduction ? p.product.title : "\(p.product.title) (\(c.environment))"
                lines.append(BriefLine(id: "ops.\(c.queue.rawValue)", kind: .operations, severity: c.isProduction ? .normal : .info,
                                       text: c.queue.sentence(c.count), source: LF("%@ admin, %@", where_, c.queue.title),
                                       readAt: c.readAt, destination: .operations(p.product), product: p.product.title,
                                       factKey: BriefLine.countBucket(c.count)))
            }
        }
        return finish(.operations, lines: lines, readAt: newest, source: source, gaps: gaps)
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
                                   source: source, readAt: lastScan, destination: .oversight,
                                   factKey: BriefLine.countBucket(summary.openSecurityAlerts)))
        }
        if summary.unprotectedDefaultBranches > 0 {
            lines.append(BriefLine(id: "oversight.unprotected", kind: .oversight, severity: .info,
                                   text: LF("%d default branches are not protected", summary.unprotectedDefaultBranches),
                                   source: source, readAt: lastScan, destination: .oversight,
                                   factKey: BriefLine.countBucket(summary.unprotectedDefaultBranches)))
        }
        if summary.reposWithUncommittedChanges > 0 {
            lines.append(BriefLine(id: "oversight.uncommitted", kind: .oversight, severity: .info,
                                   text: LF("%d local repositories have uncommitted changes", summary.reposWithUncommittedChanges),
                                   source: L("Local Git scan of the chosen folder"), readAt: lastScan, destination: .oversight,
                                   factKey: BriefLine.countBucket(summary.reposWithUncommittedChanges)))
        }
        for change in o.recentChanges where input.now.timeIntervalSince(change.detectedAt) < day {
            lines.append(BriefLine(id: "oversight.change.\(change.id.uuidString)", kind: .oversight,
                                   severity: change.isImportant ? .normal : .info, text: change.message,
                                   source: source, readAt: change.detectedAt, destination: .oversight))
        }
        // Repositories the sweep has not reached are unknown, not clean.
        let gaps = summary.neverScanned > 0
            ? [BriefGap(key: "neverScanned", text: LF("%d of %d repositories not scanned yet.", summary.neverScanned, summary.totalRepos))]
            : []
        return finish(.oversight, lines: lines, readAt: lastScan, source: source, gaps: gaps)
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
                      readAt: r.readAt, destination: .keys,
                      product: r.keyID.flatMap { id in k.check.registry.keys.first { $0.id == id }?.product })
        }
        var gaps: [BriefGap] = []
        if k.check.checkedAt == nil {
            gaps.append(BriefGap(key: "files", text: L("Files on this Mac have not been checked; only the registry facts are used.")))
        }
        if !k.notGranted.isEmpty {
            gaps.append(BriefGap(key: "notGranted", text: LF("Not granted, so not checked: %@.", k.notGranted.joined(separator: ", "))))
        }
        return finish(.keys, lines: lines, readAt: k.check.checkedAt, source: source, gaps: gaps)
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
            let top = texts(attention).prefix(3).joined(separator: "; ")
            parts.append(attention.count == 1 ? top : LF("%d items need you: %@", attention.count, top))
        }
        let never = brief.neverRead.filter { $0 != .changes }
        if !never.isEmpty {
            parts.append(LF("Not read: %@.", never.map(\.title).joined(separator: ", ")))
        }
        parts.append(LF("As of %@.", asOf))
        return (L("Daily Brief"), parts.joined(separator: " "))
    }

    /// The lines' texts, with every Sales line folded into counts where the first one was: a Sales line names a customer,
    /// and the lock screen shows no customer name. Follow-ups due today or overdue by Kabul's day are counted as such; any
    /// other Sales line (a next-action date that could not be read, accounts with no next step, a new signup) is counted
    /// apart, never called a follow-up.
    static func texts(_ attention: [BriefLine]) -> [String] {
        let sales = attention.filter { $0.kind == .sales }
        guard !sales.isEmpty else { return attention.map(\.text) }
        let due = sales.count { SalesBrief.isFollowUpDue($0) }
        let others = sales.count - due
        var phrases: [String] = []
        if due > 0 { phrases.append(LF("%d WorkTrack follow-ups are due", due)) }
        if others > 0 { phrases.append(due > 0 ? LF("%d other Sales items need you", others) : LF("%d Sales items need you", others)) }
        var out: [String] = []
        var folded = false
        for line in attention {
            guard line.kind == .sales else { out.append(line.text); continue }
            if !folded { out += phrases; folded = true }
        }
        return out
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
