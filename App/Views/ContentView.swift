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
        .alert("Inventory updated", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
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
        case .verification: VerificationView()
        case .releases: AllReleasesView()
        case .roadmap: AllRoadmapView()
        case .issues: AllIssuesView()
        case .repositories: AllRepositoriesView()
        case .deployments: AllDeploymentsView()
        case .builds:
            NotIntegratedView(item: item, message: "Build status will come from CI (GitHub Actions) once the read-only GitHub integration is connected.")
        case .appStore: StoreListingsView(store: .appStore)
        case .googlePlay: StoreListingsView(store: .googlePlay)
        case .socialMedia: SocialAccountsView()
        case .contentCalendar: ContentCalendarView()
        case .marketIntelligence: MarketIntelligenceView()
        case .aiAssistant:
            NotIntegratedView(item: item, message: "The assistant will answer only from recorded data and will label each answer as verified, derived or unknown.")
        case .integrations: IntegrationsSettingsView()
        case .security: SecuritySettingsView()
        case .account: AccountSettingsView()
        }
    }
}
