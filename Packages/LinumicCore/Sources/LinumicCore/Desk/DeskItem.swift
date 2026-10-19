import CryptoKit
import Foundation

// MARK: - Desk (میز کار)
//
// One list of what needs the owner, built on this device from what the app already holds: the Daily Brief (Monitor,
// Releases, Licences, WorkTrack, Operations, Keys, …) and the owner's ledgers (the PRIORITIES.md files and the newest
// NEXT-ACTIONS, read-only). Everything here is a plain value; the App collects the inputs and keeps only the owner's
// marks (Done, Snooze, Waiting on others, Dismiss) in `desk-state.json`. A source that was not read is itself an item,
// never a zero.

/// The product (or area) an item belongs to: the pill on each row and the grouping on the Desk.
public struct DeskDomain: Hashable, Codable, Sendable, Identifiable {
    /// Stable key ("worktrack"). Names the Desk does not know keep their own name under "other:<name>".
    public let key: String
    /// The product's own name (a name of record, never translated). See `displayTitle` for the shared domain.
    public let name: String

    public var id: String { key }

    public init(_ key: String, _ name: String) {
        self.key = key
        self.name = name
    }

    // The key is the identity: two spellings of one unknown product ("Signing Keys", "Signing-Keys") are the same
    // domain, so the Desk makes one group of them (keeping the first name seen) and never two rows with one id.
    public static func == (a: DeskDomain, b: DeskDomain) -> Bool { a.key == b.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    public static let worktrack = DeskDomain("worktrack", "WorkTrack")
    public static let safeBeauty = DeskDomain("safebeauty", "SafeBeauty")
    public static let talar = DeskDomain("talar", "Talar")
    public static let velro = DeskDomain("velro", "VELRO")
    public static let dukanPro = DeskDomain("dukanpro", "DukanPro")
    public static let linumicOS = DeskDomain("linumicos", "Linumic OS")
    public static let bePaya = DeskDomain("bepaya", "BE-PAYA")
    public static let website = DeskDomain("linumic.com", "linumic.com")
    public static let mediflow = DeskDomain("mediflow", "MediFlow")
    public static let khayatYar = DeskDomain("khayatyar", "KhayatYar")
    public static let nerkhTimes = DeskDomain("nerkhtimes", "NerkhTimes")
    public static let namazia = DeskDomain("namazia", "Namazia")
    /// What belongs to every product or to none: the shared ledger, Oversight, an unnamed source.
    public static let shared = DeskDomain("shared", "All products")

    /// The products the company sells first, in order (roadmap §1: WorkTrack, then SafeBeauty).
    public static let focus: [DeskDomain] = [.worktrack, .safeBeauty]

    public var isFocus: Bool { Self.focus.contains(self) }

    /// The title to show: the product's own name, or "All products" in the app's language.
    public var displayTitle: String { self == .shared ? L("All products") : name }

    static let known: [DeskDomain] = [.worktrack, .safeBeauty, .talar, .velro, .dukanPro, .linumicOS, .bePaya, .website,
                                      .mediflow, .khayatYar, .nerkhTimes, .namazia]

    /// Spellings of record (folder, repository and app names), compared without case, spaces, dashes, dots or underscores.
    static let aliases: [String: DeskDomain] = {
        var map: [String: DeskDomain] = [:]
        for d in known { map[normalized(d.name)] = d }
        map["linumiccommandcenter"] = .linumicOS
        map["website"] = .website
        map["afghanjama"] = .khayatYar
        map["afghanprayertimes"] = .namazia
        // Repository slugs that don't carry the product's name (the Release Center names lines by repository).
        map["stealthservicevault"] = .safeBeauty
        map["talarreleases"] = .talar
        return map
    }()

    /// Lower-cased, without spaces, dashes, dots, underscores or zero-width non-joiners (by Unicode scalar).
    static func normalized(_ s: String) -> String {
        let drop = Set(" -._\u{200C}".unicodeScalars)
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where !drop.contains(u) { out.append(u) }
        return String(out)
    }

    /// The domain a name of record refers to: a known product by its exact name (ignoring case, spaces, dashes and
    /// dots), the last part of a repository slug ("aminullah-dev/WorkTrack"), or a known product name followed by more
    /// words ("VELRO Driver"). Any other name keeps its own name; nothing is guessed. Nil or empty is `shared`.
    public static func named(_ raw: String?) -> DeskDomain {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .shared }
        if let slash = text.lastIndex(of: "/"), !text.contains(" ") { text = String(text[text.index(after: slash)...]) }
        if let d = aliases[normalized(text)] { return d }
        let words = text.split(whereSeparator: { $0.isWhitespace || ":·(),،".contains($0) }).map(String.init)
        for n in stride(from: min(3, words.count), through: 1, by: -1) {
            if let d = aliases[normalized(words.prefix(n).joined())] { return d }
        }
        return DeskDomain("other:\(normalized(text))", text)
    }

