import LinumicCore
import SwiftUI

@main
struct LinumicOSApp: App {
    @State private var model: InventoryModel
    @State private var router = Router()
    @State private var licences: LicenceModel
    @State private var platforms: PlatformHubModel
    @State private var worktrack: WorkTrackModel
    @State private var operations: OperationsModel
    @State private var vault = VaultModel()
    @State private var monitor = MonitorModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // macOS has no Persian system localization, so AppKit (window controls, split views, sheets,
        // menus) doesn't mirror on its own. It reads these flags at launch, so keep them in step with
        // the language: they take effect from the next launch. SwiftUI content is mirrored at once
        // through the environment.
        AppLanguage.syncWritingDirection(rightToLeft: Self.layoutDirection == .rightToLeft)
        let store: InventoryStore
        if let url = try? JSONFileInventoryStore.defaultFileURL() {
            store = JSONFileInventoryStore(fileURL: url)
        } else {
            // Application Support could not be resolved, so keep this session's data in memory.
            store = InMemoryInventoryStore()
        }
        let inventory = InventoryModel(store: store)
        _model = State(initialValue: inventory)
        _licences = State(initialValue: LicenceModel(inventory: inventory))
        _platforms = State(initialValue: PlatformHubModel(inventory: inventory))
        _worktrack = State(initialValue: WorkTrackModel(inventory: inventory))
        _operations = State(initialValue: OperationsModel(inventory: inventory))
    }

    var body: some Scene {
        WindowGroup("Linumic OS") {
            ContentView()
                .environment(\.layoutDirection, Self.layoutDirection)
                .environment(model)
                .environment(licences)
                .environment(platforms)
                .environment(worktrack)
                .environment(operations)
                .environment(vault)
                .environment(monitor)
                .environment(router)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
                // The Vault locks whenever the app leaves the foreground.
                .onChange(of: scenePhase) { _, phase in if phase == .background { vault.appMovedToBackground() } }
                // Monitor: public health checks on open, then every 5 minutes, alongside the slower refresh loop below.
                .task { await monitor.run() }
                .task {
                    vault.load()
                    await model.load()
                    await licences.load()
                    await platforms.load()
                    await worktrack.load()
                    await operations.load()
                    // Store status on launch, then every 30 minutes while the app is open.
                    while !Task.isCancelled {
                        await model.autoRefreshStoresIfDue()
                        await model.autoRefreshOversightIfDue()
                        await platforms.autoRefreshIfDue()
                        await licences.sync()
                        await worktrack.autoRefreshIfDue()
                        await operations.autoRefreshIfDue()
                        try? await Task.sleep(for: .seconds(InventoryModel.autoRefreshInterval))
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Product…") { router.isNewProductPresented = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Go") {
                Button("Quick Open…") { router.isQuickOpenPresented = true }
                    .keyboardShortcut("k")
                Divider()
                ForEach(Array(goShortcuts.enumerated()), id: \.element) { index, item in
                    Button(item.title) {
                        router.productPath = []
                        router.sidebar = item
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }
    }

    /// macOS has no Persian system localization, so AppKit doesn't mirror a Dari app by
    /// itself. Mirror the SwiftUI content when the app runs in a right-to-left language.
    static let layoutDirection: LayoutDirection = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: lang).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }()

    private var goShortcuts: [SidebarItem] {
        [.dashboard, .allProducts, .verification, .releases, .roadmap, .issues, .repositories, .aiAssistant]
    }
}
