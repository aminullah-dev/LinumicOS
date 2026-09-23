import Foundation
import LinumicCore
import Observation

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case dashboard
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
        case .allProducts: L("All Products")
        case .verification: L("Verification")
        case .releases: L("Releases")
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
        SidebarSection(title: nil, items: [.dashboard]),
        SidebarSection(title: "Products", items: [.allProducts, .verification, .releases, .roadmap, .issues]),
        SidebarSection(title: "Development", items: [.repositories, .builds, .deployments]),
        SidebarSection(title: "Stores", items: [.appStore, .googlePlay]),
        SidebarSection(title: "Marketing", items: [.socialMedia, .contentCalendar]),
        SidebarSection(title: "Intelligence", items: [.marketIntelligence, .aiAssistant]),
        SidebarSection(title: "Settings", items: [.integrations, .security, .account]),
    ]
}

/// Navigation state shared by the sidebar, the menu commands and Quick Open.
@MainActor
@Observable
final class Router {
    var sidebar: SidebarItem? = .dashboard
    var productPath: [String] = []
    var isQuickOpenPresented = false
    var isNewProductPresented = false

    func open(productID: String) {
        sidebar = .allProducts
        productPath = [productID]
    }
}