    /// Focus products first (in focus order), then the others by name, then the shared domain.
    public static func order(_ a: DeskDomain, _ b: DeskDomain) -> Bool {
        func rank(_ d: DeskDomain) -> (Int, Int, String) {
            if let i = focus.firstIndex(of: d) { return (0, i, d.name) }
            if d == .shared { return (2, 0, "") }
            return (1, 0, d.name.lowercased())
        }
        return rank(a) < rank(b)
    }
}

/// Where an item comes from. Its key starts the item id.
public enum DeskOrigin: Hashable, Sendable {
    /// A line (or an unread section) of the Daily Brief.
    case brief(BriefSourceKind)
    /// One of the allow-listed PRIORITIES.md files, by its allow-list id.
    case ledger(String)
    /// The newest NEXT-ACTIONS file.
    case nextActions

    public var key: String {
        switch self {
        case .brief(let kind): "brief.\(kind.rawValue)"
        case .ledger(let id): "ledger.\(id)"
        case .nextActions: "next-actions"
        }
    }
}

/// What an item is, which decides what Done means for it.
public enum DeskItemKind: String, Sendable, Hashable {
    /// A fact the app read (a Brief line). Done lasts until the next reading.
    case fact
    /// A line of a ledger (PRIORITIES.md or NEXT-ACTIONS). Done lasts until that line changes in the file.
    case task
    /// A source that could not be read, was not found, or is out of date. Done lasts until the next reading.
    case source
}

/// The horizon a source gives an item itself (NEXT-ACTIONS "TODAY" and "THIS WEEK").
public enum DeskHorizon: String, Sendable, Hashable {
    case today, thisWeek
}

/// The three lists of the Desk.
public enum DeskBucket: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// High severity, due today or earlier, or the owner's own work in a focus product.
    case today
    case thisWeek
    /// Shown collapsed.
    case later

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: L("Today")
        case .thisWeek: L("This week")
        case .later: L("Later")
        }
    }
}

/// Where an item was read, and when.
public struct DeskEvidence: Hashable, Sendable {
    /// What the source is called ("Monitor checks on this device (monitor.json)", "WorkTrack/PRIORITIES.md").
    public var source: String
    /// Home-relative file ("~/Projects/Multiplatform/WorkTrack/PRIORITIES.md") for ledger items.
    public var file: String?
    /// 1-based line in `file`.
    public var line: Int?
    /// When the fact or the file was read. Nil when the source does not say.
    public var readAt: Date?
    /// How often the source is normally read; an item older than twice this is "stale".
    public var cadence: TimeInterval?

    public init(source: String, file: String? = nil, line: Int? = nil, readAt: Date?, cadence: TimeInterval? = nil) {
        self.source = source
        self.file = file
        self.line = line
        self.readAt = readAt
        self.cadence = cadence
    }

    /// "~/…/PRIORITIES.md:42", the file alone, or the source's name.
    public var location: String {
        guard let file else { return source }
        return line.map { "\(file):\($0)" } ?? file
    }

    public func isStale(now: Date) -> Bool {
        guard let readAt, let cadence else { return false }
        return now.timeIntervalSince(readAt) > 2 * cadence
    }
}

/// What the row's Open button does.
public enum DeskDestination: Hashable, Sendable {
    /// A screen of the app, through the Daily Brief's routing.
    case screen(BriefDestination)
    /// A ledger file at a line (home-relative path).
    case file(path: String, line: Int?)
    /// The "Ledger access" card in Settings, where the folders are granted.
    case ledgerAccess
}

