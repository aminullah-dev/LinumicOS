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
    @State private var releases: ReleaseCenterModel
    @State private var vault = VaultModel()
    @State private var monitor: MonitorModel
    @State private var brief: BriefModel
    @State private var keys: KeysModel
    @State private var siteMessages: SiteMessagesModel
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
        let licences = LicenceModel(inventory: inventory)
        _licences = State(initialValue: licences)
        _platforms = State(initialValue: PlatformHubModel(inventory: inventory))
        let worktrack = WorkTrackModel(inventory: inventory)
        _worktrack = State(initialValue: worktrack)
        let operations = OperationsModel(inventory: inventory)
        _operations = State(initialValue: operations)
        let releases = ReleaseCenterModel(inventory: inventory)
        _releases = State(initialValue: releases)
        let monitor = MonitorModel()
        _monitor = State(initialValue: monitor)
        let keys = KeysModel()
        _keys = State(initialValue: keys)
        let siteMessages = SiteMessagesModel()
        _siteMessages = State(initialValue: siteMessages)
        _brief = State(initialValue: BriefModel(inventory: inventory, licences: licences, worktrack: worktrack,
                                                operations: operations, releases: releases, monitor: monitor, keys: keys,
                                                siteMessages: siteMessages))
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
                .environment(releases)
                .environment(vault)
                .environment(monitor)
                .environment(brief)
                .environment(keys)
                .environment(siteMessages)
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
                    await releases.load()
                    // Store status on launch, then every 30 minutes while the app is open.
                    while !Task.isCancelled {
                        await model.autoRefreshStoresIfDue()
                        await model.autoRefreshOversightIfDue()
                        await platforms.autoRefreshIfDue()
                        await licences.sync()
                        await worktrack.autoRefreshIfDue()
                        await operations.autoRefreshIfDue()
                        await releases.autoRefreshIfDue()
                        // Keys & Backups: file dates and sizes in the granted folders only (Mac), no network.
                        await keys.check()
                        // Website messages: two GETs to linumic.com with the stored application password, if any.
                        await siteMessages.refresh()
                        // Today's snapshot for "what changed since yesterday", and the morning notification.
                        await brief.record()
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
                Button("Command Palette…") { router.isPalettePresented = true }
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
        [.dashboard, .brief, .allProducts, .verification, .releases, .roadmap, .issues, .repositories, .aiAssistant]
    }
}
