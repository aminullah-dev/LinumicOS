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

/// What the owner recorded about an account: its renewal, whose name it is in and what it costs, each with a source.
public struct VendorAccountEdit: Codable, Hashable, Sendable {
    public var accountID: String
    public var renewal: KeyDay?
    public var renewalSource: String?
    public var holder: AccountHolder?
    public var holderSource: String?
    /// What it costs, with the bill it was read from (in the cost itself).
    public var cost: AccountCost?
    public var enteredAt: Date

    public init(accountID: String, renewal: KeyDay? = nil, renewalSource: String? = nil, holder: AccountHolder? = nil,
                holderSource: String? = nil, cost: AccountCost? = nil, enteredAt: Date) {
        self.accountID = accountID
        self.renewal = renewal
        self.renewalSource = renewalSource
        self.holder = holder
        self.holderSource = holderSource
        self.cost = cost
        self.enteredAt = enteredAt
    }
}

/// A Done the owner took back ("Reopen"), kept until the next sync sends it to the cloud as a deletion. Nothing else
/// removes an entry from the cloud: an entry missing from this file is never read as deleted.
public struct ObligationReopen: Codable, Hashable, Sendable {
    public var obligationID: String
    /// The due day of the Done that was taken back; nil for an undated row.
    public var due: KeyDay?

    public init(obligationID: String, due: KeyDay?) {
        self.obligationID = obligationID
        self.due = due
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
    /// Done marks taken back and not yet sent to the cloud (see `ObligationReopen`).
    public var reopened: [ObligationReopen]

    public init(added: [Obligation] = [], dates: [ObligationDateEntry] = [], completions: [ObligationCompletion] = [],
                accounts: [VendorAccount] = [], accountEdits: [VendorAccountEdit] = [], reopened: [ObligationReopen] = []) {
        version = Self.currentVersion
        self.added = added
        self.dates = dates
        self.completions = completions
        self.accounts = accounts
        self.accountEdits = accountEdits
        self.reopened = reopened
    }

    private enum CodingKeys: String, CodingKey { case version, added, dates, completions, accounts, accountEdits, reopened }

    // A file written before the cloud sync has no "reopened".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        added = try c.decode([Obligation].self, forKey: .added)
        dates = try c.decode([ObligationDateEntry].self, forKey: .dates)
        completions = try c.decode([ObligationCompletion].self, forKey: .completions)
        accounts = try c.decode([VendorAccount].self, forKey: .accounts)
        accountEdits = try c.decode([VendorAccountEdit].self, forKey: .accountEdits)
        reopened = try c.decodeIfPresent([ObligationReopen].self, forKey: .reopened) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(added, forKey: .added)
        try c.encode(dates, forKey: .dates)
        try c.encode(completions, forKey: .completions)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(accountEdits, forKey: .accountEdits)
        if !reopened.isEmpty { try c.encode(reopened, forKey: .reopened) }
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
    /// own source, and an account's renewal from the account (`editAccount`): the register does not apply a date set
    /// here for either.
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
        reopened.removeAll { $0.obligationID == obligationID && $0.due == due }
    }

