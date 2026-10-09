import CryptoKit
import Foundation

/// Ledger state of an issued licence. Offline keys can't be recalled: `void` and `superseded` are
/// bookkeeping only, the customer's app keeps accepting a valid key until it expires.
public enum LicenceStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case active, superseded, void
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: L("Active")
        case .superseded: L("Superseded")
        case .void: L("Void")
        }
    }

    /// Statuses only move forward: active → superseded → void. Merges keep the furthest one.
    var rank: Int {
        switch self {
        case .active: 0
        case .superseded: 1
        case .void: 2
        }
    }
}

/// Calendar dates as LNM1 writes them (`YYYY-MM-DD`, Gregorian, no time zone), whatever the UI calendar is.
public enum LicenceDate {
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// Today's date on this device, as the Python tool's `date.today()`.
    public static func string(from date: Date, calendar: Calendar = LicenceDate.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Parses `YYYY-MM-DD` strictly (a real calendar day). Returns the start of that day.
    public static func date(from text: String, calendar: Calendar = LicenceDate.calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return date
    }

    public static func isValid(_ text: String) -> Bool { date(from: text) != nil }

    /// Whole days from `today` to `text` (0 = that day is today, negative = in the past).
    public static func days(until text: String, from today: Date, calendar: Calendar = LicenceDate.calendar) -> Int? {
        guard let target = date(from: text, calendar: calendar) else { return nil }
        let start = calendar.startOfDay(for: today)
        return calendar.dateComponents([.day], from: start, to: target).day
    }

    /// `text` moved by whole years, keeping the day (Feb 29 becomes Feb 28).
    public static func adding(years: Int, to text: String, calendar: Calendar = LicenceDate.calendar) -> String? {
        guard let d = date(from: text, calendar: calendar), let moved = calendar.date(byAdding: .year, value: years, to: d) else { return nil }
        return string(from: moved, calendar: calendar)
    }
}

/// One licence in the ledger. The signed part (product … features) never changes after issue;
/// status, notes and links to renewals are ledger-only.
public struct LicenceRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var product: LicenceProduct
    public var licenceID: String
    public var customer: String
    public var machine: String
    /// `YYYY-MM-DD`
    public var issued: String
    /// `YYYY-MM-DD`, last valid day; nil = perpetual.
    public var expires: String?
    public var edition: String
    /// nil = unknown (a row imported from `issued.csv`, which doesn't record features).
    public var features: [String]?
    /// The full `LNM1.…` key; nil = unknown (an `issued.csv` row without its `.lnmlic` file).
    public var keyText: String?
    public var status: LicenceStatus
    /// The licence this one renewed or replaced. Ledger only, not in the signed payload.
    public var renewedFrom: String?
    public var notes: String
    /// Who or what recorded it, e.g. "Linumic OS" or "issued.csv import".
    public var createdBy: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), product: LicenceProduct, licenceID: String, customer: String, machine: String,
                issued: String, expires: String?, edition: String = "standard", features: [String]? = ["*"],
                keyText: String? = nil, status: LicenceStatus = .active, renewedFrom: String? = nil, notes: String = "",
                createdBy: String, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.product = product
        self.licenceID = licenceID
        self.customer = customer
        self.machine = machine
        self.issued = issued
        self.expires = expires
        self.edition = edition
        self.features = features
        self.keyText = keyText
        self.status = status
        self.renewedFrom = renewedFrom
        self.notes = notes
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Whole days until the last valid day (0 = last day is today), or nil when perpetual.
    public func daysUntilExpiry(today: Date = .now) -> Int? {
        expires.flatMap { LicenceDate.days(until: $0, from: today) }
    }

    /// Active, has an expiry, and the last valid day is between today and `days` from now.
    public func isExpiring(within days: Int, today: Date = .now) -> Bool {
        guard status == .active, let left = daysUntilExpiry(today: today) else { return false }
        return left >= 0 && left <= days
    }

    /// Active but past its last valid day.
    public func isExpired(today: Date = .now) -> Bool {
        guard status == .active, let left = daysUntilExpiry(today: today) else { return false }
        return left < 0
    }

    /// Fields that are inside the signature. Two records with the same licence id must agree on these.
    var signedFields: [String] {
        [product.rawValue, licenceID, customer, machine, issued, expires ?? "", edition]
    }
}

public enum LicenceLedgerError: Error, LocalizedError, Equatable, Sendable {
    case customerMissing
    case machineInvalid
    case expiryInvalid
    case expiryBeforeIssue
    case cannotRenew(LicenceStatus)
    case duplicateID(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .customerMissing: L("Enter the customer's name.")
        case .machineInvalid: L("The machine code must be 16 characters like K7Q2-9XMB-4T1D-WP3C, or * for any machine.")
        case .expiryInvalid: L("The expiry date isn't a valid date.")
        case .expiryBeforeIssue: L("The expiry date is before today.")
        case .cannotRenew(let s): LF("A %@ licence can't be renewed. Renew the newest licence of this customer.", s.title)
        case .duplicateID(let id): LF("Licence %@ is already in the ledger.", id)
        case .verificationFailed(let why): LF("The new key didn't verify, so it wasn't issued: %@", why)
        }
    }
}

