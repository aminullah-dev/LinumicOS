import Foundation

// MARK: - The owner's entries (obligations.json, this device)

/// A due date the owner set for a row whose date was unknown (or corrected), with where it came from.
public struct ObligationDateEntry: Codable, Hashable, Sendable {
    public var obligationID: String
    public var due: KeyDay
    public var source: String
    public var enteredAt: Date

    public init(obligationID: String, due: KeyDay, source: String, enteredAt: Date) {
        self.obligationID = obligationID
        self.due = due
        self.source = source
        self.enteredAt = enteredAt
    }
}

/// What the owner recorded about an account: its renewal and whose name it is in, each with a source.
public struct VendorAccountEdit: Codable, Hashable, Sendable {
    public var accountID: String
    public var renewal: KeyDay?
    public var renewalSource: String?
    public var holder: AccountHolder?
    public var holderSource: String?
    public var enteredAt: Date

    public init(accountID: String, renewal: KeyDay? = nil, renewalSource: String? = nil, holder: AccountHolder? = nil,
                holderSource: String? = nil, enteredAt: Date) {
        self.accountID = accountID
        self.renewal = renewal
        self.renewalSource = renewalSource
        self.holder = holder
        self.holderSource = holderSource
        self.enteredAt = enteredAt
    }
}

/// Everything the owner entered: obligations and accounts he added, dates he set, Done with evidence, account facts.
/// The seed and the live rows are never stored here; they are built fresh from their sources.
public struct ObligationsFile: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var added: [Obligation]
    public var dates: [ObligationDateEntry]
    public var completions: [ObligationCompletion]
    public var accounts: [VendorAccount]
    public var accountEdits: [VendorAccountEdit]

    public init(added: [Obligation] = [], dates: [ObligationDateEntry] = [], completions: [ObligationCompletion] = [],
                accounts: [VendorAccount] = [], accountEdits: [VendorAccountEdit] = []) {
        version = Self.currentVersion
        self.added = added
        self.dates = dates
        self.completions = completions
        self.accounts = accounts
        self.accountEdits = accountEdits
    }

    static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    // MARK: Changes (each refused without its source or evidence)

    /// Adds an obligation the owner wrote. The id is made from the title and the time, so it never clashes with a seed.
    @discardableResult
    public mutating func add(title: String, product: String?, area: ObligationArea, due: KeyDay?, consequence: String?,
                             source: String, now: Date, calendar: Calendar = KeyDay.calendar) throws -> Obligation {
        guard let title = Self.clean(title) else { throw ObligationError.missingTitle }
        guard let source = Self.clean(source) else { throw ObligationError.missingSource }
        let id = "owner.\(DeskHash.of(title, "\(now.timeIntervalSinceReferenceDate)"))"
        guard !added.contains(where: { $0.id == id }) else { throw ObligationError.duplicateID(id) }
        let o = Obligation(id: id, title: title, product: Self.clean(product), area: area, due: due,
                           consequence: Self.clean(consequence), source: source, recordedOn: KeyDay(now, calendar: calendar),
                           origin: .owner)
        added.append(o)
        return o
    }

    /// Sets (or corrects) the due day of a row, with where the date comes from. Live rows take their date from their
    /// own source and can't be set here.
    public mutating func setDate(_ obligationID: String, due: KeyDay, source: String, now: Date) throws {
        guard let source = Self.clean(source) else { throw ObligationError.missingSource }
        dates.removeAll { $0.obligationID == obligationID }
        dates.append(ObligationDateEntry(obligationID: obligationID, due: due, source: source, enteredAt: now))
    }

    /// Records Done for one due day of an obligation, with what proves it.
    public mutating func complete(_ obligationID: String, due: KeyDay?, on day: KeyDay, evidence: String, now: Date,
                                  calendar: Calendar = KeyDay.calendar) throws {
        guard let evidence = Self.clean(evidence) else { throw ObligationError.missingEvidence }
        guard day <= KeyDay(now, calendar: calendar) else { throw ObligationError.futureDay }
        completions.removeAll { $0.obligationID == obligationID && $0.due == due }
        completions.append(ObligationCompletion(obligationID: obligationID, due: due, on: day, evidence: evidence, enteredAt: now))
    }

    /// Takes a Done back (it was pressed by mistake).
    public mutating func reopen(_ obligationID: String, due: KeyDay?) {
        completions.removeAll { $0.obligationID == obligationID && $0.due == due }
    }

    @discardableResult
    public mutating func addAccount(name: String, purpose: String, holder: AccountHolder?, source: String, now: Date,
                                    calendar: Calendar = KeyDay.calendar) throws -> VendorAccount {
        guard let name = Self.clean(name) else { throw ObligationError.missingTitle }
        guard let source = Self.clean(source) else { throw ObligationError.missingSource }
        let id = "owner.\(DeskHash.of(name, "\(now.timeIntervalSinceReferenceDate)"))"
        let a = VendorAccount(id: id, name: name, purpose: Self.clean(purpose) ?? "", holder: holder,
                              holderSource: holder == nil ? nil : source, source: source,
                              recordedOn: KeyDay(now, calendar: calendar), origin: .owner)
        accounts.append(a)
        return a
    }

    /// Records an account's renewal day, whose name it is in, or both; each needs a source.
    public mutating func editAccount(_ accountID: String, renewal: KeyDay?, renewalSource: String?, holder: AccountHolder?,
                                     holderSource: String?, now: Date) throws {
        if renewal != nil, Self.clean(renewalSource) == nil { throw ObligationError.missingSource }
        if holder != nil, Self.clean(holderSource) == nil { throw ObligationError.missingSource }
        guard renewal != nil || holder != nil else { return }
        accountEdits.append(VendorAccountEdit(accountID: accountID, renewal: renewal, renewalSource: Self.clean(renewalSource),
                                              holder: holder, holderSource: Self.clean(holderSource), enteredAt: now))
    }
}

