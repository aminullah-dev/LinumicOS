import CryptoKit
import Foundation

// MARK: - Desk sync: what travels (docs/desk-sync.md)
//
// The owner's Desk marks, his obligations and accounts, and the Mac's last ledger reading, as the Supabase tables
// `desk_state`, `obligations`, `vendors` and `desk_items` hold them (supabase/migrations/20261019090000_desk_sync.sql).
// Every row has a version; a write names the version it was based on, and the server refuses it when the row has moved
// on, answering the row it holds. Nothing is ever deleted: an undo is a tombstone.

/// Which kind of device wrote a row, so a conflict can say "on the Mac" or "on iPhone or iPad". Nothing that names the
/// device or its owner.
public enum CloudDevice: String, Codable, Sendable, Hashable {
    case macOS, iOS

    public static var current: CloudDevice {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }

    public var title: String {
        switch self {
        case .macOS: L("the Mac")
        case .iOS: L("iPhone or iPad")
        }
    }
}

/// What one row of a synced table holds. Each type is encoded as the app stores it (desk-state.json, obligations.json),
/// which is also what the server keeps in `data`.
public protocol CloudPayload: Codable, Hashable, Sendable {
    /// The row's kind as the server stores it ("mark", "row", "seed", "date", "done", "account", "facts").
    var entry: String { get }
    /// Reads `data` of a row of kind `entry`.
    init(entry: String, from decoder: Decoder) throws
    /// Writes `data`.
    func encodeData(to encoder: Encoder) throws
}

extension CloudPayload {
    /// The payload's bytes as the app writes them (sorted keys, whole-second dates): two payloads are the same when
    /// these are, whatever their in-memory dates hold below a second.
    public var fingerprint: Data {
        (try? InventoryCoding.encoder().encode(CloudData(self))) ?? Data()
    }

    public func same(as other: Self?) -> Bool {
        guard let other else { return false }
        return fingerprint == other.fingerprint
    }
}

/// `data` alone, for encoding.
struct CloudData<P: CloudPayload>: Encodable {
    let payload: P
    init(_ payload: P) { self.payload = payload }
    func encode(to encoder: Encoder) throws { try payload.encodeData(to: encoder) }
}

/// Two optional payloads hold the same thing (both nil: both deleted, or both absent).
func cloudSame<P: CloudPayload>(_ a: P?, _ b: P?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (x?, y): x.same(as: y)
    case (nil, _?): false
    }
}

// MARK: Payloads

extension DeskMark: CloudPayload {
    public var entry: String { "mark" }
    public init(entry: String, from decoder: Decoder) throws { try self.init(from: decoder) }
    public func encodeData(to encoder: Encoder) throws { try encode(to: encoder) }
}

/// A row of `obligations`: one of the owner's entries in obligations.json, or a seed row the app ships.
public enum ObligationCloudPayload: CloudPayload {
    /// An obligation the owner added (`ObligationsFile.added`).
    case row(Obligation)
    /// A row of `ObligationSeed`, sent so the server's sweep knows its date. Never read back into obligations.json.
    case seed(Obligation)
    /// A date the owner set, with its source.
    case date(ObligationDateEntry)
    /// Done with evidence, for one due day.
    case done(ObligationCompletion)

    public var entry: String {
        switch self {
        case .row: "row"
        case .seed: "seed"
        case .date: "date"
        case .done: "done"
        }
    }

