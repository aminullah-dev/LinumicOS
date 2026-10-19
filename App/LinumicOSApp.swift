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
    @State private var vault: VaultModel
    @State private var monitor: MonitorModel
    @State private var brief: BriefModel
    @State private var desk: DeskModel
    @State private var keys: KeysModel
    @State private var siteMessages: SiteMessagesModel
    @State private var sentinel: SentinelModel
    @State private var obligations: ObligationsModel
    @State private var deskSync: DeskSyncModel
    @State private var continuity: ContinuityModel
    @State private var automation: AutomationEngine
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(MacPresence.menuBarKey) private var showMenuBar = true
    #endif

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
        let platforms = PlatformHubModel(inventory: inventory)
        _platforms = State(initialValue: platforms)
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
        let continuity = ContinuityModel()
        _continuity = State(initialValue: continuity)
        let obligations = ObligationsModel(monitor: monitor, licences: licences, keys: keys, continuity: continuity)
        _obligations = State(initialValue: obligations)
        let brief = BriefModel(inventory: inventory, licences: licences, worktrack: worktrack, operations: operations,
                               releases: releases, monitor: monitor, keys: keys, siteMessages: siteMessages, obligations: obligations)
        _brief = State(initialValue: brief)
        let desk = DeskModel(brief: brief)
        _desk = State(initialValue: desk)
        let sentinel = SentinelModel(inventory: inventory)
        _sentinel = State(initialValue: sentinel)
        let deskSync = DeskSyncModel(inventory: inventory, desk: desk, obligations: obligations)
        _deskSync = State(initialValue: deskSync)
        // Started here, not from a window, so it runs whether or not a window is open (menu bar, login item).
        let automation = AutomationEngine(inventory: inventory, licences: licences, platforms: platforms, worktrack: worktrack,
                                          operations: operations, releases: releases, monitor: monitor, brief: brief,
                                          keys: keys, siteMessages: siteMessages, sentinel: sentinel, desk: desk,
                                          obligations: obligations, deskSync: deskSync)
        _automation = State(initialValue: automation)
        let vault = VaultModel()
        vault.load()
        _vault = State(initialValue: vault)
        automation.start()
    }

    var body: some Scene {
        WindowGroup("Linumic OS", id: "main") {
            environment(ContentView())
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
                // The Vault locks whenever the app leaves the foreground.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        vault.appMovedToBackground()
                        #if os(iOS)
                        automation.scheduleBackgroundRefresh()
                        #endif
                    case .active:
                        // Back in front: run whatever fell due while the app was suspended.
                        automation.nudge(.wake)
                    default: break
                    }
                }
                // Keeps the Monitor's relative times current; the checks themselves run in `AutomationEngine`.
                .task { await monitor.keepTime() }
        }
        #if os(macOS)
        .defaultLaunchBehavior(MacPresence.startsHidden && showMenuBar ? .suppressed : .automatic)
        #else
        .backgroundTask(.appRefresh(AutomationEngine.backgroundTaskID)) {
            await automation.backgroundRefresh()
        }
        #endif
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
        #if os(macOS)
        MenuBarExtra(isInserted: $showMenuBar) {
            environment(MenuBarPanel())
        } label: {
            environment(MenuBarLabel())
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    /// Every model, for the main window and the menu bar panel alike.
    private func environment<V: View>(_ view: V) -> some View {
        view
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
            .environment(desk)
            .environment(keys)
            .environment(siteMessages)
            .environment(automation)
            .environment(sentinel)
            .environment(obligations)
            .environment(deskSync)
            .environment(continuity)
            .environment(router)
    }

    /// macOS has no Persian system localization, so AppKit doesn't mirror a Dari app by
    /// itself. Mirror the SwiftUI content when the app runs in a right-to-left language.
    static let layoutDirection: LayoutDirection = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: lang).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }()

    private var goShortcuts: [SidebarItem] {
        // ⌘1 to ⌘9: the Desk first (the home screen); AI Assistant moved out to keep nine.
        [.desk, .dashboard, .brief, .allProducts, .verification, .releases, .roadmap, .issues, .repositories]
    }
}
