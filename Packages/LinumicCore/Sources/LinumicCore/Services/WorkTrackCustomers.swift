import Foundation

// WorkTrack customers and renewals: date rules, list filters, the renewal request builder (and its expiresAt
// guard), the before/after diff, post-write verification, reminders and a local action log.
// Pure functions over the vendor API models; no network here.

// MARK: - Dates (the server's rules)

/// WorkTrack's date rules. The vendor's "today" is Kabul's (`routes/vendor.ts:52-54`), licence dates are plain
/// `YYYY-MM-DD` Gregorian days, and month arithmetic clamps to the last day (`lib/dates.ts:23-30`).
public enum WorkTrackDates {
    public static let kabul = TimeZone(identifier: "Asia/Kabul")!
    /// `plans.ts:110`: the licence keeps working this many days after `expiresAt`.
    public static let graceDays = 7

    static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Today's date in Kabul, `YYYY-MM-DD`.
    public static func kabulToday(_ now: Date = .now) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kabul
        let d = c.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }

    /// Strict `YYYY-MM-DD` (a real calendar day).
    public static func isValid(_ text: String) -> Bool { parse(text) != nil }

    static func parse(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = utcCalendar.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return (y, m, d)
    }

    static func format(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    /// `addMonths` from WorkTrack `lib/dates.ts`: same day of the month, clamped to the month's last day.
    public static func addMonths(_ text: String, _ months: Int) -> String? {
        guard let (y, m, d) = parse(text) else { return nil }
        let index = y * 12 + (m - 1) + months
        let ty = Int((Double(index) / 12).rounded(.down)), tm = index - ty * 12 + 1
        guard let first = utcCalendar.date(from: DateComponents(year: ty, month: tm, day: 1)),
              let days = utcCalendar.range(of: .day, in: .month, for: first)?.count else { return nil }
        return format(ty, tm, min(d, days))
    }

    public static func addDays(_ text: String, _ days: Int) -> String? {
        guard let (y, m, d) = parse(text), let date = utcCalendar.date(from: DateComponents(year: y, month: m, day: d)),
              let moved = utcCalendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let c = utcCalendar.dateComponents([.year, .month, .day], from: moved)
        return format(c.year!, c.month!, c.day!)
    }

    /// Whole days from `from` to `to` (negative when `to` is earlier).
    public static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let (y1, m1, d1) = parse(from), let (y2, m2, d2) = parse(to),
              let a = utcCalendar.date(from: DateComponents(year: y1, month: m1, day: d1)),
              let b = utcCalendar.date(from: DateComponents(year: y2, month: m2, day: d2)) else { return nil }
        return utcCalendar.dateComponents([.day], from: a, to: b).day
    }

    /// The day as a `Date` at noon UTC, for display in the UI's calendar without shifting a day.
    public static func displayDate(_ text: String) -> Date? {
        guard let (y, m, d) = parse(text) else { return nil }
        return utcCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }

    /// The `YYYY-MM-DD` the owner picked in a date picker (its components in this device's calendar).
    public static func string(fromPicked date: Date, calendar: Calendar = .current) -> String {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        let c = g.dateComponents([.year, .month, .day], from: date)
        return format(c.year!, c.month!, c.day!)
    }

    /// An ISO 8601 instant from the API (`toISOString()`, with milliseconds).
    public static func instant(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

// MARK: - Standing and filters

/// Where a licence stands, as `licenseStanding` (`services/license.ts:222-237`) would put it, from the server's
/// `daysUntilExpiry`.
public enum WTStanding: String, Sendable, Equatable {
    case active, grace, lapsed, perpetual
}

public extension WTCompany {
    var isFlagged: Bool { flags != nil }

    var standing: WTStanding {
        if license.status != .active { return .lapsed }
        guard let days = daysUntilExpiry else { return .perpetual }
        if days >= 0 { return .active }
        return days >= -WorkTrackDates.graceDays ? .grace : .lapsed
    }

    var isTrial: Bool { license.plan == .trial }

    /// Status EXPIRED, or past its last day (including the grace week).
    var isExpired: Bool { license.status == .expired || (daysUntilExpiry.map { $0 < 0 } ?? false) }

    /// Active and ending within `days` (0 = last day is today).
    func isExpiring(within days: Int) -> Bool {
        guard license.status == .active, let d = daysUntilExpiry else { return false }
        return d >= 0 && d <= days
    }

    /// Anything the server lists above "info".
    var needsAttention: Bool { attention.contains { $0.severity != "info" } }
}

public enum WTCompanyFilter: String, CaseIterable, Sendable, Identifiable {
    case all, expiring30, expired, trial, attention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: L("All")
        case .expiring30: L("Expiring in 30 days")
        case .expired: L("Expired")
        case .trial: L("Trial")
        case .attention: L("Needs attention")
        }
    }

    public func matches(_ c: WTCompany) -> Bool {
        switch self {
        case .all: true
        case .expiring30: c.isExpiring(within: 30)
        case .expired: c.isExpired
        case .trial: c.isTrial
        case .attention: c.needsAttention
        }
    }
}