/// `obligations.json` next to the inventory. Like `desk-state.json`: a file that can't be read is reported and never
/// overwritten.
public struct ObligationsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "obligations.json")
    }

    public enum LoadResult: Sendable {
        case empty
        case loaded(ObligationsFile)
        case unreadable(String)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .empty }
        do {
            return .loaded(try InventoryCoding.decoder().decode(ObligationsFile.self, from: Data(contentsOf: fileURL)))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func save(_ file: ObligationsFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(file).write(to: fileURL, options: [.atomic])
    }
}

// MARK: - Live inputs

/// What the app already read that holds dates: plain values the App collects from its models.
public struct ObligationLiveInput: Sendable {
    public var monitor: MonitorSnapshot?
    /// Hosts the Monitor checks (certificates of other hosts are left out).
    public var monitorHosts: Set<String>
    /// The licence ledger; nil when it was not loaded.
    public var licences: [LicenceRecord]?
    public var licencesReadAt: Date?
    public var licencesSynced: Bool
    /// The Keys & Backups registry; nil when it was not loaded.
    public var keys: KeysRegistry?
    /// The continuity export log; nil when it was not loaded (iPhone and iPad have none).
    public var continuity: ContinuityLog?

    public init(monitor: MonitorSnapshot? = nil, monitorHosts: Set<String> = [], licences: [LicenceRecord]? = nil,
                licencesReadAt: Date? = nil, licencesSynced: Bool = false, keys: KeysRegistry? = nil, continuity: ContinuityLog? = nil) {
        self.monitor = monitor
        self.monitorHosts = monitorHosts
        self.licences = licences
        self.licencesReadAt = licencesReadAt
        self.licencesSynced = licencesSynced
        self.keys = keys
        self.continuity = continuity
    }
}