    public init(entry: String, from decoder: Decoder) throws {
        switch entry {
        case "row": self = .row(try Obligation(from: decoder))
        case "seed": self = .seed(try Obligation(from: decoder))
        case "date": self = .date(try ObligationDateEntry(from: decoder))
        case "done": self = .done(try ObligationCompletion(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown obligations entry \(entry)"))
        }
    }

    public func encodeData(to encoder: Encoder) throws {
        switch self {
        case .row(let o), .seed(let o): try o.encode(to: encoder)
        case .date(let d): try d.encode(to: encoder)
        case .done(let c): try c.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case entry, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(entry: try c.decode(String.self, forKey: .entry), from: try c.superDecoder(forKey: .data))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entry, forKey: .entry)
        try encodeData(to: c.superEncoder(forKey: .data))
    }
}

/// Everything the owner recorded about one account (renewal, holder, cost), oldest first: `ObligationsFile.accountEdits`
/// for that account.
public struct AccountFacts: Codable, Hashable, Sendable {
    public var edits: [VendorAccountEdit]

    public init(edits: [VendorAccountEdit]) {
        self.edits = edits.sorted { $0.enteredAt < $1.enteredAt }
    }
}

/// A row of `vendors`: an account the owner added, a seed account, or the facts he recorded about an account.
public enum VendorCloudPayload: CloudPayload {
    case account(VendorAccount)
    /// A row of `ObligationSeed.accounts`, sent so the server's sweep knows the account's name. Never read back.
    case seed(VendorAccount)
    case facts(AccountFacts)

    public var entry: String {
        switch self {
        case .account: "account"
        case .seed: "seed"
        case .facts: "facts"
        }
    }

    public init(entry: String, from decoder: Decoder) throws {
        switch entry {
        case "account": self = .account(try VendorAccount(from: decoder))
        case "seed": self = .seed(try VendorAccount(from: decoder))
        case "facts": self = .facts(try AccountFacts(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown vendors entry \(entry)"))
        }
    }

    public func encodeData(to encoder: Encoder) throws {
        switch self {
        case .account(let a), .seed(let a): try a.encode(to: encoder)
        case .facts(let f): try f.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case entry, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(entry: try c.decode(String.self, forKey: .entry), from: try c.superDecoder(forKey: .data))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entry, forKey: .entry)
        try encodeData(to: c.superEncoder(forKey: .data))
    }
}

// MARK: Rows

/// One row as the server holds it (or as this device last agreed with it).
public struct CloudRow<P: CloudPayload>: Codable, Hashable, Sendable {
    public var id: String
    public var entry: String
    /// The obligation or account the row is about (nil for a Desk mark).
    public var key: String?
    public var version: Int64
    /// Nil: a tombstone (the owner undid it).
    public var value: P?
    public var seedRevision: Int?
    public var writtenOn: CloudDevice?
    public var updatedAt: Date?

    public var isDeleted: Bool { value == nil }

    public init(id: String, entry: String, key: String? = nil, version: Int64, value: P?, seedRevision: Int? = nil,
                writtenOn: CloudDevice? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.entry = entry
        self.key = key
        self.version = version
        self.value = value
        self.seedRevision = seedRevision
        self.writtenOn = writtenOn
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, entry, key, version, deleted, data, seedRevision, writtenOn, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entry = try c.decode(String.self, forKey: .entry)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        version = try c.decode(Int64.self, forKey: .version)
        seedRevision = try c.decodeIfPresent(Int.self, forKey: .seedRevision)
        // An unknown device name (a later app) is not a reason to drop the row.
        writtenOn = (try? c.decodeIfPresent(CloudDevice.self, forKey: .writtenOn)) ?? nil
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        let deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        if !deleted, c.contains(.data), !(try c.decodeNil(forKey: .data)) {
            value = try P(entry: entry, from: try c.superDecoder(forKey: .data))
        } else {
            value = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(entry, forKey: .entry)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encode(version, forKey: .version)
        try c.encode(value == nil, forKey: .deleted)
        if let value { try value.encodeData(to: c.superEncoder(forKey: .data)) }
        try c.encodeIfPresent(seedRevision, forKey: .seedRevision)
        try c.encodeIfPresent(writtenOn, forKey: .writtenOn)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

/// One change sent to a push RPC.
public struct CloudChange<P: CloudPayload>: Encodable, Hashable, Sendable {
    public var id: String
    public var entry: String
    public var key: String?
    /// The version the change is based on; 0 for a row the server did not hold.
    public var expectedVersion: Int64
    /// Nil: a tombstone.
    public var value: P?
    public var seedRevision: Int?

    public init(id: String, entry: String, key: String?, expectedVersion: Int64, value: P?, seedRevision: Int? = nil) {
        self.id = id
        self.entry = entry
        self.key = key
        self.expectedVersion = expectedVersion
        self.value = value
        self.seedRevision = seedRevision
    }

    private enum CodingKeys: String, CodingKey { case id, entry, key, expectedVersion, data, seedRevision }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(entry, forKey: .entry)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encode(expectedVersion, forKey: .expectedVersion)
        if let value { try value.encodeData(to: c.superEncoder(forKey: .data)) } else { try c.encodeNil(forKey: .data) }
        try c.encodeIfPresent(seedRevision, forKey: .seedRevision)
    }
}

/// The server's answer to one change.
public struct CloudPushResult<P: CloudPayload>: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable {
        /// Written; `row` is the row as it is now.
        case applied
        /// The row moved on (or was never there for the version named); nothing was written; `row` is what the server holds.
        case stale
        /// Refused by a rule (no source, no evidence, a key pattern); nothing was written; `message` says which.
        case invalid
    }

    public var id: String
    public var status: Status
    public var row: CloudRow<P>?
    public var message: String?
}

/// Decodes every element it can and counts the others (a row of a kind a later app writes), so one row this version
/// can't read never hides the rest.
struct LossyRows<P: CloudPayload>: Decodable, Sendable {
    var rows: [CloudRow<P>] = []
    var skipped = 0

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let row = try? c.decode(CloudRow<P>.self) {
                rows.append(row)
            } else {
                _ = try? c.decode(Skip.self)
                skipped += 1
            }
        }
    }
}

// MARK: The Mac's ledger reading

/// One ledger or NEXT-ACTIONS line as the Mac read it (`desk_items`): what the Desk needs to show it and to match marks,
/// never the lines under it or its detail.
public struct CloudLedgerItem: Codable, Hashable, Sendable {
    public var id: String
    /// "(withheld)" when `titleWithheld`.
    public var title: String
    /// The line held an email address, a phone number or a key, so the Mac did not send its text.
    public var titleWithheld: Bool
    public var domain: String
    public var domainName: String
    /// "high", "normal" or "info".
    public var severity: String
    /// "task" or "source".
    public var kind: String
    public var kindKey: String
    public var subject: String
    public var file: String?
    public var line: Int?
    public var due: KeyDay?
    public var horizon: String?
    public var ownerAction: Bool
    public var factHash: String

    public init(id: String, title: String, titleWithheld: Bool, domain: String, domainName: String, severity: String,
                kind: String, kindKey: String, subject: String, file: String?, line: Int?, due: KeyDay?, horizon: String?,
                ownerAction: Bool, factHash: String) {
        self.id = id
        self.title = title
        self.titleWithheld = titleWithheld
        self.domain = domain
        self.domainName = domainName
        self.severity = severity
        self.kind = kind
        self.kindKey = kindKey
        self.subject = subject
        self.file = file
        self.line = line
        self.due = due
        self.horizon = horizon
        self.ownerAction = ownerAction
        self.factHash = factHash
    }
}

/// One ledger as the Mac read it: its state and counts, for the iPhone's header.
public struct CloudLedgerSource: Codable, Hashable, Sendable {
    /// The allow-list id ("worktrack", "next-actions").
    public var id: String
    public var path: String
    /// "read", "report", "notGranted", "notFound", "unreadable", "notRead" or "unsupported".
    public var state: String
    public var open: Int?
    public var ticked: Int?
    public var today: Int?
    public var thisWeek: Int?
    public var skipped: [Int]?
    /// The review day (a PRIORITIES.md) or the report's day (NEXT-ACTIONS).
    public var day: KeyDay?
    /// Why it could not be read.
    public var reason: String?

    public init(id: String, path: String, state: String, open: Int? = nil, ticked: Int? = nil, today: Int? = nil,
                thisWeek: Int? = nil, skipped: [Int]? = nil, day: KeyDay? = nil, reason: String? = nil) {
        self.id = id
        self.path = path
        self.state = state
        self.open = open
        self.ticked = ticked
        self.today = today
        self.thisWeek = thisWeek
        self.skipped = skipped
        self.day = day
        self.reason = reason
    }
}

/// What the Mac sends: its reading of the ledgers.
public struct CloudLedgerUpload: Codable, Hashable, Sendable {
    public var readAt: Date
    /// SHA-256 (hex) of the items as encoded, so an unchanged reading only moves the time on the server.
    public var digest: String
    public var sources: [CloudLedgerSource]
    public var items: [CloudLedgerItem]

    public init(readAt: Date, sources: [CloudLedgerSource], items: [CloudLedgerItem]) {
        self.readAt = readAt
        self.sources = sources
        self.items = items
        digest = Self.digest(items)
    }

    public static func digest(_ items: [CloudLedgerItem]) -> String {
        let data = (try? InventoryCoding.encoder().encode(items)) ?? Data()
        return DeskSyncHash.sha256Hex(data)
    }
}

/// The Mac's last reading as the server holds it (`desk_ledger_reading` and `desk_items`).
public struct CloudLedgerSnapshot: Codable, Hashable, Sendable {
    public var version: Int64
    /// When the Mac read the files.
    public var readAt: Date
    public var digest: String?
    public var writtenOn: CloudDevice?
    /// When it reached the server.
    public var updatedAt: Date?
    public var sources: [CloudLedgerSource]
    public var items: [CloudLedgerItem]

    public init(version: Int64, readAt: Date, digest: String? = nil, writtenOn: CloudDevice? = .macOS, updatedAt: Date? = nil,
                sources: [CloudLedgerSource], items: [CloudLedgerItem]) {
        self.version = version
        self.readAt = readAt
        self.digest = digest
        self.writtenOn = writtenOn
        self.updatedAt = updatedAt
        self.sources = sources
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case version, readAt, digest, writtenOn, updatedAt, sources, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int64.self, forKey: .version)
        readAt = try c.decode(Date.self, forKey: .readAt)
        digest = try c.decodeIfPresent(String.self, forKey: .digest)
        writtenOn = (try? c.decodeIfPresent(CloudDevice.self, forKey: .writtenOn)) ?? nil
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        sources = (try? c.decode([CloudLedgerSource].self, forKey: .sources)) ?? []
        // A line this version can't read is left out, never the whole reading.
        var items: [CloudLedgerItem] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .items) {
            struct Skip: Decodable {}
            while !list.isAtEnd {
                if let item = try? list.decode(CloudLedgerItem.self) { items.append(item) } else { _ = try? list.decode(Skip.self) }
            }
        }
        self.items = items
    }
}

/// The server's answer to a ledger reading.
public struct CloudLedgerPushResult: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable {
        /// The lines were replaced.
        case applied
        /// The same lines: only the time moved.
        case unchanged
        /// Based on a version the server no longer holds: sent again at the next sync.
        case stale
        /// The server holds a newer reading.
        case older
        case invalid
    }

