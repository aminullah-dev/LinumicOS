import Foundation

// MARK: - The sidebar's Archive group (Phase 6 of docs/company-os-roadmap.md)
//
// Six manual pages that hold no records on the owner's Mac (checked 2026-10-20 in inventory.json: 0 release records,
// 0 roadmap items, 0 issues, 0 deployments, 0 social accounts; Builds was never connected) and that a newer module now
// covers move into one collapsed "Archive" group at the end of the sidebar. Presentation only: no page, record or
// editor is removed, and a record added later still shows on its page there and on the product's own tabs.

/// One group of the sidebar, by page id (the App's `SidebarItem` raw values).
public struct SidebarGroup: Hashable, Sendable {
    /// Nil for the first, untitled group.
    public var title: String?
    public var items: [String]
    /// The Archive: shown collapsed until opened.
    public var isArchive: Bool
    /// "More": working pages kept out of the daily view, shown collapsed until opened.
    public var isMore: Bool

    public init(title: String?, items: [String], isArchive: Bool = false, isMore: Bool = false) {
        self.title = title
        self.items = items
        self.isArchive = isArchive
        self.isMore = isMore
    }
}

public enum SidebarArchive {
    /// The group's title (English; the app localizes it).
    public static let title = "Archive"

    /// The pages, in the order they show in the Archive. Content Calendar and Market Intelligence joined on 2026-11-02:
    /// both held no records on the owner's Mac. The Brief and the Dashboard joined on 2026-11-04: the centre shows what
    /// they showed, from the same models (every Brief line is a Desk item, and the centre is built from the Desk).
    public static let ids = ["brief", "dashboard", "releases", "roadmap", "issues", "builds", "deployments", "socialMedia", "contentCalendar",
                             "marketIntelligence"]

    /// What covers an archived page now, in the app's language (the row's help text).
    public static func coveredBy(_ id: String) -> String? {
        switch id {
        case "brief": L("Now covered by the center and the Desk: every line of the Brief is a Desk item, and what changed since yesterday is on the center.")
        case "dashboard": L("Now covered by the center: what waits on you, the projects, and the readings that are out of date.")
        case "releases": L("Now covered by Releases, which reads App Store Connect, Google Play and GitHub.")
        case "roadmap", "issues": L("Now covered by the Desk, which lists the ledgers' open items.")
        case "builds": L("Now covered by Releases: builds and CI per store and repository.")
        case "deployments": L("Now covered by the Monitor and Platforms: live endpoints and the versions on main.")
        case "socialMedia", "contentCalendar": L("Now covered by the Marketing queue.")
        case "marketIntelligence": L("Holds no records on this device yet.")
        default: nil
        }
    }

    public static func isArchived(_ id: String) -> Bool { ids.contains(id) }

    /// The groups with the archived pages taken out of their own groups (a group left empty is dropped) and put, in
    /// `ids` order, into a last group, the Archive. Every other page keeps its group and place. A page id that is not
    /// in `groups` is not added: the Archive never invents a page.
    public static func arrange(_ groups: [SidebarGroup]) -> [SidebarGroup] {
        let present = Set(groups.flatMap(\.items))
        var out: [SidebarGroup] = groups.compactMap { g in
            let kept = g.items.filter { !isArchived($0) }
            return kept.isEmpty ? nil : SidebarGroup(title: g.title, items: kept)
        }
        let archived = ids.filter(present.contains)
        if !archived.isEmpty { out.append(SidebarGroup(title: title, items: archived, isArchive: true)) }
        return out
    }
}

// MARK: - The sidebar's daily surface and its More group
//
// The way a very large operations console stays calm (owner, 2026-11-04: "think of it as Amazon, Uber, Lyft, Meta"): a
// handful of places used every day, search (the Command Palette) to reach anything else, and the rest one click away in
// a collapsed group. Every page still works, keeps its records and is found by the Command Palette; this only decides
// what is on show.

public enum SidebarDaily {
    /// The five pages used every day, in this order, as one untitled group at the top: the centre (home), the Desk,
    /// Projects (each project's page, with its tabs), Keys & Backups and Automation.
    public static let ids = ["center", "desk", "productBoard", "keys", "automation"]

    public static func contains(_ id: String) -> Bool { ids.contains(id) }
}

public enum SidebarMore {
    /// The group's title (English; the app localizes it).
    public static let title = "More"

    /// Every page that is neither on the daily surface nor archived.
    public static func contains(_ id: String) -> Bool { !SidebarDaily.contains(id) && !SidebarArchive.isArchived(id) }

    /// The daily pages first, as one untitled group in `SidebarDaily.ids` order, then every other page in one "More"
    /// group in the order `groups` list them (so pages of one area stay together), then the Archive as it was. A page id
    /// that is not in `groups` is not added, and an empty group is not shown.
    public static func arrange(_ groups: [SidebarGroup]) -> [SidebarGroup] {
        let pages = groups.filter { !$0.isArchive }.flatMap(\.items)
        let present = Set(pages)
        var out: [SidebarGroup] = []
        let daily = SidebarDaily.ids.filter(present.contains)
        if !daily.isEmpty { out.append(SidebarGroup(title: nil, items: daily)) }
        let more = pages.filter(contains)
        if !more.isEmpty { out.append(SidebarGroup(title: title, items: more, isMore: true)) }
        return out + groups.filter(\.isArchive)
    }
}
