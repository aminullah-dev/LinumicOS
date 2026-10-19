import Foundation
import LinumicCore
import Observation

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case desk
    case obligations
    case dashboard
    case brief
    case monitor
    case automation
    case releaseCenter
    case platforms
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
    case socialMedia, contentCalendar
    case marketIntelligence, aiAssistant
    case integrations, security, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desk: L("Desk")
        case .obligations: L("Obligations & accounts")
        case .dashboard: L("Dashboard")
        case .brief: L("Brief")
        case .monitor: L("Monitor")
        case .automation: L("Automation")
        case .releaseCenter: L("Releases")
        case .platforms: L("Platforms")
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
        case .socialMedia: L("Social Media")
        case .contentCalendar: L("Content Calendar")
        case .marketIntelligence: L("Market Intelligence")
        case .aiAssistant: L("AI Assistant")
        case .integrations: L("Integrations")
        case .security: L("Security")
        case .account: L("Account")
        }
    }

    var symbol: String {
        switch self {
        case .desk: "checklist"
        case .obligations: "calendar.badge.exclamationmark"
        case .dashboard: "square.grid.2x2"
        case .brief: "sun.horizon"
        case .monitor: "waveform.path.ecg"
        case .automation: "gearshape.2"
        case .releaseCenter: "shippingbox.and.arrow.backward"
        case .platforms: "square.stack.3d.up"
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
        case .socialMedia: "bubble.left.and.bubble.right"
        case .contentCalendar: "calendar"
        case .marketIntelligence: "chart.line.uptrend.xyaxis"
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
    var id: String { title ?? "root" }

    static let all: [SidebarSection] = [
        SidebarSection(title: nil, items: [.desk, .obligations, .dashboard, .brief, .monitor, .automation, .releaseCenter, .platforms, .oversight, .licences, .worktrackCustomers, .operations, .siteMessages, .vault, .keys, .continuity]),
        SidebarSection(title: "Products", items: [.allProducts, .verification, .releases, .roadmap, .issues]),
        SidebarSection(title: "Development", items: [.repositories, .builds, .deployments]),
        SidebarSection(title: "Stores", items: [.appStore, .googlePlay]),
        SidebarSection(title: "Marketing", items: [.socialMedia, .contentCalendar]),
        SidebarSection(title: "Intelligence", items: [.marketIntelligence, .aiAssistant]),
        SidebarSection(title: "Settings", items: [.integrations, .security, .account]),
    ]
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
}

/// Navigation state shared by the sidebar, the menu commands, the Command Palette and the Daily Brief.
@MainActor
@Observable
final class Router {
    /// The Desk is the home screen.
    var sidebar: SidebarItem? = .desk
    var productPath: [String] = []
    var isPalettePresented = false
    var request: RouterRequest?
    var isNewProductPresented = false
    /// The product tab shown in Operations.
    var operationsTab: OperationsProduct = .talar

    init() {
        #if DEBUG
        // Debug-only screenshot aid: `-LCCScreen appStore` and `-LCCProduct safe-beauty` as launch arguments.
        let defaults = UserDefaults.standard
        if let screen = defaults.string(forKey: "LCCScreen").flatMap(SidebarItem.init(rawValue:)) { sidebar = screen }
        if let tab = defaults.string(forKey: "LCCOpsTab").flatMap(OperationsProduct.init(rawValue:)) { operationsTab = tab }
        if let product = defaults.string(forKey: "LCCProduct") { open(productID: product) }
        #endif
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