    public var status: Status
    public var version: Int64?
    public var readAt: Date?
    public var message: String?
}

/// Everything `desk_sync_pull()` answers.
public struct DeskCloudPull: Decodable, Sendable {
    public var serverTime: Date?
    public var marks: [CloudRow<DeskMark>]
    public var obligations: [CloudRow<ObligationCloudPayload>]
    public var vendors: [CloudRow<VendorCloudPayload>]
    public var ledger: CloudLedgerSnapshot?
    /// Rows this version of the app could not read (a kind a later version writes). They are left alone.
    public var unreadable: Int

    public init(serverTime: Date? = nil, marks: [CloudRow<DeskMark>] = [], obligations: [CloudRow<ObligationCloudPayload>] = [],
                vendors: [CloudRow<VendorCloudPayload>] = [], ledger: CloudLedgerSnapshot? = nil, unreadable: Int = 0) {
        self.serverTime = serverTime
        self.marks = marks
        self.obligations = obligations
        self.vendors = vendors
        self.ledger = ledger
        self.unreadable = unreadable
    }

    private enum CodingKeys: String, CodingKey { case serverTime, deskState, obligations, vendors, ledger }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = try c.decodeIfPresent(Date.self, forKey: .serverTime)
        let m = try c.decodeIfPresent(LossyRows<DeskMark>.self, forKey: .deskState)
        let o = try c.decodeIfPresent(LossyRows<ObligationCloudPayload>.self, forKey: .obligations)
        let v = try c.decodeIfPresent(LossyRows<VendorCloudPayload>.self, forKey: .vendors)
        marks = m?.rows ?? []
        obligations = o?.rows ?? []
        vendors = v?.rows ?? []
        unreadable = (m?.skipped ?? 0) + (o?.skipped ?? 0) + (v?.skipped ?? 0)
        ledger = (try? c.decodeIfPresent(CloudLedgerSnapshot.self, forKey: .ledger)) ?? nil
    }
}

