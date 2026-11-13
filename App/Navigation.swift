import Foundation
import LinumicCore
import Observation

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case center
    case desk
    case obligations
    case money
    case sales
    case legal
    case dashboard
    case brief
    case monitor
    case automation
    case releaseCenter
    case platforms
    case productBoard
    case agents
    case oversight
    case licences
    case worktrackCustomers
    case operations
    case siteMessages
    case vault
    case keys
    case continuity
    case allProducts, verification, releases, roadmap, issues
    case repositories, builds, deployments
    case appStore, googlePlay
    /// Every marketing item: the queue, posts and social accounts, market research (`MarketingTab`). It replaced the
    /// Marketing queue, Content Calendar, Social Media and Market Intelligence pages on 2026-11-13; links to those open it
    /// on their tab (`Router.resolve(screen:)`).
    case marketing
    case aiAssistant
    case integrations, security, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .center: L("Center")
        case .desk: L("Desk")
        case .obligations: L("Obligations & accounts")
        case .money: L("Money")
        case .sales: L("Sales")
        case .legal: L("Legal & company")
        case .dashboard: L("Dashboard")
        case .brief: L("Brief")
        case .monitor: L("Monitor")
        case .automation: L("Automation")
        case .releaseCenter: L("Releases")
        case .platforms: L("Platforms")
        case .productBoard: L("Projects")
        case .agents: L("Agents")
        case .oversight: L("Oversight")
        case .licences: L("Licences")
        case .worktrackCustomers: L("WorkTrack customers")
        case .operations: L("Operations")
        case .siteMessages: L("Website messages")
        case .vault: L("Vault")
        case .keys: L("Keys & Backups")
        case .continuity: L("Continuity")
        case .allProducts: L("All Products")
        case .verification: L("Verification")
        case .releases: L("Release records")
        case .roadmap: L("Roadmap")
        case .issues: L("Issues")
        case .repositories: L("Repositories")
        case .builds: L("Builds")
        case .deployments: L("Deployments")
        case .appStore: L("App Store")
        case .googlePlay: L("Google Play")
        case .marketing: L("Marketing")
        case .aiAssistant: L("AI Assistant")
        case .integrations: L("Integrations")
        case .security: L("Security")
        case .account: L("Account")
        }
    }

    var symbol: String {
        switch self {
        case .center: "rectangle.3.group"
        case .desk: "checklist"
        case .obligations: "calendar.badge.exclamationmark"
        case .money: "banknote"
        case .sales: "phone.arrow.up.right"
        case .legal: "building.columns"
        case .dashboard: "square.grid.2x2"
        case .brief: "sun.horizon"
        case .monitor: "waveform.path.ecg"
        case .automation: "gearshape.2"
        case .releaseCenter: "shippingbox.and.arrow.backward"
        case .platforms: "square.stack.3d.up"
        case .productBoard: "square.grid.3x2"
        case .agents: "person.2.wave.2"
        case .oversight: "scope"
        case .licences: "key.horizontal"
        case .worktrackCustomers: "person.2.badge.key"
        case .operations: "tray.full"
        case .siteMessages: "envelope"
        case .vault: "lock.rectangle.stack"
        case .keys: "externaldrive.badge.checkmark"
        case .continuity: "lock.doc"
        case .allProducts: "shippingbox"
        case .verification: "checkmark.seal"
        case .releases: "tag"
        case .roadmap: "map"
        case .issues: "exclamationmark.triangle"
        case .repositories: "externaldrive.connected.to.line.below"
        case .builds: "hammer"
        case .deployments: "server.rack"
        case .appStore: "applelogo"
        case .googlePlay: "play.rectangle"
        case .marketing: "megaphone"
        case .aiAssistant: "sparkles"
        case .integrations: "puzzlepiece.extension"
        case .security: "lock.shield"
        case .account: "person.crop.circle"
        }
    }
}

struct SidebarSection: Identifiable {
    let title: String?
    let items: [SidebarItem]
    /// The Archive (Phase 6): shown collapsed until opened.
    var isArchive = false
    /// Working pages kept out of the daily view: shown collapsed until opened.
    var isMore = false
    var id: String { title ?? "root" }