    /// Takes a Done back (it was pressed by mistake), here and (at the next sync) in the cloud.
    public mutating func reopen(_ obligationID: String, due: KeyDay?) {
        let before = completions.count
        completions.removeAll { $0.obligationID == obligationID && $0.due == due }
        let intent = ObligationReopen(obligationID: obligationID, due: due)
        if completions.count < before, !reopened.contains(intent) { reopened.append(intent) }
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

    /// Records an account's renewal day, whose name it is in, what it costs, or any of them; each needs a source.
    public mutating func editAccount(_ accountID: String, renewal: KeyDay?, renewalSource: String?, holder: AccountHolder?,
                                     holderSource: String?, cost: AccountCost? = nil, now: Date) throws {
        if renewal != nil, Self.clean(renewalSource) == nil { throw ObligationError.missingSource }
        if holder != nil, Self.clean(holderSource) == nil { throw ObligationError.missingSource }
        var cleanCost: AccountCost?
        if let c = cost {
            guard Self.clean(c.source) != nil else { throw ObligationError.missingSource }
            guard let checked = c.checked else { throw ObligationError.badAmount }
            cleanCost = checked
        }
        guard renewal != nil || holder != nil || cleanCost != nil else { return }
        // The account is the one place for its renewal day: a date once set on its renewal row is superseded (and so
        // no longer reported as not applied).
        if renewal != nil { dates.removeAll { $0.obligationID == VendorAccount.renewalObligationID(accountID) } }
        accountEdits.append(VendorAccountEdit(accountID: accountID, renewal: renewal, renewalSource: Self.clean(renewalSource),
                                              holder: holder, holderSource: Self.clean(holderSource), cost: cleanCost, enteredAt: now))
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
        case .continuity: L("The continuity export log was not read here (it is kept on the Mac only, or continuity.json could not be read), so whether there is an encrypted copy off this Mac is not known here.")
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
        // What is refused is said (validate's issues) and left out: a refused row is not counted, alerted or put on the
        // Desk, only its issue is.
        var issues: [ObligationIssue] = []

        // Accounts: the seed and the owner's (only what the app's own form writes), each refused without its source.
        var accountCandidates = seedAccounts
        for a in file.accounts {
            if isOwners(id: a.id, origin: a.origin) { accountCandidates.append(a) } else { issues.append(.notOwners(a.id)) }
        }
        let screenedAccounts = screen(accounts: accountCandidates)
        var accounts = screenedAccounts.kept
        issues += screenedAccounts.issues
        // The owner's latest facts on top, each with the day it was entered. A value without its source is not applied
        // (and is reported below); a cost the account sheet would refuse, and facts for an account that is not here,
        // are not applied either, and are reported.
        let candidateIDs = Set(accountCandidates.map(\.id))
        for edit in file.accountEdits.sorted(by: { $0.enteredAt < $1.enteredAt }) {
            guard let i = accounts.firstIndex(where: { $0.id == edit.accountID }) else {
                // An account that was refused already has its own line.
                if !candidateIDs.contains(edit.accountID) { issues.append(.unknownAccount(edit.accountID)) }
                continue
            }
            let entered = KeyDay(edit.enteredAt, calendar: calendar)
            if let r = edit.renewal, let source = ObligationsFile.clean(edit.renewalSource) {
                accounts[i].renewal = r
                accounts[i].renewalSource = source
                accounts[i].renewalRecordedOn = entered
            }
            if let h = edit.holder, let source = ObligationsFile.clean(edit.holderSource) {
                accounts[i].holder = h
                accounts[i].holderSource = source
            }
            // A cost without its bill, or one the sheet would refuse, is reported by fileIssues.
            if let c = edit.cost?.checked {
                accounts[i].cost = c
                accounts[i].costRecordedOn = entered
            }
        }

        // Obligations: the seed, the owner's (again only what the app writes), the renewals that are known to exist,
        // and the live rows.
        var candidates = seed
        for o in file.added {
            if isOwners(id: o.id, origin: o.origin) { candidates.append(o) } else { issues.append(.notOwners(o.id)) }
        }
        candidates += accounts.filter(\.hasRecordedTerm).map(renewal) + derived(live, calendar: calendar)
        // A live row replaces a seed row with the same id (the Monitor's reading of linumic.com replaces the docs').
        let liveIDs = Set(candidates.filter(\.origin.isLive).map(\.id))
        candidates.removeAll { $0.origin == .seed && liveIDs.contains($0.id) }
        let screenedRows = screen(obligations: candidates)
        var rows = screenedRows.kept
        issues += screenedRows.issues

        // The owner's dates, then Done for the due day each row has now. Each day is entered in one place: a live row
        // takes it from its source, an account's renewal from the account's card. A date without a source, a date for
        // a live row, an account's renewal or no row, a Done without evidence and a Done for a live row (which closes
        // only through its source) are not applied: each is reported, and the row stays as its source says.
        issues += fileIssues(file)
        let validDates = file.dates.filter { ObligationsFile.clean($0.source) != nil }
        let validDone = file.completions.filter { ObligationsFile.clean($0.evidence) != nil }
        let dates = Dictionary(validDates.map { ($0.obligationID, $0) }, uniquingKeysWith: { a, b in a.enteredAt >= b.enteredAt ? a : b })
        for id in dates.keys.sorted() where !rows.contains(where: { $0.id == id && $0.origin.takesDateHere }) {
            issues.append(.dateNotApplied(id))
        }
        for i in rows.indices {
            if rows[i].origin.takesDateHere, let d = dates[rows[i].id] {
                rows[i].due = d.due
                rows[i].dueSource = d.source
            }
            if rows[i].origin.takesDoneHere {
                rows[i].completion = validDone.last { $0.obligationID == rows[i].id && $0.due == rows[i].due }
            } else if validDone.contains(where: { $0.obligationID == rows[i].id }) {
                issues.append(.doneNotApplied(rows[i].id))
            }
            // Hand-written lead days that would never bring a row forward (none at all) give way to the defaults.
            rows[i].leadDays = Obligation.usableLeadDays(rows[i].leadDays)
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
        return ObligationsRegister(obligations: rows, accounts: accounts, issues: unique(issues), builtAt: now, unread: unread)
    }

    /// What the app's own forms write into obligations.json: the owner's origin and an "owner." id. Anything else there
    /// (a hand edit, a copy of a seed or live row) is not taken in.
    static func isOwners(id: String, origin: ObligationOrigin) -> Bool {
        origin == .owner && id.hasPrefix("owner.")
    }

    /// An account's renewal as an obligation: dated when known, "date unknown" when only its billing term is. Its
    /// source and recorded day are those of the fact it comes from: the renewal date as entered, else the bill.
    static func renewal(_ a: VendorAccount) -> Obligation {
        var source = a.source
        var recorded = a.recordedOn
        if a.renewal != nil, let s = a.renewalSource {
            source = s
            recorded = a.renewalRecordedOn ?? a.recordedOn
        } else if let c = a.cost {
            source = c.source
            recorded = a.costRecordedOn ?? a.recordedOn
        }
        return Obligation(id: a.renewalObligationID,
                          title: a.renewal == nil ? LF("%@: renewal date unknown", a.name) : LF("%@: renewal", a.name),
                          product: nil, area: .accounts, due: a.renewal, source: source, recordedOn: recorded, origin: .account,
                          subject: a.id)
    }

    // MARK: Live rows

    static func derived(_ live: ObligationLiveInput, calendar: Calendar) -> [Obligation] {
        var out: [Obligation] = []
        if let s = live.monitor {
            for (name, d) in s.domains.sorted(by: { $0.key < $1.key }) {
                guard let expires = d.expiresAt else { continue }
                out.append(Obligation(id: "domain.\(name)", title: LF("%@ registration ends", name), product: name, area: .domains,
                                      due: KeyDay(expires, calendar: calendar),
                                      consequence: name == "linumic.com" ? ObligationSeed.linumicComConsequence : nil,
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
            let ledger = live.licencesSynced ? L("Licence ledger (synced with Supabase)") : L("Licence ledger on this device (not synced)")
            // No customer name: the licence id is enough to open it, and nothing personal enters the register.
            out.append(Obligation(id: "licence.\(r.licenceID)", title: LF("%@ licence %@ ends", r.product.displayName, r.licenceID),
                                  product: r.product.displayName, area: .licences, due: day,
                                  consequence: "After a licence ends the product gives a 30-day grace; renew it before then.",
                                  source: "\(ledger); \(licenceGraceSource)",
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

    /// Where the licence grace comes from: the protocol's GRACE_EXPIRY state.
    static let licenceGraceSource = "~/Projects/Multiplatform/Linumic/licensing/PROTOCOL.md:75 (GRACE_EXPIRY: works fully for 30 days after the end)"

    /// Where the continuity gap is recorded: the P0 lines of Linumic OS's PRIORITIES file. Cited by line range and
    /// quoted, because that file is edited often and its lines move.
    static let continuitySource = "~/Projects/Multiplatform/Linumic/LinumicCommandCenter/PRIORITIES.md:52-54 (P0: «Supabase رایگان PITR ندارد»; 2026-10-19: «هنوز هیچ نسخه‌ای بیرون از این مک نیست»)"

    static let continuityConsequence = "Without it, the inventory and the licence ledger are on this Mac and in Supabase, which keeps no point-in-time backup on the free plan; the obligations and the keys registry are only on this Mac."

    /// The encrypted copy of Linumic OS's data off this Mac: due 30 days after the last verified export known to be off
    /// this Mac, or undated (and to do now) while there is none. An export to a folder on this Mac's own disk, or whose
    /// place is not known, is not a copy off this Mac; one in a cloud folder counts once it was opened outside this Mac
    /// (its local copy reads back whether or not it was uploaded). Either leaves the row as it was.
    static func continuityExport(_ log: ContinuityLog, calendar: Calendar) -> Obligation {
        guard let last = log.lastVerifiedOffMac else {
            var source = "\(continuitySource); continuity.json"
            if let newest = log.lastVerified {
                source += "; " + (newest.folderKind == .cloud
                    ? LF("the newest verified export, %@, is in a cloud folder and has not been opened outside this Mac, so whether it was uploaded is not known",
                         newest.fileName)
                    : LF("the newest verified export, %1$@, is in a folder that is not off this Mac (%2$@)",
                         newest.fileName, newest.folderKind.title))
            }
            return Obligation(id: "continuity.export", title: "No encrypted copy of Linumic OS data off this Mac yet", product: "Linumic OS",
                              area: .continuity, due: nil, consequence: continuityConsequence, source: source,
                              recordedOn: KeyDay("2026-10-19"), origin: .continuity)
        }
        let day = KeyDay(last.createdAt, calendar: calendar)
        let next = KeyDay(log.nextExportDue(calendar: calendar) ?? last.createdAt, calendar: calendar)
        return Obligation(id: "continuity.export", title: "Next encrypted export of Linumic OS data", product: "Linumic OS",
                          area: .continuity, due: next, consequence: continuityConsequence,
                          source: LF("continuity.json: %@ verified %@", last.fileName, day.description),
                          recordedOn: day, readAt: last.verifiedAt, origin: .continuity)
    }

    // MARK: Validation

    /// Refuses a row without a source or a recorded day, a Done without evidence, a value set without a source, a row
    /// without a title, and two rows with one id. `build` leaves each refused row out and keeps only its issue.
    public static func validate(obligations: [Obligation], accounts: [VendorAccount], file: ObligationsFile) -> [ObligationIssue] {
        unique(screen(obligations: obligations).issues + screen(accounts: accounts).issues + fileIssues(file))
    }

    /// The rows that pass, in order (the first of two with one id), and why the others don't.
    static func screen(obligations: [Obligation]) -> (kept: [Obligation], issues: [ObligationIssue]) {
        var kept: [Obligation] = []
        var issues: [ObligationIssue] = []
        var seen = Set<String>()
        for o in obligations {
            if ObligationsFile.clean(o.title) == nil { issues.append(.noTitle(o.id)); continue }
            if ObligationsFile.clean(o.source) == nil || o.recordedOn == nil { issues.append(.noSource(o.id)); continue }
            guard seen.insert(o.id).inserted else { issues.append(.duplicateID(o.id)); continue }
            kept.append(o)
        }
        return (kept, issues)
    }

    /// The accounts that pass. An account without a source or a recorded day is left out; a renewal, holder or cost
    /// without its own source, and a cost the account sheet would refuse, are taken off the account (and reported), so
    /// none is ever shown as known.
    static func screen(accounts: [VendorAccount]) -> (kept: [VendorAccount], issues: [ObligationIssue]) {
        var kept: [VendorAccount] = []
        var issues: [ObligationIssue] = []
        var seen = Set<String>()
        for account in accounts {
            var a = account
            if ObligationsFile.clean(a.name) == nil { issues.append(.noTitle(a.id)); continue }
            if ObligationsFile.clean(a.source) == nil || a.recordedOn == nil { issues.append(.noSource(a.id)); continue }
            guard seen.insert(a.id).inserted else { issues.append(.duplicateID(a.id)); continue }
            if a.renewal != nil, ObligationsFile.clean(a.renewalSource) == nil {
                issues.append(.valueWithoutSource(a.id))
                a.renewal = nil
                a.renewalSource = nil
            }
            if a.holder != nil, ObligationsFile.clean(a.holderSource) == nil {
                issues.append(.valueWithoutSource(a.id))
                a.holder = nil
                a.holderSource = nil
            }
            if let c = a.cost {
                if ObligationsFile.clean(c.source) == nil {
                    issues.append(.valueWithoutSource(a.id))
                    a.cost = nil
                } else if let checked = c.checked {
                    a.cost = checked
                } else {
                    issues.append(.badValue(a.id))
                    a.cost = nil
                }
            }
            kept.append(a)
        }
        return (kept, issues)
    }

    /// The owner's entries that are not applied: a Done without evidence, a date or account value without a source, a
    /// cost the account sheet would refuse.
    static func fileIssues(_ file: ObligationsFile) -> [ObligationIssue] {
        var issues: [ObligationIssue] = []
        for c in file.completions where ObligationsFile.clean(c.evidence) == nil { issues.append(.doneWithoutEvidence(c.obligationID)) }
        for d in file.dates where ObligationsFile.clean(d.source) == nil { issues.append(.valueWithoutSource(d.obligationID)) }
        for e in file.accountEdits {
            if (e.renewal != nil && ObligationsFile.clean(e.renewalSource) == nil)
                || (e.holder != nil && ObligationsFile.clean(e.holderSource) == nil)
                || (e.cost.map { ObligationsFile.clean($0.source) == nil } ?? false) {
                issues.append(.valueWithoutSource(e.accountID))
            }
            if let c = e.cost, ObligationsFile.clean(c.source) != nil, c.checked == nil {
                issues.append(.badValue(e.accountID))
            }
        }
        return issues
    }

    /// Each issue once, in the order found (one line and one card each).
    static func unique(_ issues: [ObligationIssue]) -> [ObligationIssue] {
        var seen = Set<ObligationIssue>()
        return issues.filter { seen.insert($0).inserted }
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