/// One thing on the Desk. Its id is "<origin>|<subjectKey>|<kindKey>" and stays the same between readings, so the
/// owner's marks follow it.
public struct DeskItem: Identifiable, Hashable, Sendable {
    public var origin: DeskOrigin
    public var subjectKey: String
    public var kindKey: String
    public var kind: DeskItemKind
    public var domain: DeskDomain
    public var severity: BriefSeverity
    public var title: String
    public var detail: String?
    /// What it is about, as the source names it: a product, an app, "WorkTrack / first-customer-contract", a section.
    public var subject: String
    public var due: KeyDay?
    public var horizon: DeskHorizon?
    /// The source says the owner has to act (a Brief "needs you" line, a NEXT-ACTIONS owner task, a missing grant).
    public var ownerAction: Bool
    public var evidence: DeskEvidence
    /// Changes when the fact itself changes (the ledger line's text and the lines under it, a Brief line's subject and
    /// severity).
    public var factHash: String
    public var destination: DeskDestination
    /// The lines the ledger keeps indented under the item, as written (its own dated corrections among them).
    public var notes: [String]
    /// Other products the source names for the same item (a NEXT-ACTIONS «منبع» line with several products).
    public var related: [DeskDomain]
    /// The source's own reference line, as written (the NEXT-ACTIONS «منبع: …» text).
    public var reference: String?
    /// The obligation an item of the Obligations section is about. Its Done opens the evidence sheet: an obligation is
    /// never done on the Desk's word alone.
    public var obligationID: String?
    /// A live obligation: its Done goes to the screen of its source (Continuity, Keys & Backups, the licence, the
    /// Monitor), where what closes it is recorded.
    public var closesAtSource: Bool
    /// Read on another device and taken from the cloud (the Mac's ledger reading on an iPhone); nil: read here.
    public var readOn: CloudDevice?

    public var id: String { "\(origin.key)|\(subjectKey)|\(kindKey)" }

    /// The kinds of source item that say a source was not read: their time is when it was tried, not a reading.
    public static let notReadKinds: Set<String> = ["not-read", "not-granted", "not-found", "unreadable", "unavailable"]

    /// False for a source item that says its source was not read, so its time reads "checked", not "read".
    public var wasRead: Bool { !(kind == .source && Self.notReadKinds.contains(kindKey)) }

    /// The notes that correct or date the item: they start with a day, or say «اصلاح» or «درست نیست».
    public var corrections: [String] { notes.filter(LedgerText.isCorrection) }

    public init(origin: DeskOrigin, subjectKey: String, kindKey: String, kind: DeskItemKind, domain: DeskDomain,
                severity: BriefSeverity, title: String, detail: String? = nil, subject: String, due: KeyDay? = nil,
                horizon: DeskHorizon? = nil, ownerAction: Bool, evidence: DeskEvidence, factHash: String,
                destination: DeskDestination, notes: [String] = [], related: [DeskDomain] = [], reference: String? = nil,
                obligationID: String? = nil, closesAtSource: Bool = false, readOn: CloudDevice? = nil) {
        self.origin = origin
        self.subjectKey = subjectKey
        self.kindKey = kindKey
        self.kind = kind
        self.domain = domain
        self.severity = severity
        self.title = title
        self.detail = detail
        self.subject = subject
        self.due = due
        self.horizon = horizon
        self.ownerAction = ownerAction
        self.evidence = evidence
        self.factHash = factHash
        self.destination = destination
        self.notes = notes
        self.related = related
        self.reference = reference
        self.obligationID = obligationID
        self.closesAtSource = closesAtSource
        self.readOn = readOn
    }

    /// The origin part of an item id ("ledger.worktrack|…" → "ledger.worktrack").
    public static func originKey(ofID id: String) -> String {
        String(id.prefix { $0 != "|" })
    }
}

/// A short, stable hash for item ids and fact hashes: the first 8 bytes of SHA-256, in hex. Unlike `Hasher`, it is the
/// same in every launch, so marks saved today still match tomorrow.
public enum DeskHash {
    public static func of(_ parts: String...) -> String { of(parts) }

    public static func of(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