    /// The sidebar as shown: the five daily pages, then every other page in one collapsed "More" group, then the
    /// collapsed Archive (`SidebarDaily`, `SidebarMore`, `SidebarArchive`, LinumicCore). No page or record is removed:
    /// each one still opens from the sidebar, the Command Palette, and the links on the centre and the project pages.
    static let all: [SidebarSection] = SidebarMore.arrange(SidebarArchive.arrange(grouped.map { SidebarGroup(title: $0.title, items: $0.items.map(\.rawValue)) }))
        .map { SidebarSection(title: $0.title, items: $0.items.compactMap(SidebarItem.init(rawValue:)), isArchive: $0.isArchive, isMore: $0.isMore) }

    /// Every page by area. Every `SidebarItem` appears exactly once.
    ///
    /// This is where a page belongs, not what the sidebar shows: `all` takes the five daily pages to the top, the
    /// archived pages to the Archive, and the rest, in this order, to More, so the pages of one area sit together there.
    /// The Command Palette shows a page's area beside its name.
    static let grouped: [SidebarSection] = [
        SidebarSection(title: nil, items: [.center, .desk, .brief, .dashboard]),
        SidebarSection(title: "Company", items: [.obligations, .money, .sales, .licences, .legal]),
        SidebarSection(title: "Projects", items: [.productBoard, .releaseCenter, .platforms, .operations, .worktrackCustomers, .allProducts, .verification,
                                                  .releases, .roadmap, .issues, .aiAssistant]),
        SidebarSection(title: "Build & Ship", items: [.automation, .agents, .repositories, .appStore, .googlePlay, .builds, .deployments]),
        SidebarSection(title: "Health", items: [.monitor, .oversight, .siteMessages]),
        SidebarSection(title: "Marketing", items: [.marketing]),
        SidebarSection(title: "Security & Backups", items: [.keys, .vault, .continuity]),
        SidebarSection(title: "Settings", items: [.integrations, .security, .account]),
    ]

    /// The area a page belongs to (its group's title), for the Command Palette; nil for the untitled home group.
    static func area(of item: SidebarItem) -> String? {
        grouped.first { $0.items.contains(item) }?.title
    }
}

/// A request for the screen that opens next: show a record, or open its own sheet (where any confirmation lives).
/// The Command Palette and the Daily Brief set it together with `sidebar`; the screen consumes it and clears it.
enum RouterRequest: Equatable {
    case licence(String)
    case issueLicence
    case worktrackCompany(String)
    case newVaultEntry
    case vaultSearch(String)
    /// Opens the "Mark restore test done" sheet in Keys & Backups, for one backup or the first (the sheet saves, never
    /// the palette).
    case markRestoreTest(backupID: String?)
    /// Shows one Desk item (scrolled to and highlighted).
    case deskItem(String)
    /// Shows one obligation (scrolled to and highlighted).
    case obligation(String)
    /// Opens "Done with evidence" for one obligation (the sheet saves, nothing else).
    case completeObligation(String)
    /// Shows one Sales row (a `SalesKey`), scrolled to and highlighted.
    case salesItem(String)
    /// Opens one product's card on the Products page.
    case productCard(String)
    /// Shows one agent on the Agents page (its slug), scrolled to and highlighted.
    case agent(String)
    /// Shows the agents with pull requests waiting for review.
    case agentsWaiting
}

/// Navigation state shared by the sidebar, the menu commands, the Command Palette and the Daily Brief.
@MainActor
@Observable
final class Router {
    /// The management centre is the home screen.
    var sidebar: SidebarItem? = .center
    var productPath: [String] = []
    var isPalettePresented = false
    var request: RouterRequest?
    var isNewProductPresented = false
    /// The product tab shown in Operations.
    var operationsTab: OperationsProduct = .talar
    /// The tab a project's page shows next (the Center's line about an app on this Mac opens Releases); taken once.
    var pendingProjectTab: ProjectTab?
    /// The Marketing page's tab.
    var marketingTab: MarketingTab = .queue