// MARK: - Cloud keys

/// The id a Desk item has in the cloud. It is the item's own id, except in the Daily Brief sections that name customers
/// (WorkTrack companies, website messages, licences): there the subject, which is the source's own entry id and can be
/// a readable slug such as a company's name, is replaced by a hash, so no customer's name or id reaches `desk_state`.
/// The server refuses such an id in clear.
public enum DeskCloudKey {
    /// Origins whose subjects are hashed. The same sections whose agent brief leaves the customer out.
    public static let hashedOrigins: Set<String> = ["brief.worktrack", "brief.siteMessages", "brief.licences"]

    public static func cloud(_ id: String) -> String {
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, hashedOrigins.contains(String(parts[0])), !isHashedSubject(parts[1]) else { return id }
        return "\(parts[0])|h-\(DeskHash.of("desk-cloud", String(parts[1])))|\(parts[2])"
    }

    static func isHashedSubject(_ s: Substring) -> Bool {
        s.count == 18 && s.hasPrefix("h-") && s.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Whether `id` is already a cloud key that stands for another id (a hashed subject).
    public static func isHashed(_ id: String) -> Bool {
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 && hashedOrigins.contains(String(parts[0])) && isHashedSubject(parts[1])
    }
}

/// SHA-256 in hex, for the ledger digest.
enum DeskSyncHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
