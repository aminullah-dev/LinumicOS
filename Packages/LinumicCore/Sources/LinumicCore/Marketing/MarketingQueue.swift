import Foundation

// MARK: - Marketing queue (صف بازاریابی), read-only, never posts
//
// Module 8 of docs/company-os-roadmap.md. The end of each brand's scheduled queue and the US clock change on 2026-11-01
// are obligations of the register (area .marketing, `ObligationSeed`, each with its source), so they reach the Desk,
// the alerts and the server's sweep like any other. This page groups them by brand beside the brand's own marketing
// ledger. The app never parses a ledger's text: it reads the file's modification date (metadata only), says when the
// ledger changed after a date was recorded, and opens the ledger in its own app when the owner presses Verify, inside a
// read-only grant of that ledger's folder. The owner then corrects the date or records Done on the Obligations screen.

/// One brand's marketing ledger: where the owner keeps what is scheduled and posted.
public struct MarketingLedger: Hashable, Sendable, Identifiable {
    public let id: String
    /// The brand, as the obligations name their product ("WorkTrack").
    public let brand: String
    /// The ledger's folder, home-relative: the only folder a grant for it may cover.
    public let folder: String
    /// The ledger file, home-relative, inside `folder`.
    public let file: String
    /// Where this ledger is named as the brand's ledger.
    public let source: String

    public init(id: String, brand: String, folder: String, file: String, source: String) {
        self.id = id
        self.brand = brand
        self.folder = folder
        self.file = file
        self.source = source
    }

    public var displayFile: String { "~/\(file)" }
    public var displayFolder: String { "~/\(folder)" }
}

public enum MarketingLedgers {
    static let memory = "~/.claude/projects/-Users-aminullahhashemi/memory"

    /// The brands whose ledgers are recorded, focus first (WorkTrack, then SafeBeauty).
    public static let all: [MarketingLedger] = [
        MarketingLedger(id: "worktrack", brand: "WorkTrack", folder: "Desktop/1/WorkTrack-Marketing",
                        file: "Desktop/1/WorkTrack-Marketing/Social/index.html",
                        source: "\(memory)/worktrack-marketing.md:13 (Social/: ready, scheduled, published, archive; the dashboard index.html)"),
        MarketingLedger(id: "safebeauty", brand: "SafeBeauty", folder: "Desktop/1/SafeBeauty-Marketing",
                        file: "Desktop/1/SafeBeauty-Marketing/STATUS.md",
                        source: "\(memory)/safebeauty-marketing.md:55, :57 (the ledger ~/Desktop/1/SafeBeauty-Marketing/STATUS.md)"),
        MarketingLedger(id: "velro", brand: "VELRO", folder: "Desktop/1/Marketing/Velro",
                        file: "Desktop/1/Marketing/Velro/01-plan/content-calendar.md",
                        source: "\(memory)/velro-marketing.md:13 (the working folder), :35 (the calendar 01-plan/content-calendar.md)"),
    ]

    public static func ledger(forBrand brand: String?) -> MarketingLedger? {
        guard let brand else { return nil }
        let domain = DeskDomain.named(brand)
        return all.first { DeskDomain.named($0.brand) == domain }
    }

    /// Whether a folder the owner picked may be kept as a grant for Verify: exactly one of the ledgers' folders, never
    /// a wider one (~/Desktop/1 also holds the Asasnama drafts and much else).
    public static func decide(_ chosen: String, home: String) -> LegalGrantDecision {
        let path = LegalAccessRules.standardized(chosen)
        let allowed = all.map { LegalAccessRules.standardized(KeyPaths.expand("~/\($0.folder)", home: home)) }
        return allowed.contains(path)
            ? .accept
            : .refuse(LF("Only a marketing ledger's own folder is accepted (%@), so nothing was saved.", all.map(\.displayFolder).joined(separator: ", ")))
    }

    /// The ledger whose folder holds `path` (absolute), when there is one.
    public static func ledger(containing path: String, home: String) -> MarketingLedger? {
        all.first { KeyPaths.isInside(path, root: KeyPaths.expand("~/\($0.folder)", home: home)) }
    }
}

/// A ledger file's modification date, read from its metadata only (the sandbox allows that without a grant).
public enum MarketingLedgerFile: Hashable, Sendable {
    case modified(Date)
    case missing
    /// It could not be checked; the reason as shown.
    case unknown(String)

    public var modifiedAt: Date? { if case .modified(let d) = self { d } else { nil } }
}

/// One brand on the Marketing queue page.
public struct MarketingQueueBrand: Hashable, Sendable, Identifiable {
    /// Nil for the marketing obligations of a brand with no recorded ledger.
    public var ledger: MarketingLedger?
    public var brand: String
    /// Its marketing obligations, open first by due day, then those whose date is unknown, then the done ones.
    public var obligations: [Obligation]
    public var file: MarketingLedgerFile?
    /// Obligations whose ledger changed on a later day than the date was recorded: to verify.
    public var changedSince: Set<String>

    public var id: String { ledger?.id ?? "other:\(brand)" }
}

public enum MarketingQueue {
    /// Groups the register's marketing obligations by brand, beside each recorded ledger (every ledger is listed, with
    /// or without obligations, so a brand whose queue is not recorded still shows). `files` are the ledgers' dates by
    /// ledger id; `dateEnteredOn` the day the owner set an obligation's date, when he did (that day stands for the
    /// "recorded" day of a date he verified).
    public static func build(register: ObligationsRegister, files: [String: MarketingLedgerFile],
                             dateEnteredOn: [String: KeyDay] = [:], calendar: Calendar = KeyDay.calendar) -> [MarketingQueueBrand] {
        let rows = register.obligations.filter { $0.area == .marketing }
        var out: [MarketingQueueBrand] = MarketingLedgers.all.map { ledger in
            let mine = rows.filter { MarketingLedgers.ledger(forBrand: $0.product) == ledger }
            let file = files[ledger.id]
            return MarketingQueueBrand(ledger: ledger, brand: ledger.brand, obligations: ordered(mine), file: file,
                                       changedSince: changed(mine, file: file, dateEnteredOn: dateEnteredOn, calendar: calendar))
        }
        let others = rows.filter { MarketingLedgers.ledger(forBrand: $0.product) == nil }
        for brand in Array(Set(others.map { $0.product ?? "" })).sorted() {
            let mine = others.filter { ($0.product ?? "") == brand }
            out.append(MarketingQueueBrand(ledger: nil, brand: brand, obligations: ordered(mine), file: nil, changedSince: []))
        }
        return out
    }

    static func ordered(_ rows: [Obligation]) -> [Obligation] {
        rows.sorted { a, b in
            if a.isClosed != b.isClosed { return !a.isClosed }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.id < b.id
            }
        }
    }

    /// An open obligation whose ledger was modified on a later day than its date was recorded (or entered by the owner)
    /// may be out of date: the ledger may have moved it. Only the dates are compared; the ledger is never read.
    public static func changed(_ rows: [Obligation], file: MarketingLedgerFile?, dateEnteredOn: [String: KeyDay],
                               calendar: Calendar = KeyDay.calendar) -> Set<String> {
        guard let modified = file?.modifiedAt else { return [] }
        let day = KeyDay(modified, calendar: calendar)
        return Set(rows.filter { o in
            guard !o.isClosed, let recorded = dateEnteredOn[o.id] ?? o.recordedOn else { return false }
            return day > recorded
        }.map(\.id))
    }
}
