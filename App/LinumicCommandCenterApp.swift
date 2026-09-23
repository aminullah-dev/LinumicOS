import LinumicCore
import SwiftUI

@main
struct LinumicCommandCenterApp: App {
    @State private var model: InventoryModel
    @State private var router = Router()

    init() {
        let store: InventoryStore
        if let url = try? JSONFileInventoryStore.defaultFileURL() {
            store = JSONFileInventoryStore(fileURL: url)
        } else {
            // Application Support could not be resolved, so keep this session's data in memory.
            store = InMemoryInventoryStore()
        }
        _model = State(initialValue: InventoryModel(store: store))
    }

    var body: some Scene {
        WindowGroup("Linumic Command Center") {
            ContentView()
                .environment(model)
                .environment(router)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.load() }
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

    private var goShortcuts: [SidebarItem] {
        [.dashboard, .allProducts, .releases, .roadmap, .issues, .repositories]
    }
}