/// Counts for the screen header and the dashboard card. TEST / DUPLICATE companies are left out of the
/// renewal counts, as the server leaves them out of revenue (`summariseRevenue`).
public struct WTCustomersSummary: Sendable, Equatable {
    public let total: Int
    public let flagged: Int
    public let expiringSoon: [WTCompany]
    public let expired: [WTCompany]
    public let trials: Int

    public init(companies: [WTCompany], window: Int = 30) {
        let real = companies.filter { !$0.isFlagged }
        total = companies.count
        flagged = companies.count - real.count
        expiringSoon = real.filter { $0.isExpiring(within: window) }
            .sorted { ($0.daysUntilExpiry ?? 0, $0.name) < ($1.daysUntilExpiry ?? 0, $1.name) }
        expired = real.filter(\.isExpired)
        trials = real.filter(\.isTrial).count
    }
}

// MARK: - Renewal

/// The new expiry the owner chose.
public enum WTExpiryChoice: Equatable, Sendable {
    /// A last day in force, `YYYY-MM-DD`.
    case date(String)
    /// No end date. Only accepted with `confirmed == true`, which the UI sets from a separate confirmation.
    case perpetual(confirmed: Bool)
}

/// What the owner changes in a renewal. Everything not here is copied from the current licence.
public struct WTRenewalInput: Equatable, Sendable {
    public var plan: WTPlan
    public var deviceLimit: Int
    public var status: WTLicenseStatus
    public var expiry: WTExpiryChoice

    public init(plan: WTPlan, deviceLimit: Int, status: WTLicenseStatus, expiry: WTExpiryChoice) {
        self.plan = plan
        self.deviceLimit = deviceLimit
        self.status = status
        self.expiry = expiry
    }
}

public enum WTRenewalError: Error, LocalizedError, Equatable {
    case perpetualNotConfirmed
    case invalidDate(String)
    case dateInPast(String)
    case unknownPlan(String)
    case unwritableStatus(String)
    case deviceLimitOutOfRange(Int)
    case employeeLimitOutOfRange(Int)
    case unknownFeature(String)
    case confirmationMismatch

    public var errorDescription: String? {
        switch self {
        case .perpetualNotConfirmed: L("A licence without an end date needs its own confirmation.")
        case .invalidDate(let s): LF("“%@” isn't a valid date (YYYY-MM-DD).", s)
        case .dateInPast(let s): LF("The new last day (%@) is before today in Kabul.", s)
        case .unknownPlan(let p): LF("WorkTrack doesn't accept the plan “%@”.", p)
        case .unwritableStatus(let s): LF("The current status “%@” can't be sent back; choose ACTIVE, SUSPENDED or EXPIRED.", s)
        case .deviceLimitOutOfRange(let n): LF("Device seats must be between 1 and 100,000 (got %ld).", n)
        case .employeeLimitOutOfRange(let n): LF("The current employee cap (%ld) is outside 1 to 100,000; WorkTrack would refuse it.", n)
        case .unknownFeature(let f): LF("The licence carries a feature WorkTrack no longer accepts (“%@”); change it in the WorkTrack console.", f)
        case .confirmationMismatch: L("Type the company name exactly to confirm.")
        }
    }
}

/// One line of the before/after table.
public struct WTFieldChange: Equatable, Sendable, Identifiable {
    public let field: String
    public let before: String
    public let after: String
    public var changed: Bool { before != after }
    public var id: String { field }
}

