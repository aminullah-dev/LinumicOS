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

    /// The owner's list: only Linumic OS, KhayatYar and WorkTrack are in focus; DukanPro is archived and off this Mac.
    public static func `default`(forProduct id: String) -> CenterTier {
        switch id {
        case "linumicos", "khayatyar", "worktrack": .focus
        case "dukanpro": .archived
        default: .maintenance
        }
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
}

public struct CenterProject: Hashable, Sendable, Identifiable {
    public var card: ProductCard
    public var tier: CenterTier
    /// Open rows of this product on the Desk that the owner has to act on.
    public var waiting: [DeskRow]
    public var attention: [CenterAttention]

    public var id: String { card.id }
    public var hasProblem: Bool { !attention.isEmpty }

    /// Neither CI nor health could be read, so "no known problem" says little about this project.
    public var isUnread: Bool { card.ci.isUnknown && card.health.isUnknown }
}

public struct CenterReport: Hashable, Sendable {
    /// Open Desk rows, today first, that say the owner has to act.
    public var waiting: [DeskRow]
    /// Other rows due today: true, but not the owner's to do.
    public var alsoToday: [DeskRow]
    /// Always shown, in the catalog's order.
    public var focus: [CenterProject]
    /// Maintenance projects with a known problem or something waiting.
    public var maintenanceAttention: [CenterProject]
    /// Maintenance projects with no known problem.
    public var maintenanceQuiet: [CenterProject]

    /// Projects with something known to be wrong, in any shown tier.
    public var problemCount: Int { (focus + maintenanceAttention).count(where: \.hasProblem) }
}

public enum CenterBuilder {
    public static func build(desk: Desk, products: ProductsReport,
                             tier: (String) -> CenterTier = CenterTier.default(forProduct:)) -> CenterReport {
        let open = desk.today + desk.thisWeek
        let waiting = open.filter(\.item.ownerAction)
        let alsoToday = desk.today.filter { !$0.item.ownerAction }

        var focus: [CenterProject] = []
        var attention: [CenterProject] = []
        var quiet: [CenterProject] = []
        for card in products.cards {
            let projectTier = tier(card.id)
            let project = CenterProject(card: card, tier: projectTier,
                                        waiting: waiting.filter { $0.item.domain == card.product.deskDomain },
                                        attention: attentions(card))
            switch projectTier {
            case .focus: focus.append(project)
            case .archived: break
            case .maintenance:
                if project.hasProblem || !project.waiting.isEmpty { attention.append(project) } else { quiet.append(project) }
            }
        }
        // The worst first: a project that is down outranks one with a failing test.
        attention.sort { rank($0) < rank($1) }
        return CenterReport(waiting: waiting, alsoToday: alsoToday, focus: focus, maintenanceAttention: attention, maintenanceQuiet: quiet)
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