    init() {
        #if DEBUG
        // Debug-only screenshot aid: `-LCCScreen appStore` and `-LCCProduct safe-beauty` as launch arguments.
        let defaults = UserDefaults.standard
        if let screen = defaults.string(forKey: "LCCScreen"), let (item, tab) = Self.resolve(screen: screen) {
            sidebar = item
            if let tab { marketingTab = tab }
        }
        if let tab = defaults.string(forKey: "LCCOpsTab").flatMap(OperationsProduct.init(rawValue:)) { operationsTab = tab }
        if let product = defaults.string(forKey: "LCCProduct") { open(productID: product) }
        if let card = defaults.string(forKey: "LCCProductCard") { request = .productCard(card) }
        if let agent = defaults.string(forKey: "LCCAgent") { request = .agent(agent) }
        #endif
    }

    /// A page by its id, including the pages folded into Marketing on 2026-11-13 (`MarketingTab.replacing`), which open
    /// Marketing on the tab that holds them. Nil for an id that names no page.
    static func resolve(screen id: String) -> (SidebarItem, MarketingTab?)? {
        if let tab = MarketingTab.replacing(pageID: id) { return (.marketing, tab) }
        return SidebarItem(rawValue: id).map { ($0, nil) }
    }

    /// The Marketing page on one tab, with one marketing obligation to show, or none.
    func openMarketing(_ tab: MarketingTab = .queue, obligation: String? = nil) {
        marketingTab = tab
        go(.marketing, request: obligation.map(RouterRequest.obligation))
    }

    func open(productID: String) {
        sidebar = .allProducts
        productPath = [productID]
    }

    func go(_ item: SidebarItem, request: RouterRequest? = nil) {
        productPath = []
        sidebar = item
        self.request = request
    }

    /// One project's page, on one of its tabs.
    func openProject(_ id: String, tab: ProjectTab) {
        pendingProjectTab = tab
        go(.productBoard, request: .productCard(id))
    }

    /// Takes the pending request if `accept` wants it, so each request is handled once.
    func take(_ accept: (RouterRequest) -> Bool) -> RouterRequest? {
        guard let r = request, accept(r) else { return nil }
        request = nil
        return r
    }

    /// Where a Daily Brief line's button goes.
    func open(_ destination: BriefDestination) {
        switch destination {
        case .monitor: go(.monitor)
        case .releaseCenter: go(.releaseCenter)
        case .licences: go(.licences)
        case .licence(let id): go(.licences, request: .licence(id))
        case .worktrackCustomers: go(.worktrackCustomers)
        case .worktrackCompany(let id): go(.worktrackCustomers, request: .worktrackCompany(id))
        case .operations(let product):
            if let product { operationsTab = product }
            go(.operations)
        case .oversight: go(.oversight)
        case .keys: go(.keys)
        case .siteMessages: go(.siteMessages)
        case .automation: go(.automation)
        case .obligations: go(.obligations)
        case .obligation(let id): go(.obligations, request: .obligation(id))
        case .continuity: go(.continuity)
        case .money: go(.money)
        case .sales(let key): go(.sales, request: key.map(RouterRequest.salesItem))
        case .products(let id): go(.productBoard, request: id.map(RouterRequest.productCard))
        case .agents(let slug): go(.agents, request: slug.map(RouterRequest.agent))
        case .legal: go(.legal)
        case .marketing(let id): openMarketing(.queue, obligation: id)
        }
    }

    /// Where a live obligation is closed: at its source, never by a typed Done. A restore test opens its sheet for that
    /// backup; the rest open the screen they are read from (Continuity for the export, the licence, the Monitor).
    func closeAtSource(_ obligationID: String, destination: BriefDestination) {
        let restore = "keys.restore."
        if obligationID.hasPrefix(restore) {
            go(.keys, request: .markRestoreTest(backupID: String(obligationID.dropFirst(restore.count))))
        } else {
            open(destination)
        }
    }

    /// Where a Desk row's Open button goes: a screen through the Brief's routing, or Settings for ledger access.
    /// Files are opened by `DeskModel` (they need the granted folder's scope).
    func open(_ destination: DeskDestination) {
        switch destination {
        case .screen(let d): open(d)
        case .ledgerAccess: go(.integrations)
        case .file: break
        }
    }
}
