import Foundation

// MARK: - The management centre (مرکز مدیریت)
//
// The home page answers three questions in one look: what is waiting on the owner, which project has a problem, and
// which readings can't be trusted. It reads nothing itself: it arranges what the Desk and the Products page already
// built, so a fact has one source and the three pages can't disagree. Pure, so it is tested without the app.

/// How much of the owner's attention a project gets. Set by the owner's focus (2026-10-21), not derived from its state.
public enum CenterTier: String, Codable, CaseIterable, Sendable, Hashable {
    /// Shown in full, always.
    case focus
    /// Shown only when something is known to be wrong.
    case maintenance
    /// Not shown on the centre.
    case archived

    /// The owner's list: only Linumic OS, KhayatYar and WorkTrack are in focus. DukanPro is archived and off this Mac; the
    /// book is finished, Tailoring Workshop ERP is sidelined for KhayatYar, and the Pashto research ships no app.
    public static func `default`(forProduct id: String) -> CenterTier {
        switch id {
        case "linumicos", "khayatyar", "worktrack": .focus
        case "dukanpro", "soder-hakem", "tailoring-workshop-erp", "the-digital-infrastructure-of-the-pashto-language": .archived
        default: .maintenance
        }
    }

    public var title: String {
        switch self {
        case .focus: L("In focus")
        case .maintenance: L("Maintenance")
        case .archived: L("Archive")
        }
    }
}

/// The owner's choices of tier, one per project that differs from the default. Only choices are kept, so a project with
/// none follows the default if it changes.
public struct ProjectTiers: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion = ProjectTiers.currentSchemaVersion
    public private(set) var chosen: [String: CenterTier] = [:]

    public init() {}

    public func tier(forProduct id: String) -> CenterTier { chosen[id] ?? CenterTier.default(forProduct: id) }

    /// Choosing the default clears the choice.
    public mutating func set(_ tier: CenterTier, forProduct id: String) {
        chosen[id] = tier == CenterTier.default(forProduct: id) ? nil : tier
    }
}

public struct ProjectTiersStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "project-tiers.json")
    }

    /// A missing or unreadable file is no choices: the defaults still give a working page.
    public func load() -> ProjectTiers {
        guard let data = try? Data(contentsOf: fileURL) else { return ProjectTiers() }
        return (try? InventoryCoding.decoder().decode(ProjectTiers.self, from: data)) ?? ProjectTiers()
    }

    public func save(_ tiers: ProjectTiers) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(tiers).write(to: fileURL, options: [.atomic])
    }
}

/// Something known to be wrong with a project. A value that was not read is never one of these: unread is shown as
/// unknown, not as a problem and not as fine.
public struct CenterAttention: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case healthDown, ciFailing, licenceExpired, notLevel, healthDegraded, licenceExpiring
    }

    public var kind: Kind
    public var text: String
    public var id: Kind { kind }

    /// Something is broken or about to be. Versions that differ between platforms are worth a look but aren't a fault.
    public var isSerious: Bool {
        switch kind {
        case .healthDown, .ciFailing, .licenceExpired: true
        case .healthDegraded, .licenceExpiring, .notLevel: false
        }
    }
}

public struct CenterProject: Hashable, Sendable, Identifiable {
    public var card: ProductCard
    public var tier: CenterTier
    /// Open rows of this product on the Desk that the owner has to act on.
    public var waiting: [DeskRow]
    public var attention: [CenterAttention]

    public var id: String { card.id }
    /// Something to look at, serious or not: it lifts a maintenance project onto the page.
    public var needsLook: Bool { !attention.isEmpty }
    /// Something broken: what the page counts as a problem.
    public var hasProblem: Bool { attention.contains(where: \.isSerious) }

    /// Neither CI nor health could be read, so "no known problem" says little about this project.
    public var isUnread: Bool { card.ci.isUnknown && card.health.isUnknown }
}

/// One ledger and the day it was last reviewed.
public struct CenterLedgerReview: Hashable, Sendable, Identifiable {
    public var path: String
    public var reviewedOn: KeyDay
    public var id: String { path }
}

public struct CenterReport: Hashable, Sendable {
    /// Open Desk rows, the worst first, that say the owner has to act. Pull requests and agents' reviews aren't here: one
    /// row each would bury everything else, so they are counted in `pullRows`.
    public var waiting: [DeskRow]
    /// Pull requests ready to merge and agents' reviews, shown as one line that opens Releases.
    public var pullRows: [DeskRow] = []
    /// Agents with no pull request for too long, one Desk row each. Alike, and often several at once (four WorkTrack
    /// agents go quiet together), so the centre shows them as one line that opens Agents.
    public var quietAgentRows: [DeskRow] = []
    /// Other rows due today: true, but not the owner's to do.
    public var alsoToday: [DeskRow]
    /// Always shown, in the catalog's order.
    public var focus: [CenterProject]
    /// Maintenance projects with a known problem or something waiting.
    public var maintenanceAttention: [CenterProject]
    /// Maintenance projects with no known problem.
    public var maintenanceQuiet: [CenterProject]

    /// Ledgers not reviewed for `CenterBuilder.reviewAfterDays`, oldest first. Their open items may already be done, so
    /// this says why a long waiting list can't be taken at its word. A ledger with no review day isn't listed: unknown.
    public var overdueLedgers: [CenterLedgerReview] = []

