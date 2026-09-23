import LinumicCore
import SwiftUI

struct ContentView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        @Bindable var model = model

        NavigationSplitView {
            // Picking a sidebar item resets the product path; programmatic navigation (Quick Open) sets both.
            List(selection: Binding(
                get: { router.sidebar },
                set: { router.sidebar = $0; router.productPath = [] }
            )) {
                ForEach(SidebarSection.all) { section in
                    if let title = section.title {
                        Section(title) { rows(section.items) }
                    } else {
                        rows(section.items)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            detail(for: router.sidebar ?? .dashboard)
        }
        .sheet(isPresented: $router.isQuickOpenPresented) { QuickOpenView() }
        .sheet(isPresented: $router.isNewProductPresented) {
            ProductEditor(product: nil) { product in
                model.upsert(product)
                router.open(productID: product.id)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func rows(_ items: [SidebarItem]) -> some View {
        ForEach(items) { item in
            Label(item.title, systemImage: item.symbol).tag(item)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .dashboard: DashboardView()
        case .allProducts: ProductsRootView()
        case .releases: AllReleasesView()
        case .roadmap: AllRoadmapView()
        case .issues: AllIssuesView()
        case .repositories: AllRepositoriesView()
        case .deployments: AllDeploymentsView()
        case .builds:
            NotIntegratedView(item: item, message: "Build status will come from CI (GitHub Actions) once the read-only GitHub integration is connected.")
        case .appStore:
            NotIntegratedView(item: item, message: "App Store Connect integration is planned (read-only). Store fields can be recorded manually on each product's Stores tab.")
        case .googlePlay:
            NotIntegratedView(item: item, message: "Google Play Developer API integration is planned (read-only). Store fields can be recorded manually on each product's Stores tab.")
        case .socialMedia:
            NotIntegratedView(item: item, message: "LinkedIn, Facebook, Instagram, X and YouTube will be managed here. Publishing will always require approval.")
        case .contentCalendar:
            NotIntegratedView(item: item, message: "The content calendar, drafts and campaigns are planned for the Marketing phase.")
        case .marketIntelligence:
            NotIntegratedView(item: item, message: "Afghanistan market intelligence is at the design stage. Every finding will carry a source and timestamp. See docs/market-intelligence.md.")
        case .aiAssistant:
            NotIntegratedView(item: item, message: "The assistant will answer only from recorded data and will label each answer as verified, derived or unknown.")
        case .integrations: IntegrationsSettingsView()
        case .security: SecuritySettingsView()
        case .account: AccountSettingsView()
        }
    }
}