/// A live source the register reads dates from. One that was not read leaves its rows out, which the Brief says.
public enum ObligationLiveSource: String, CaseIterable, Sendable, Hashable {
    case monitor, licences, keys, continuity

    /// The sentence for a source not read (a part of the Obligations section that is unknown, not empty).
    public var notReadText: String {
        switch self {
        case .monitor: L("The Monitor has not read the domain and TLS dates yet; the seed's linumic.com date is used until it does.")
        case .licences: L("The licence ledger has not been read yet, so licence end dates are not here.")
        case .keys: L("The Keys & Backups registry has not been loaded yet, so restore-test dates are not here.")
        case .continuity: L("The continuity export log is kept on the Mac, so the encrypted export's date is not known here.")
        }
    }
}

// MARK: - Timing

/// Where an obligation stands today.
public enum ObligationTiming: Hashable, Sendable {
    case closed(ObligationCompletion)
    case dateUnknown
    /// Past its day by this many days.
    case overdue(Int)
    /// Due in this many days (0 is today); `lead` is the alert window it is in (30, 14, 7 or 1), nil beyond them all.
    case due(Int, lead: Int?)
}

/// The lists of the Obligations screen.
public enum ObligationLane: String, CaseIterable, Sendable, Identifiable {
    case overdue, week, month, later, dateUnknown, closed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overdue: L("Overdue")
        case .week: L("Within 7 days")
        case .month: L("Within 30 days")
        case .later: L("Later")
        case .dateUnknown: L("Date unknown")
        case .closed: L("Done")
        }
    }
}

public enum ObligationRules {
    /// The alert window a due day is in: the smallest lead day at or above the days left (30, 14, 7, 1); 0 on the day
    /// itself or after it; nil before the widest window.
    public static func lead(daysLeft: Int, leadDays: [Int]) -> Int? {
        if daysLeft <= 0 { return 0 }
        return leadDays.sorted().first { daysLeft <= $0 }
    }

    public static func timing(_ o: Obligation, today: KeyDay) -> ObligationTiming {
        if let c = o.completion { return .closed(c) }
        guard let due = o.due else { return .dateUnknown }
        let left = today.days(until: due)
        if left < 0 { return .overdue(-left) }
        return .due(left, lead: lead(daysLeft: left, leadDays: o.leadDays))
    }

    public static func lane(_ o: Obligation, today: KeyDay) -> ObligationLane {
        switch timing(o, today: today) {
        case .closed: .closed
        case .dateUnknown: .dateUnknown
        case .overdue: .overdue
        case .due(let left, _): left <= 7 ? .week : (left <= 30 ? .month : .later)
        }
    }

    /// Overdue or due within a day: high. In the 7- or 14-day window: normal (the Desk's This week). In the 30-day
    /// window, beyond it, or with no date: for information (the Desk's Later).
    public static func severity(_ o: Obligation, today: KeyDay) -> BriefSeverity {
        switch timing(o, today: today) {
        case .overdue: return .high
        case .due(_, let lead):
            switch lead {
            case 0?, 1?: return .high
            case 7?, 14?: return .normal
            default: return .info
            }
        case .closed, .dateUnknown: return .info
        }
    }
}

// MARK: - The register

public struct ObligationsRegister: Hashable, Sendable {
    /// Every obligation (seed, the owner's, accounts' renewals and live rows), with its Done attached, by due day.
    public var obligations: [Obligation]
    public var accounts: [VendorAccount]
    /// What `validate` refuses; shown, never hidden.
    public var issues: [ObligationIssue]
    public var builtAt: Date
    /// Live sources that were not read, so their rows are missing (unknown, not none).
    public var unread: [ObligationLiveSource] = []

    public func obligation(_ id: String) -> Obligation? { obligations.first { $0.id == id } }

    public func lanes(today: KeyDay) -> [ObligationLane: [Obligation]] {
        Dictionary(grouping: obligations) { ObligationRules.lane($0, today: today) }
    }
}

