import Foundation

// MARK: - The Marketing page (بازاریابی): every marketing item in one place
//
// The owner, 2026-11-13: "Open a Marketing section. Show every marketing item there and remove it from everywhere else.
// Don't make the app cluttered." Marketing obligations (the queue ends, the clock change: area .marketing) stay in the
// obligations register as they were, with their dates, Done marks and sources; nothing stored changes. What changes is
// where they are shown: on the Marketing page only. The Daily Brief (and so the Desk and the Center), the Obligations
// page, the project cards and the readiness checks leave them out (`MarketingScope`). The Center keeps one quiet line
// when some are overdue (`MarketingSummary.overdue`), so an overdue post is never invisible.

/// The parts of the Marketing page. One page, three tabs: the queue is what needs the owner; posts and research are
/// records he keeps by hand.
public enum MarketingTab: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// Each brand's scheduled queue: its end, the clock change (marketing obligations), beside its ledger.
    case queue
    /// The content calendar (drafts, approval, schedule) and the social accounts recorded per product.
    case posts
    /// Market intelligence: sources, evidence and findings.
    case research

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .queue: L("Queue")
        case .posts: L("Posts")
        case .research: L("Market research")
        }
    }

    /// The page each tab replaces (the sidebar's page ids before 2026-11-13), so a saved or typed link to an old page
    /// still opens: the Marketing page on the tab that holds it. Nil for any other id.
    public static func replacing(pageID: String) -> MarketingTab? {
        switch pageID {
        case "marketingQueue": .queue
        case "contentCalendar", "socialMedia": .posts
        case "marketIntelligence": .research
        default: nil
        }
    }

    /// The page ids folded into the Marketing page.
    public static let replacedPageIDs = ["marketingQueue", "contentCalendar", "socialMedia", "marketIntelligence"]
}

/// What belongs on the Marketing page and nowhere else.
public enum MarketingScope {
    public static func isMarketing(_ o: Obligation) -> Bool { o.area == .marketing }

    /// The register without its marketing obligations: what the Obligations page and the readiness checks are built from.
    /// Accounts, issues and unread sources are kept as they are.
    public static func withoutMarketing(_ register: ObligationsRegister) -> ObligationsRegister {
        var out = register
        out.obligations = register.obligations.filter { !isMarketing($0) }
        return out
    }

    /// The register's marketing obligations, in its order (by due day).
    public static func marketing(_ register: ObligationsRegister) -> [Obligation] {
        register.obligations.filter(isMarketing)
    }
}

/// The marketing obligations counted for the page's header and the Center's one line.
public struct MarketingSummary: Hashable, Sendable {
    /// Open and past their day.
    public var overdue: Int
    /// Open and due today or within 7 days.
    public var dueThisWeek: Int
    /// Open with no date recorded: unknown, never "nothing".
    public var dateUnknown: Int
    public var open: Int
    public var done: Int

    public init(register: ObligationsRegister, today: KeyDay) {
        let rows = MarketingScope.marketing(register)
        var overdue = 0, week = 0, unknown = 0
        for o in rows where !o.isClosed {
            switch ObligationRules.lane(o, today: today) {
            case .overdue: overdue += 1
            case .week: week += 1
            case .dateUnknown: unknown += 1
            default: break
            }
        }
        self.overdue = overdue
        self.dueThisWeek = week
        self.dateUnknown = unknown
        self.open = rows.count { !$0.isClosed }
        self.done = rows.count(where: \.isClosed)
    }
}

extension MarketingQueue {
    /// The brands as the page lists them: the one whose oldest open row is furthest overdue first, then those with a
    /// row due soonest, then those whose dates are all unknown, then the rest; brands that tie keep the ledgers' order
    /// (WorkTrack, then SafeBeauty, then VELRO). Within a brand the rows are already open first by due day, so its
    /// overdue rows lead.
    public static func urgentFirst(_ brands: [MarketingQueueBrand], today: KeyDay) -> [MarketingQueueBrand] {
        func rank(_ b: MarketingQueueBrand) -> (Int, Int) {
            let open = b.obligations.filter { !$0.isClosed }
            if let due = open.compactMap(\.due).min() {
                let left = today.days(until: due)
                return (left < 0 ? 0 : 1, left)
            }
            return (open.isEmpty ? 3 : 2, 0)
        }
        return brands.enumerated()
            .sorted { (rank($0.element).0, rank($0.element).1, $0.offset) < (rank($1.element).0, rank($1.element).1, $1.offset) }
            .map(\.element)
    }
}