public enum WorkTrackRenewal {
    /// `plans.ts` FEATURE_KEYS, the values `licenseWriteSchema` accepts in `extraFeatures`.
    public static let featureKeys: Set<String> = [
        "attendance", "leave", "shifts", "announcements", "payroll", "finance", "documents", "kiosk",
        "projects", "pieceWork", "faceRecognition",
    ]

    /// Where a renewal counts from: the current last day if it is still ahead, otherwise today (Kabul).
    /// The same base WorkTrack's own purchase flow uses (`licenseAfterPurchase`, `billing.ts`).
    public static func base(for license: WTLicense, today: String) -> String {
        if let e = license.expiresAt, WorkTrackDates.isValid(e), e > today { return e }
        return today
    }

    /// +1 month / +1 year from `base`.
    public static func extended(_ license: WTLicense, months: Int, today: String) -> String? {
        WorkTrackDates.addMonths(base(for: license, today: today), months)
    }

    /// The status a renewal starts from: an EXPIRED licence becomes ACTIVE (that is what renewing means);
    /// ACTIVE and SUSPENDED stay as they are, so a suspension is never lifted without the owner choosing it.
    public static func suggestedStatus(for license: WTLicense) -> WTLicenseStatus {
        license.status == .expired ? .active : license.status
    }

    /// Builds the PUT body from the licence **as just fetched**. Every field the owner didn't change is copied
    /// from `current`; `expiresAt` is always set unless perpetual was separately confirmed.
    public static func makeWrite(current: WTLicense, input: WTRenewalInput, today: String) throws -> WTLicenseWrite {
        guard input.plan.isKnown else { throw WTRenewalError.unknownPlan(input.plan.rawValue) }
        guard WTLicenseStatus.writable.contains(input.status) else { throw WTRenewalError.unwritableStatus(input.status.rawValue) }
        guard (1...100_000).contains(input.deviceLimit) else { throw WTRenewalError.deviceLimitOutOfRange(input.deviceLimit) }
        if let cap = current.employeeLimit, !(1...100_000).contains(cap) { throw WTRenewalError.employeeLimitOutOfRange(cap) }
        if let bad = current.extraFeatures.first(where: { !featureKeys.contains($0) }) { throw WTRenewalError.unknownFeature(bad) }

        let expiresAt: String?
        switch input.expiry {
        case .date(let d):
            guard WorkTrackDates.isValid(d) else { throw WTRenewalError.invalidDate(d) }
            guard d >= today else { throw WTRenewalError.dateInPast(d) }
            expiresAt = d
        case .perpetual(let confirmed):
            guard confirmed else { throw WTRenewalError.perpetualNotConfirmed }
            expiresAt = nil
        }
        return WTLicenseWrite(plan: input.plan, deviceLimit: input.deviceLimit, status: input.status, expiresAt: expiresAt,
                              enforceDevices: current.enforceDevices, enforcePlan: current.enforcePlan,
                              employeeLimit: current.employeeLimit, extraFeatures: current.extraFeatures)
    }

    /// Every licence field, before and after (the `source` becomes VENDOR on any vendor write).
    public static func diff(current: WTLicense, write: WTLicenseWrite) -> [WTFieldChange] {
        diff(before: current, after: write.expectedLicense)
    }

    public static func diff(before: WTLicense, after: WTLicense) -> [WTFieldChange] {
        func yesNo(_ b: Bool) -> String { b ? L("Yes") : L("No") }
        func expiry(_ e: String?) -> String { e ?? L("Never (perpetual)") }
        func cap(_ n: Int?) -> String { n.map(String.init) ?? L("Plan's cap") }
        func features(_ f: [String]) -> String { f.isEmpty ? L("None") : f.sorted().joined(separator: ", ") }
        return [
            WTFieldChange(field: L("Plan"), before: before.plan.rawValue, after: after.plan.rawValue),
            WTFieldChange(field: L("Last day (expiresAt)"), before: expiry(before.expiresAt), after: expiry(after.expiresAt)),
            WTFieldChange(field: L("Status"), before: before.status.rawValue, after: after.status.rawValue),
            WTFieldChange(field: L("Device seats"), before: String(before.deviceLimit), after: String(after.deviceLimit)),
            WTFieldChange(field: L("Enforce device seats"), before: yesNo(before.enforceDevices), after: yesNo(after.enforceDevices)),
            WTFieldChange(field: L("Enforce plan"), before: yesNo(before.enforcePlan), after: yesNo(after.enforcePlan)),
            WTFieldChange(field: L("Employee cap"), before: cap(before.employeeLimit), after: cap(after.employeeLimit)),
            WTFieldChange(field: L("Extra features"), before: features(before.extraFeatures), after: features(after.extraFeatures)),
            WTFieldChange(field: L("Source"), before: before.source, after: after.source),
        ]
    }