/// What the owner fills in on the Issue sheet.
public struct LicenceRequest: Sendable, Equatable {
    public var product: LicenceProduct
    public var customer: String
    public var machine: String
    /// nil = perpetual
    public var expires: String?
    public var edition: String
    public var features: [String]
    public var notes: String

    public init(product: LicenceProduct, customer: String, machine: String, expires: String?,
                edition: String = "standard", features: [String] = ["*"], notes: String = "") {
        self.product = product
        self.customer = customer
        self.machine = machine
        self.expires = expires
        self.edition = edition
        self.features = features
        self.notes = notes
    }
}

/// Pure ledger operations: next id, issue, renew, void, merge.
public enum LicenceLedger {
    /// The next free id for a product and year, as `next_id` in the Python tool: highest number in
    /// the ledger with that prefix, plus one, four digits.
    public static func nextID(for product: LicenceProduct, year: Int, in ledger: [LicenceRecord]) -> String {
        let prefix = "\(product.idPrefix)-\(year)-"
        let used = ledger.compactMap { r -> Int? in
            guard r.licenceID.hasPrefix(prefix) else { return nil }
            return Int(r.licenceID.dropFirst(prefix.count))
        }
        return prefix + String(format: "%04d", (used.max() ?? 0) + 1)
    }

    /// Signs a new licence. The key is verified with `publicKey` (the embedded production key by
    /// default) before it is returned, like the Python tool: a key that doesn't verify is never handed out.
    public static func issue(_ request: LicenceRequest, signingKey: P256.Signing.PrivateKey,
                             publicKey: P256.Signing.PublicKey? = nil, ledger: [LicenceRecord],
                             renewedFrom: String? = nil, createdBy: String,
                             now: Date = .now, calendar: Calendar = LicenceDate.calendar) throws -> LicenceRecord {
        let customer = request.customer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !customer.isEmpty else { throw LicenceLedgerError.customerMissing }
        guard let machine = MachineCode.normalize(request.machine) else { throw LicenceLedgerError.machineInvalid }
        let issued = LicenceDate.string(from: now, calendar: calendar)
        if let e = request.expires {
            guard LicenceDate.isValid(e) else { throw LicenceLedgerError.expiryInvalid }
            guard e >= issued else { throw LicenceLedgerError.expiryBeforeIssue }
        }
        let edition = request.edition.trimmingCharacters(in: .whitespacesAndNewlines)
        let features = request.features.isEmpty ? ["*"] : request.features
        let year = calendar.component(.year, from: now)
        let licenceID = nextID(for: request.product, year: year, in: ledger)
        let payload = LicencePayload(product: request.product.rawValue, licenceID: licenceID, customer: customer,
                                     machine: machine, issued: issued, expires: request.expires,
                                     edition: edition.isEmpty ? "standard" : edition, features: features)
        let key = try LicenceKey.sign(payload, with: signingKey)
        do {
            let checked = try LicenceKey.verify(key, product: request.product, publicKey: publicKey ?? request.product.productionPublicKey)
            guard checked == payload else { throw LicenceKeyError.badJSON }
        } catch {
            throw LicenceLedgerError.verificationFailed(error.localizedDescription)
        }
        return LicenceRecord(product: request.product, licenceID: licenceID, customer: customer, machine: machine,
                             issued: issued, expires: request.expires, edition: payload.edition, features: features,
                             keyText: key, status: .active, renewedFrom: renewedFrom,
                             notes: request.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                             createdBy: createdBy, createdAt: now)
    }

    /// Renews (or re-issues for a new machine): a new licence id for the same customer, edition and
    /// features with a new expiry; the old licence becomes `superseded`. Returns the new record and the updated old one.
    public static func renew(_ old: LicenceRecord, expires: String?, machine: String? = nil, notes: String = "",
                             signingKey: P256.Signing.PrivateKey, publicKey: P256.Signing.PublicKey? = nil,
                             ledger: [LicenceRecord], createdBy: String, now: Date = .now,
                             calendar: Calendar = LicenceDate.calendar) throws -> (renewed: LicenceRecord, superseded: LicenceRecord) {
        guard old.status == .active else { throw LicenceLedgerError.cannotRenew(old.status) }
        let request = LicenceRequest(product: old.product, customer: old.customer, machine: machine ?? old.machine,
                                     expires: expires, edition: old.edition, features: old.features ?? ["*"], notes: notes)
        let renewed = try issue(request, signingKey: signingKey, publicKey: publicKey, ledger: ledger,
                                renewedFrom: old.licenceID, createdBy: createdBy, now: now, calendar: calendar)
        var superseded = old
        superseded.status = .superseded
        superseded.updatedAt = now
        return (renewed, superseded)
    }

