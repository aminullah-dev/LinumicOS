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

    public init(title: String?, items: [String], isArchive: Bool = false) {
        self.title = title
        self.items = items
        self.isArchive = isArchive
    }
}

public enum SidebarArchive {
    /// The group's title (English; the app localizes it).
    public static let title = "Archive"

    /// The six pages, in the order they show in the Archive.
    public static let ids = ["releases", "roadmap", "issues", "builds", "deployments", "socialMedia"]

    /// What covers an archived page now, in the app's language (the row's help text).
    public static func coveredBy(_ id: String) -> String? {
        switch id {
        case "releases": L("Now covered by Releases, which reads App Store Connect, Google Play and GitHub.")
        case "roadmap", "issues": L("Now covered by the Desk, which lists the ledgers' open items.")
        case "builds": L("Now covered by Releases: builds and CI per store and repository.")
        case "deployments": L("Now covered by the Monitor and Platforms: live endpoints and the versions on main.")
        case "socialMedia": L("Now covered by the Marketing queue.")
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