    /// Fields where what the server stored differs from what was sent (empty = as intended).
    public static func mismatches(expected: WTLicense, stored: WTLicense) -> [WTFieldChange] {
        var e = expected, s = stored
        e.extraFeatures.sort()
        s.extraFeatures.sort()
        return diff(before: e, after: s).filter(\.changed)
    }

    /// Production writes are confirmed by typing the company name (trimmed, case and spacing as shown).
    public static func confirmationMatches(_ typed: String, companyName: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == companyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Reminders

/// A local reminder 30, 14, 7 or 1 days before a WorkTrack customer's last licensed day.
public struct WorkTrackReminder: Sendable, Equatable, Identifiable {
    public let companyID: String
    public let name: String
    public let plan: String
    public let expiresAt: String
    public let daysBefore: Int
    public let fireDay: String
    public var id: String { "worktrack-\(companyID)-\(expiresAt)-\(daysBefore)" }

    public static let offsets = [30, 14, 7, 1]

    /// For active, dated, unflagged licences; reminders due today or later, soonest first.
    public static func schedule(for companies: [WTCompany], today: String) -> [WorkTrackReminder] {
        var out: [WorkTrackReminder] = []
        for c in companies where !c.isFlagged && c.license.status == .active {
            guard let e = c.license.expiresAt, WorkTrackDates.isValid(e) else { continue }
            for n in offsets {
                guard let day = WorkTrackDates.addDays(e, -n), day >= today else { continue }
                out.append(WorkTrackReminder(companyID: c.companyId, name: c.name, plan: c.license.plan.rawValue,
                                             expiresAt: e, daysBefore: n, fireDay: day))
            }
        }
        return out.sorted { ($0.fireDay, $0.companyID) < ($1.fireDay, $1.companyID) }
    }
}

// MARK: - Local action log

/// Linumic OS's own record of a WorkTrack write it sent: who, what, where, before/after, result.
/// WorkTrack keeps its own trails too (`vendorAuditLogs` and the company's `auditLogs`); this one is the
/// owner's copy on this device, so a failed or unverified write is never lost.
public struct WorkTrackActionRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Sent, stored, and the re-fetch matched.
        case verified
        /// Sent and stored, but the re-fetch differs (`mismatches` lists how) or couldn't be read.
        case unverified
        /// The server refused it, or it never arrived.
        case failed
    }

    public var id: UUID
    public var at: Date
    public var environment: WorkTrackEnvironment
    public var actorEmail: String
    public var action: String
    public var companyID: String
    public var companyName: String
    public var before: WTLicense
    public var sent: WTLicense
    public var stored: WTLicense?
    public var outcome: Outcome
    public var message: String?

    public init(id: UUID = UUID(), at: Date, environment: WorkTrackEnvironment, actorEmail: String, action: String = "license.update",
                companyID: String, companyName: String, before: WTLicense, sent: WTLicense, stored: WTLicense?,
                outcome: Outcome, message: String?) {
        self.id = id
        self.at = at
        self.environment = environment
        self.actorEmail = actorEmail
        self.action = action
        self.companyID = companyID
        self.companyName = companyName
        self.before = before
        self.sent = sent
        self.stored = stored
        self.outcome = outcome
        self.message = message
    }
}

/// Append-only JSON file next to `inventory.json` (`worktrack-actions.json`). Entries are never removed.
public actor WorkTrackActionLog {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "worktrack-actions.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Newest first. A missing file is an empty log.
    public func load() throws -> [WorkTrackActionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let records = try Self.decoder.decode([WorkTrackActionRecord].self, from: Data(contentsOf: fileURL))
        return records.sorted { $0.at > $1.at }
    }

    public func append(_ record: WorkTrackActionRecord) throws {
        var all = try load()
        all.append(record)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(all.sorted { $0.at < $1.at }).write(to: fileURL, options: .atomic)
    }
}
