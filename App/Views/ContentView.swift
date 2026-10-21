import LinumicCore
import SwiftUI

struct ContentView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage("LCCSidebarArchiveExpanded") private var archiveExpanded = false

    var body: some View {
        @Bindable var router = router
        @Bindable var model = model

        NavigationSplitView {
            // Picking a sidebar item resets the product path; programmatic navigation (Command Palette, Brief) sets both.
            List(selection: Binding(
                get: { router.sidebar },
                set: { router.sidebar = $0; router.productPath = [] }
            )) {
                ForEach(SidebarSection.all) { section in
                    if section.isArchive, let title = section.title {
                        // Collapsed until opened; the choice is kept on this device.
                        Section(isExpanded: $archiveExpanded) { rows(section.items, muted: true) } header: { Text(LocalizedStringKey(title)) }
                    } else if let title = section.title {
                        Section(LocalizedStringKey(title)) { rows(section.items) }
                    } else {
                        rows(section.items)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button { router.isPalettePresented = true } label: {
                        Label("Search and commands", systemImage: "magnifyingglass")
                    }
                    .help("Search screens, records and commands (⌘K)")
                }
            }
        } detail: {
            detail(for: router.sidebar ?? .desk)
        }
        .sheet(isPresented: $router.isPalettePresented) { CommandPaletteView() }
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
            Text(verbatim: model.errorMessage ?? "")
        }
        .alert("Inventory updated", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(verbatim: model.notice ?? "")
        }
    }

    /// Each row with its tile in the area's tint, as in System Settings; the Archive's tiles are muted.
    private func rows(_ items: [SidebarItem], muted: Bool = false) -> some View {
        ForEach(items) { item in
            // An archived page says what covers it now.
            if let covered = SidebarArchive.coveredBy(item.rawValue) {
                row(item, muted: muted).tag(item).help(Text(verbatim: covered))
            } else {
                row(item, muted: muted).tag(item)
            }
        }
    }

    private func row(_ item: SidebarItem, muted: Bool) -> some View {
        Label { Text(verbatim: item.title) } icon: { SidebarTile(item: item, muted: muted) }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .desk: DeskView()
        case .obligations: ObligationsView()
        case .money: MoneyView()
        case .sales: SalesView()
        case .legal: LegalView()
        case .dashboard: DashboardView()
        case .brief: DailyBriefView()
        case .monitor: MonitorView()
        case .automation: AutomationView()
        case .releaseCenter: ReleaseCenterView()
        case .platforms: PlatformsView()
        case .productBoard: ProductBoardView()
        case .agents: AgentsView()
        case .oversight: OversightView()
        case .licences: LicencesView()
        case .worktrackCustomers: WorkTrackCustomersView()
        case .operations: OperationsView()
        case .siteMessages: SiteMessagesView()
        case .vault: VaultView()
        case .keys: KeysView()
        case .continuity: ContinuityView()
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
        case .marketingQueue: MarketingQueueView()
        case .socialMedia: SocialAccountsView()
        case .contentCalendar: ContentCalendarView()
        case .marketIntelligence: MarketIntelligenceView()
        case .aiAssistant: AssistantView()
        case .integrations: IntegrationsSettingsView()
        case .security: SecuritySettingsView()
        case .account: AccountSettingsView()
        }
    }
}
