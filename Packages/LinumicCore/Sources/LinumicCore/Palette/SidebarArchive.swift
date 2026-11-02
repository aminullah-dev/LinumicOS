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
    /// both held no records on the owner's Mac.
    public static let ids = ["releases", "roadmap", "issues", "builds", "deployments", "socialMedia", "contentCalendar", "marketIntelligence"]

    /// What covers an archived page now, in the app's language (the row's help text).
    public static func coveredBy(_ id: String) -> String? {
        switch id {
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

// MARK: - The sidebar's More group
//
// The management centre answers the daily questions, so the sidebar shows the pages used every day and keeps the rest
// one click away. Every page still works and is found by the Command Palette; this only decides what is on show.

public enum SidebarMore {
    /// The group's title (English; the app localizes it).
    public static let title = "More"

    /// The pages, in the order they show in the group.
    public static let ids = ["brief", "dashboard", "legal", "allProducts", "verification", "platforms", "repositories", "appStore", "googlePlay",
                             "automation", "agents", "oversight", "siteMessages", "aiAssistant", "keys", "continuity", "security"]

    public static func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The groups with these pages taken out of their own groups (a group left empty is dropped) and put, in `ids` order,
    /// into one group before the Archive. A page id that is not in `groups` is not added.
    public static func arrange(_ groups: [SidebarGroup]) -> [SidebarGroup] {
        let present = Set(groups.flatMap(\.items))
        let kept: [SidebarGroup] = groups.compactMap { g in
            guard !g.isArchive else { return g }
            let items = g.items.filter { !contains($0) }
            return items.isEmpty ? nil : SidebarGroup(title: g.title, items: items)
        }
        let moved = ids.filter(present.contains)
        guard !moved.isEmpty else { return kept }
        let more = SidebarGroup(title: title, items: moved, isMore: true)
        if let archive = kept.firstIndex(where: \.isArchive) {
            var out = kept
            out.insert(more, at: archive)
            return out
        }
        return kept + [more]
    }
}
