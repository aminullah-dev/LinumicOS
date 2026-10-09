import Foundation
import LinumicCore
import Observation

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case dashboard
    case brief
    case monitor
    case releaseCenter
    case platforms
    case oversight
    case licences
    case worktrackCustomers
    case operations
    case siteMessages
    case vault
    case keys
    case allProducts, verification, releases, roadmap, issues
    case repositories, builds, deployments
    case appStore, googlePlay
    case socialMedia, contentCalendar
    case marketIntelligence, aiAssistant
    case integrations, security, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: L("Dashboard")
        case .brief: L("Brief")
        case .monitor: L("Monitor")
        case .releaseCenter: L("Releases")
        case .platforms: L("Platforms")
        case .oversight: L("Oversight")
        case .licences: L("Licences")
        case .worktrackCustomers: L("WorkTrack customers")
        case .operations: L("Operations")
        case .siteMessages: L("Website messages")
        case .vault: L("Vault")
        case .keys: L("Keys & Backups")
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
        case .dashboard: "square.grid.2x2"
        case .brief: "sun.horizon"
        case .monitor: "waveform.path.ecg"
        case .releaseCenter: "shippingbox.and.arrow.backward"
        case .platforms: "square.stack.3d.up"
        case .oversight: "scope"
        case .licences: "key.horizontal"
        case .worktrackCustomers: "person.2.badge.key"
        case .operations: "tray.full"
        case .siteMessages: "envelope"
        case .vault: "lock.rectangle.stack"
        case .keys: "externaldrive.badge.checkmark"
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
        SidebarSection(title: nil, items: [.dashboard, .brief, .monitor, .releaseCenter, .platforms, .oversight, .licences, .worktrackCustomers, .operations, .siteMessages, .vault, .keys]),
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
    /// Opens the "Mark restore test done" sheet in Keys & Backups (the sheet saves, never the palette).
    case markRestoreTest
}

/// Navigation state shared by the sidebar, the menu commands, the Command Palette and the Daily Brief.
@MainActor
@Observable
final class Router {
    var sidebar: SidebarItem? = .dashboard
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
        }
    }
}