    /// Marks a licence void in the ledger. The key itself keeps working in the customer's app.
    public static func void(_ record: LicenceRecord, reason: String, now: Date = .now) -> LicenceRecord {
        var r = record
        r.status = .void
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { r.notes = r.notes.isEmpty ? reason : r.notes + "\n" + reason }
        r.updatedAt = now
        return r
    }

    /// Records that disagree on signed fields for the same licence id.
    public struct Conflict: Sendable, Equatable {
        public let licenceID: String
    }

    /// Merges two copies of the ledger by licence id. Nothing is ever dropped. For the same licence:
    /// the further status wins (active → superseded → void), a known key/feature list wins over an
    /// unknown one, and notes come from the copy edited last. Signed fields must agree; when they
    /// don't, the remote (server) copy is kept and the id is reported.
    public static func merge(_ local: [LicenceRecord], _ remote: [LicenceRecord]) -> (records: [LicenceRecord], conflicts: [Conflict]) {
        var byID: [String: LicenceRecord] = [:]
        var conflicts: [Conflict] = []
        for r in remote { byID[r.licenceID] = r }
        for l in local {
            guard let r = byID[l.licenceID] else { byID[l.licenceID] = l; continue }
            if l.signedFields != r.signedFields || (l.keyText != nil && r.keyText != nil && l.keyText != r.keyText) {
                conflicts.append(Conflict(licenceID: l.licenceID))
                continue  // keep the server copy
            }
            byID[l.licenceID] = combine(r, l)
        }
        return (sorted(Array(byID.values)), conflicts)
    }

    static func combine(_ a: LicenceRecord, _ b: LicenceRecord) -> LicenceRecord {
        var out = a
        out.status = a.status.rank >= b.status.rank ? a.status : b.status
        out.keyText = a.keyText ?? b.keyText
        out.features = a.features ?? b.features
        out.renewedFrom = a.renewedFrom ?? b.renewedFrom
        out.notes = b.updatedAt > a.updatedAt ? b.notes : a.notes
        out.updatedAt = max(a.updatedAt, b.updatedAt)
        return out
    }

    /// Newest first (issue date, then id).
    public static func sorted(_ records: [LicenceRecord]) -> [LicenceRecord] {
        records.sorted { ($0.issued, $0.licenceID) > ($1.issued, $1.licenceID) }
    }

    /// Records that must be sent so the server holds `merged` (missing there, or different).
    public static func changes(_ merged: [LicenceRecord], comparedTo remote: [LicenceRecord]) -> [LicenceRecord] {
        let server = Dictionary(remote.map { ($0.licenceID, $0) }, uniquingKeysWith: { a, _ in a })
        return merged.filter { server[$0.licenceID] != $0 }
    }
}

/// Derived counts for the dashboard. Computed from the ledger, never stored.
public struct LicenceSummary: Sendable, Equatable {
    public let activeByProduct: [LicenceProduct: Int]
    public let expiringSoon: [LicenceRecord]
    public let expired: [LicenceRecord]
    public let total: Int

    public init(records: [LicenceRecord], today: Date = .now, window: Int = 30) {
        var counts: [LicenceProduct: Int] = [:]
        for r in records where r.status == .active { counts[r.product, default: 0] += 1 }
        activeByProduct = counts
        expiringSoon = records.filter { $0.isExpiring(within: window, today: today) }
            .sorted { ($0.expires ?? "", $0.licenceID) < ($1.expires ?? "", $1.licenceID) }
        expired = records.filter { $0.isExpired(today: today) }
        total = records.count
    }
}

/// Local reminders before expiry. The app turns each into a calendar notification.
public struct LicenceReminder: Sendable, Equatable, Identifiable {
    public let licenceID: String
    public let product: LicenceProduct
    public let customer: String
    public let expires: String
    public let daysBefore: Int
    /// `YYYY-MM-DD` on which it fires.
    public let fireDay: String
    public var id: String { "licence-\(licenceID)-\(daysBefore)" }

    public static let offsets = [30, 14, 7, 1]

    /// Reminders still in the future (or due today) for active licences, soonest first.
    public static func schedule(for records: [LicenceRecord], today: Date = .now, calendar: Calendar = LicenceDate.calendar) -> [LicenceReminder] {
        let todayString = LicenceDate.string(from: today, calendar: calendar)
        var out: [LicenceReminder] = []
        for r in records where r.status == .active {
            guard let e = r.expires, let end = LicenceDate.date(from: e, calendar: calendar) else { continue }
            for n in offsets {
                guard let fire = calendar.date(byAdding: .day, value: -n, to: end) else { continue }
                let day = LicenceDate.string(from: fire, calendar: calendar)
                if day >= todayString {
                    out.append(LicenceReminder(licenceID: r.licenceID, product: r.product, customer: r.customer,
                                               expires: e, daysBefore: n, fireDay: day))
                }
            }
        }
        return out.sorted { ($0.fireDay, $0.licenceID) < ($1.fireDay, $1.licenceID) }
    }
}