    /// Projects with something known to be wrong, in any shown tier.
    public var problemCount: Int { (focus + maintenanceAttention).count(where: \.hasProblem) }

    /// Nothing to look at: nothing waits on the owner (no row, no pull request, no quiet agent), no project has a
    /// problem or needs a look, every ledger is reviewed, and every reading is current (`staleSources`, from the
    /// automation log). Only then does the centre say "All clear"; a reading that is old or missing never is.
    public func isAllClear(staleSources: Int) -> Bool {
        waiting.isEmpty && pullRows.isEmpty && quietAgentRows.isEmpty && maintenanceAttention.isEmpty && problemCount == 0
            && overdueLedgers.isEmpty && staleSources == 0
    }
}

public enum CenterBuilder {
    /// The owner's weekly review: a ledger older than this is due.
    public static let reviewAfterDays = 7

    public static func build(desk: Desk, products: ProductsReport, today: KeyDay? = nil,
                             tier: (String) -> CenterTier = CenterTier.default(forProduct:)) -> CenterReport {
        // The worst first, then as the Desk lists them: red never sits below amber on the first screen.
        let open = desk.today + desk.thisWeek
        let owner = open.enumerated().filter(\.element.item.ownerAction)
            .sorted { ($0.element.item.severity.rawValue, $0.offset) < ($1.element.item.severity.rawValue, $1.offset) }
            .map(\.element)
        let waiting = owner.filter { !isPullRow($0) && !isQuietAgentRow($0) }
        let pullRows = owner.filter(isPullRow)
        let quietAgentRows = owner.filter(isQuietAgentRow)
        let alsoToday = desk.today.filter { !$0.item.ownerAction }

        var focus: [CenterProject] = []
        var attention: [CenterProject] = []
        var quiet: [CenterProject] = []
        for card in products.cards {
            let projectTier = tier(card.id)
            let project = CenterProject(card: card, tier: projectTier,
                                        waiting: owner.filter { $0.item.domain == card.product.deskDomain },
                                        attention: attentions(card))
            switch projectTier {
            case .focus: focus.append(project)
            case .archived: break
            case .maintenance:
                if project.needsLook || !project.waiting.isEmpty { attention.append(project) } else { quiet.append(project) }
            }
        }
        // The worst first: a project that is down outranks one with a failing test.
        attention.sort { rank($0) < rank($1) }
        return CenterReport(waiting: waiting, pullRows: pullRows, quietAgentRows: quietAgentRows, alsoToday: alsoToday, focus: focus,
                            maintenanceAttention: attention, maintenanceQuiet: quiet, overdueLedgers: overdueLedgers(desk, today: today))
    }

    /// A Desk row that comes from a pull request waiting to merge or an agent's pull requests waiting for review.
    static func isPullRow(_ row: DeskRow) -> Bool {
        let key = row.item.subjectKey
        return key.hasPrefix("agents.waiting") || ["pullReady|", "stackReady|", "dependencyUpdatesReady|"].contains { key.contains($0) }
    }

    /// A Desk row that says an agent has opened no pull request for too long (`AgentsBrief`, `agents.quiet.<slug>`).
    public static func isQuietAgentRow(_ row: DeskRow) -> Bool { row.item.subjectKey.hasPrefix("agents.quiet.") }

    static func overdueLedgers(_ desk: Desk, today: KeyDay?) -> [CenterLedgerReview] {
        guard let today else { return [] }
        return desk.sources.compactMap { source -> CenterLedgerReview? in
            guard case .read(_, _, _, let reviewedOn?) = source.state, reviewedOn.days(until: today) > reviewAfterDays else { return nil }
            return CenterLedgerReview(path: source.displayPath, reviewedOn: reviewedOn)
        }
        .sorted { ($0.reviewedOn, $0.path) < ($1.reviewedOn, $1.path) }
    }

    static func attentions(_ card: ProductCard) -> [CenterAttention] {
        var out: [CenterAttention] = []
        if let health = card.health.value {
            if health.down > 0 { out.append(CenterAttention(kind: .healthDown, text: LF("%d checks down", health.down))) }
            if health.degraded > 0 { out.append(CenterAttention(kind: .healthDegraded, text: LF("%d checks degraded", health.degraded))) }
        }
        if let failing = card.ci.value?.failing, !failing.isEmpty {
            out.append(CenterAttention(kind: .ciFailing, text: LF("CI failing: %@", failing.joined(separator: ", "))))
        }
        if let licences = card.licences?.value {
            if licences.expired > 0 { out.append(CenterAttention(kind: .licenceExpired, text: LF("%d licences expired", licences.expired))) }
            if licences.expiringSoon > 0 { out.append(CenterAttention(kind: .licenceExpiring, text: LF("%d licences expiring soon", licences.expiringSoon))) }
        }
        if case .notLevel(let findings) = card.level {
            out.append(CenterAttention(kind: .notLevel, text: LF("Platforms not level: %d", findings.count)))
        }
        return out.sorted { order($0.kind) < order($1.kind) }
    }

    private static func order(_ kind: CenterAttention.Kind) -> Int {
        switch kind {
        case .healthDown: 0
        case .ciFailing: 1
        case .licenceExpired: 2
        case .healthDegraded: 3
        case .licenceExpiring: 4
        case .notLevel: 5
        }
    }

    private static func rank(_ project: CenterProject) -> Int {
        project.attention.map { order($0.kind) }.min() ?? 6
    }
}