public enum ObligationsBuilder {
    /// A verified export older than this is due again.
    public static let exportEveryDays = 30

    public static func build(file: ObligationsFile, live: ObligationLiveInput, now: Date, calendar: Calendar = KeyDay.calendar,
                             seed: [Obligation] = ObligationSeed.obligations,
                             seedAccounts: [VendorAccount] = ObligationSeed.accounts) -> ObligationsRegister {
        // Accounts: the seed and the owner's, with the owner's latest facts on top.
        var accounts = seedAccounts + file.accounts
        for edit in file.accountEdits.sorted(by: { $0.enteredAt < $1.enteredAt }) {
            guard let i = accounts.firstIndex(where: { $0.id == edit.accountID }) else { continue }
            // A value without its source is not applied (and validate() reports it).
            if let r = edit.renewal, let source = ObligationsFile.clean(edit.renewalSource) {
                accounts[i].renewal = r
                accounts[i].renewalSource = source
            }
            if let h = edit.holder, let source = ObligationsFile.clean(edit.holderSource) {
                accounts[i].holder = h
                accounts[i].holderSource = source
            }
        }

        var rows = seed + file.added + accounts.map(renewal) + derived(live, calendar: calendar)
        // A live row replaces a seed row with the same id (the Monitor's reading of linumic.com replaces the docs').
        let liveIDs = Set(rows.filter(\.origin.isLive).map(\.id))
        rows.removeAll { $0.origin == .seed && liveIDs.contains($0.id) }

        // The owner's dates, then Done for the due day each row has now. A date without a source or a Done without
        // evidence is not applied: validate() reports it, and the row stays as its source says.
        let validDates = file.dates.filter { ObligationsFile.clean($0.source) != nil }
        let validDone = file.completions.filter { ObligationsFile.clean($0.evidence) != nil }
        let dates = Dictionary(validDates.map { ($0.obligationID, $0) }, uniquingKeysWith: { a, b in a.enteredAt >= b.enteredAt ? a : b })
        for i in rows.indices {
            if !rows[i].origin.isLive, let d = dates[rows[i].id] {
                rows[i].due = d.due
                rows[i].dueSource = d.source
            }
            rows[i].completion = validDone.last { $0.obligationID == rows[i].id && $0.due == rows[i].due }
        }

        rows.sort { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.id < b.id
            }
        }
        var unread: [ObligationLiveSource] = []
        if live.monitor == nil { unread.append(.monitor) }
        if live.licences == nil { unread.append(.licences) }
        if live.keys == nil { unread.append(.keys) }
        if live.continuity == nil { unread.append(.continuity) }
        return ObligationsRegister(obligations: rows, accounts: accounts,
                                   issues: validate(obligations: rows, accounts: accounts, file: file), builtAt: now,
                                   unread: unread)
    }

    /// An account's renewal as an obligation: dated when known, "date unknown" otherwise.
    static func renewal(_ a: VendorAccount) -> Obligation {
        Obligation(id: a.renewalObligationID,
                   title: a.renewal == nil ? LF("%@: renewal date unknown", a.name) : LF("%@: renewal", a.name),
                   product: nil, area: .accounts, due: a.renewal,
                   source: a.renewalSource ?? a.source, recordedOn: a.recordedOn, origin: .account, subject: a.id)
    }

    // MARK: Live rows

    static func derived(_ live: ObligationLiveInput, calendar: Calendar) -> [Obligation] {
        var out: [Obligation] = []
        if let s = live.monitor {
            for (name, d) in s.domains.sorted(by: { $0.key < $1.key }) {
                guard let expires = d.expiresAt else { continue }
                out.append(Obligation(id: "domain.\(name)", title: LF("%@ registration ends", name), product: name, area: .domains,
                                      due: KeyDay(expires, calendar: calendar),
                                      consequence: name == "linumic.com"
                                          ? "Every Linumic address depends on it: the website, contact@linumic.com and the subdomains such as console.linumic.com."
                                          : nil,
                                      source: LF("RDAP: %@", d.sourceURL), recordedOn: KeyDay(d.fetchedAt, calendar: calendar),
                                      readAt: d.fetchedAt, origin: .domain, subject: name))
            }
            for reading in s.certificates.values.filter({ live.monitorHosts.contains($0.host) }).sorted(by: { $0.host < $1.host }) {
                out.append(Obligation(id: "tls.\(reading.host)", title: LF("TLS certificate of %@ ends", reading.host),
                                      area: .domains, due: KeyDay(reading.notAfter, calendar: calendar),
                                      source: LF("TLS handshake with %@", reading.host),
                                      recordedOn: KeyDay(reading.readAt, calendar: calendar), readAt: reading.readAt,
                                      origin: .certificate, subject: reading.host))
            }
        }
        for r in live.licences ?? [] where r.status == .active {
            guard let expires = r.expires, let day = KeyDay(expires) else { continue }
            // No customer name: the licence id is enough to open it, and nothing personal enters the register.
            out.append(Obligation(id: "licence.\(r.licenceID)", title: LF("%@ licence %@ ends", r.product.displayName, r.licenceID),
                                  product: r.product.displayName, area: .licences, due: day,
                                  consequence: "After a licence ends the product gives a 30-day grace; renew it before then.",
                                  source: live.licencesSynced ? L("Licence ledger (synced with Supabase)") : L("Licence ledger on this device (not synced)"),
                                  recordedOn: live.licencesReadAt.map { KeyDay($0, calendar: calendar) } ?? KeyDay(r.updatedAt, calendar: calendar),
                                  readAt: live.licencesReadAt, origin: .licence, subject: r.licenceID))
        }
        if let reg = live.keys {
            for b in reg.backups {
                if let test = b.lastRestoreTest {
                    let next = KeyDay(Calendar.utc.date(byAdding: .day, value: KeysRules.restoreTestMaxDays, to: test.on.start(calendar: .utc)) ?? .distantFuture,
                                      calendar: .utc)
                    out.append(Obligation(id: "keys.restore.\(b.id)", title: LF("%@: next restore test", L(b.title)), area: .keys,
                                          due: next,
                                          consequence: "A backup that has not been restored lately may not restore when it is needed.",
                                          source: LF("Keys & Backups registry: last restore test %@ (%@)", test.on.description, test.source),
                                          recordedOn: test.on, origin: .keys, subject: b.id))
                } else {
                    out.append(Obligation(id: "keys.restore.\(b.id)", title: LF("%@: no restore test recorded", L(b.title)), area: .keys,
                                          due: nil, source: b.source, recordedOn: b.recordedOn, origin: .keys, subject: b.id))
                }
            }
            if let gap = reg.secondCopyGap, gap.isOpen {
                out.append(Obligation(id: "keys.second-copy", title: "No second copy of the key backups off this Mac", area: .keys,
                                      due: nil, consequence: gap.detail, source: gap.source, recordedOn: gap.recordedOn, origin: .keys))
            }
        }
        if let log = live.continuity {
            out.append(continuityExport(log, calendar: calendar))
        }
        return out
    }

    /// The encrypted copy of Linumic OS's data off this Mac: due 30 days after the last verified export, or "date
    /// unknown" (and to do now) when there is none.
    static func continuityExport(_ log: ContinuityLog, calendar: Calendar) -> Obligation {
        let consequence = "Without it, the inventory, obligations, licence ledger and keys registry exist only on this Mac and in Supabase, which keeps no point-in-time backup on the free plan."
        let source = "~/Projects/Multiplatform/Linumic/LinumicCommandCenter/PRIORITIES.md:53 (P0, 2026-10-19: no copy of Linumic OS data off this Mac yet); continuity.json"
        guard let last = log.lastVerified else {
            return Obligation(id: "continuity.export", title: "No encrypted copy of Linumic OS data off this Mac yet", product: "Linumic OS",
                              area: .continuity, due: nil, consequence: consequence, source: source,
                              recordedOn: KeyDay("2026-10-19"), origin: .continuity)
        }
        let day = KeyDay(last.createdAt, calendar: calendar)
        let next = KeyDay(calendar.date(byAdding: .day, value: exportEveryDays, to: last.createdAt) ?? last.createdAt, calendar: calendar)
        return Obligation(id: "continuity.export", title: "Next encrypted export of Linumic OS data", product: "Linumic OS",
                          area: .continuity, due: next, consequence: consequence,
                          source: LF("continuity.json: %@ verified %@", last.fileName, day.description),
                          recordedOn: day, readAt: last.verifiedAt, origin: .continuity)
    }

    // MARK: Validation

    /// Refuses a row without a source or a recorded day, a Done without evidence, a value set without a source, a row
    /// without a title, and two rows with one id.
    public static func validate(obligations: [Obligation], accounts: [VendorAccount], file: ObligationsFile) -> [ObligationIssue] {
        var issues: [ObligationIssue] = []
        var seen = Set<String>()
        for o in obligations {
            if !seen.insert(o.id).inserted { issues.append(.duplicateID(o.id)) }
            if o.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.noTitle(o.id)) }
            if o.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || o.recordedOn == nil { issues.append(.noSource(o.id)) }
        }
        var seenAccounts = Set<String>()
        for a in accounts {
            if !seenAccounts.insert(a.id).inserted { issues.append(.duplicateID(a.id)) }
            if a.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || a.recordedOn == nil { issues.append(.noSource(a.id)) }
            if a.renewal != nil, ObligationsFile.clean(a.renewalSource) == nil { issues.append(.valueWithoutSource(a.id)) }
            if a.holder != nil, ObligationsFile.clean(a.holderSource) == nil { issues.append(.valueWithoutSource(a.id)) }
        }
        for c in file.completions where ObligationsFile.clean(c.evidence) == nil { issues.append(.doneWithoutEvidence(c.obligationID)) }
        for d in file.dates where ObligationsFile.clean(d.source) == nil { issues.append(.valueWithoutSource(d.obligationID)) }
        for e in file.accountEdits where (e.renewal != nil && ObligationsFile.clean(e.renewalSource) == nil)
            || (e.holder != nil && ObligationsFile.clean(e.holderSource) == nil) {
            issues.append(.valueWithoutSource(e.accountID))
        }
        return issues
    }
}

// MARK: - Alerts at the lead days

/// One notification due now: an obligation that entered a lead window (30, 14, 7 or 1 day) or reached its day.
public struct ObligationAlert: Hashable, Sendable {
    /// "obligation:<id>:<due>:<lead>", the same key a server sweep would use, so nothing alerts twice.
    public var key: String
    public var obligation: Obligation
    public var lead: Int
}

public enum ObligationAlerts {
    /// The alerts to post now that are not in `sent`. Live rows have their own notifications (Monitor, Licences) and
    /// are left out; so are closed rows and rows with no date.
    public static func due(_ register: ObligationsRegister, today: KeyDay, sent: Set<String>) -> [ObligationAlert] {
        register.obligations.compactMap { o in
            guard !o.origin.isLive, o.completion == nil, let due = o.due else { return nil }
            let lead: Int
            switch ObligationRules.timing(o, today: today) {
            case .overdue: lead = 0
            case .due(_, let l?): lead = l
            default: return nil
            }
            let key = "obligation:\(o.id):\(due.description):\(lead)"
            return sent.contains(key) ? nil : ObligationAlert(key: key, obligation: o, lead: lead)
        }
    }
}

extension Calendar {
    /// Gregorian in UTC, for day arithmetic on `KeyDay`s.
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
