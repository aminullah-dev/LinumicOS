import LinumicCore
import SwiftUI

// MARK: - Command Palette (Cmd+K)

/// What choosing a palette item does. Nothing here writes to a store or deletes anything: actions that change
/// something open the screen or sheet that holds their confirmation. "Check now" and "Refresh releases" only read.
enum PaletteAction {
    case go(SidebarItem, RouterRequest?)
    case product(String)
    case operations(OperationsProduct)
    case openURL(URL)
    case newProduct
    case checkMonitor
    case refreshReleases
    case refreshSiteMessages
    case lockVault
}

/// Fuzzy search over every screen, the records the app already holds (titles only, never a secret) and the actions
/// that already exist. Arrow keys move, Return opens, Escape closes; recently used items come first.
struct CommandPaletteView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LicenceModel.self) private var licences
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(ReleaseCenterModel.self) private var releases
    @Environment(VaultModel.self) private var vault
    @Environment(MonitorModel.self) private var monitor
    @Environment(KeysModel.self) private var keys
    @Environment(SiteMessagesModel.self) private var siteMessages
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var query = ""
    @State private var selection: String?
    @State private var recents = PaletteRecentsStore.load()
    @FocusState private var focused: Bool

    private var catalog: (candidates: [PaletteCandidate], actions: [String: PaletteAction]) { buildCatalog() }

    var body: some View {
        let catalog = catalog
        let results = PaletteRanker.rank(query, catalog.candidates, recents: recents.ids)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search screens, records and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit { run(selection ?? results.first?.id, catalog.actions) }
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .accessibilityHint(Text("Type to filter. Up and down arrows choose, Return opens, Escape closes."))
                #if os(iOS)
                Button("Close") { dismiss() }
                #endif
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List {
                    if results.isEmpty {
                        Text("Nothing matches “\(query)”.").foregroundStyle(.secondary)
                    }
                    ForEach(sections(results), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                row(item, selected: item.id == (selection ?? results.first?.id))
                                    .id(item.id)
                                    .onTapGesture { run(item.id, catalog.actions) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Text("↑↓ choose · ↩ open · esc close").environment(\.layoutDirection, .leftToRight)
                Spacer()
                Text("Actions that change something open their screen first, with its confirmation.")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        #if os(macOS)
        .frame(width: 620, height: 460)
        #endif
        .onAppear { focused = true }
        .onChange(of: query) { selection = nil }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }

    /// Recents (when the query is empty) as their own group, then groups in ranked order.
    private func sections(_ results: [PaletteCandidate]) -> [(title: String, items: [PaletteCandidate])] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let recentSet = Set(recents.ids)
            let recent = results.filter { recentSet.contains($0.id) }
            var out: [(String, [PaletteCandidate])] = recent.isEmpty ? [] : [(String(localized: "Recent"), recent)]
            for g in PaletteCandidate.Group.allCases {
                let items = results.filter { $0.group == g && !recentSet.contains($0.id) }
                if !items.isEmpty { out.append((g.title, items)) }
            }
            return out
        }
        return [(String(localized: "Results"), results)]
    }

    private func row(_ item: PaletteCandidate, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 22)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "return").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func move(_ step: Int, in results: [PaletteCandidate]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == (selection ?? results.first?.id) } ?? 0
        let next = min(max(current + step, 0), results.count - 1)
        selection = results[next].id
    }

    private func run(_ id: String?, _ actions: [String: PaletteAction]) {
        guard let id, let action = actions[id] else { return }
        recents.record(id)
        PaletteRecentsStore.save(recents)
        dismiss()
        switch action {
        case .go(let item, let request): router.go(item, request: request)
        case .product(let id): router.open(productID: id)
        case .operations(let product):
            router.operationsTab = product
            router.go(.operations)
        case .openURL(let url): openURL(url)
        case .newProduct: router.isNewProductPresented = true
        case .checkMonitor:
            router.go(.monitor)
            Task { await monitor.checkNow() }
        case .refreshReleases:
            router.go(.releaseCenter)
            Task { await releases.refresh() }
        case .refreshSiteMessages:
            router.go(.siteMessages)
            Task { await siteMessages.refresh() }
        case .lockVault: vault.lock()
        }
    }

    // MARK: Catalog

    private func buildCatalog() -> (candidates: [PaletteCandidate], actions: [String: PaletteAction]) {
        var list: [PaletteCandidate] = []
        var actions: [String: PaletteAction] = [:]
        func add(_ c: PaletteCandidate, _ a: PaletteAction) {
            guard actions[c.id] == nil else { return }
            list.append(c)
            actions[c.id] = a
        }

        // Navigation: every sidebar destination, searchable by its English name in a Dari UI too.
        for section in SidebarSection.all {
            for item in section.items {
                add(PaletteCandidate(id: "nav.\(item.rawValue)", title: item.title,
                                     subtitle: section.title.map { String(localized: String.LocalizationValue($0)) },
                                     keywords: [item.rawValue, englishTitle(item)], group: .navigation, symbol: item.symbol),
                    .go(item, nil))
            }
        }
        for p in OperationsProduct.allCases {
            add(PaletteCandidate(id: "nav.operations.\(p.rawValue)", title: "\(SidebarItem.operations.title): \(p.title)",
                                 keywords: ["operations", p.rawValue], group: .navigation, symbol: p.symbol), .operations(p))
        }

        // Actions that already exist in the app.
        add(PaletteCandidate(id: "action.monitor.check", title: String(localized: "Check now"), subtitle: SidebarItem.monitor.title,
                             keywords: ["monitor", "check", "health", "refresh"], group: .action, symbol: "arrow.clockwise"), .checkMonitor)
        add(PaletteCandidate(id: "action.releases.refresh", title: String(localized: "Refresh releases"), subtitle: SidebarItem.releaseCenter.title,
                             keywords: ["releases", "refresh", "app store", "google play", "github"], group: .action, symbol: "arrow.clockwise"),
            .refreshReleases)
        add(PaletteCandidate(id: "action.sitemessages.refresh", title: String(localized: "Refresh website messages"),
                             subtitle: SidebarItem.siteMessages.title,
                             keywords: ["website", "messages", "contact", "form", "linumic.com", "sureforms", "refresh"],
                             group: .action, symbol: "arrow.clockwise"), .refreshSiteMessages)
        add(PaletteCandidate(id: "open.sureforms.entries", title: String(localized: "Open form entries in wp-admin"),
                             subtitle: SidebarItem.siteMessages.title,
                             keywords: ["website", "messages", "contact", "entries", "wordpress", "wp-admin", "sureforms"],
                             group: .action, symbol: "safari"), .openURL(SiteMessagesSource.entriesAdminURL()))
        if LicenceModel.canIssue {
            add(PaletteCandidate(id: "action.licence.issue", title: String(localized: "Issue licence…"), subtitle: SidebarItem.licences.title,
                                 keywords: ["licence", "license", "issue", "mediflow", "khayatyar"], group: .action, symbol: "key.horizontal"),
                .go(.licences, .issueLicence))
        }
        add(PaletteCandidate(id: "action.vault.new", title: String(localized: "New vault entry…"), subtitle: SidebarItem.vault.title,
                             keywords: ["vault", "add", "sign-in", "password"], group: .action, symbol: "plus"), .go(.vault, .newVaultEntry))
        if vault.isUnlocked {
            add(PaletteCandidate(id: "action.vault.lock", title: String(localized: "Lock vault"), subtitle: SidebarItem.vault.title,
                                 keywords: ["vault", "lock"], group: .action, symbol: "lock"), .lockVault)
        }
        // Opens the sheet in Keys & Backups; the sheet saves only after Save.
        add(PaletteCandidate(id: "action.keys.restoretest", title: String(localized: "Mark restore test done…"), subtitle: SidebarItem.keys.title,
                             keywords: ["keys", "backup", "restore", "test", "keystore"], group: .action, symbol: "checkmark.circle"),
            .go(.keys, .markRestoreTest))
        add(PaletteCandidate(id: "action.product.new", title: String(localized: "New Product…"), keywords: ["product", "add"],
                             group: .action, symbol: "plus.square"), .newProduct)
        // "Open <console URL>": the sign-in addresses kept in the Vault (addresses only) and the monitored pages.
        var seenURLs = Set<String>()
        for e in vault.entries {
            guard let url = e.url, url.scheme == "https", seenURLs.insert(url.absoluteString).inserted else { continue }
            add(PaletteCandidate(id: "open.\(url.absoluteString)", title: String(localized: "Open \(url.host() ?? url.absoluteString)"),
                                 subtitle: "\(e.product.title) · \(e.title)", keywords: [url.absoluteString, "open", "console"],
                                 group: .action, symbol: "safari"), .openURL(url))
        }
        for t in monitor.targets where !t.isHealthEndpoint {
            guard seenURLs.insert(t.url.absoluteString).inserted else { continue }
            add(PaletteCandidate(id: "open.\(t.url.absoluteString)", title: String(localized: "Open \(t.host)"),
                                 subtitle: "\(t.product.title) · \(L(t.name))", keywords: [t.url.absoluteString, "open"],
                                 group: .action, symbol: "safari"), .openURL(t.url))
        }

        // Records the app already holds.
        for p in model.products.sorted(by: { $0.name < $1.name }) {
            add(PaletteCandidate(id: "product.\(p.id)", title: p.name, subtitle: String(localized: "Product"),
                                 keywords: [p.id], group: .entity, symbol: "shippingbox"), .product(p.id))
        }
        for c in worktrack.companies {
            add(PaletteCandidate(id: "worktrack.\(c.companyId)", title: c.name, subtitle: String(localized: "WorkTrack customer"),
                                 keywords: [c.companyId, "worktrack"], group: .entity, symbol: "person.2.badge.key"),
                .go(.worktrackCustomers, .worktrackCompany(c.companyId)))
        }
        for r in licences.records {
            add(PaletteCandidate(id: "licence.\(r.licenceID)", title: "\(r.licenceID) · \(r.customer)",
                                 subtitle: "\(r.product.displayName) · \(r.status.title)",
                                 keywords: [r.product.displayName, r.machine, "licence"], group: .entity, symbol: "key.horizontal"),
                .go(.licences, .licence(r.licenceID)))
        }
        // Vault: title and product only. Never the login, password or notes.
        for e in vault.entries {
            add(PaletteCandidate(id: "vault.\(e.id.uuidString)", title: e.title, subtitle: "\(SidebarItem.vault.title) · \(e.product.title)",
                                 keywords: [e.product.rawValue, "vault"], group: .entity, symbol: "lock.rectangle.stack"),
                .go(.vault, .vaultSearch(e.title)))
        }
        // Keys & Backups: titles and products only (the path is shown on the screen, never a key's content).
        for k in keys.registry.keys {
            add(PaletteCandidate(id: "keys.\(k.id)", title: L(k.title), subtitle: "\(SidebarItem.keys.title) · \(k.kind.title)",
                                 keywords: [k.product ?? "", "key", "keystore", "backup"], group: .entity, symbol: k.kind.symbol),
                .go(.keys, nil))
        }
        // Website messages not marked seen: the sender's name only (no address, no text).
        for m in siteMessages.new {
            add(PaletteCandidate(id: "sitemessage.\(m.id)", title: m.name ?? String(localized: "Website message #\(m.id)"), subtitle: SidebarItem.siteMessages.title,
                                 keywords: ["message", "website", "contact"], group: .entity, symbol: "envelope"),
                .go(.siteMessages, nil))
        }
        for t in monitor.targets {
            add(PaletteCandidate(id: "monitor.\(t.id)", title: "\(t.product.title) \(L(t.name))", subtitle: t.host,
                                 keywords: ["monitor", t.url.absoluteString], group: .entity, symbol: "waveform.path.ecg"),
                .go(.monitor, nil))
        }
        for app in releases.apps {
            add(PaletteCandidate(id: "release.\(app.id)", title: app.name,
                                 subtitle: "\(SidebarItem.releaseCenter.title) · \(app.store == .appStore ? "App Store" : "Google Play")",
                                 keywords: [app.appIdentifier, app.productName], group: .entity,
                                 symbol: app.store == .appStore ? "applelogo" : "play.rectangle"), .go(.releaseCenter, nil))
        }
        for repo in releases.snapshot.repos {
            for pr in repo.pulls {
                add(PaletteCandidate(id: "pr.\(repo.repo.slug)#\(pr.number)", title: "#\(pr.number) \(pr.title)",
                                     subtitle: String(localized: "Open PR in \(repo.repo.slug)"),
                                     keywords: [repo.repo.slug, pr.head, "pr", "pull"], group: .entity, symbol: "arrow.triangle.pull"),
                    .openURL(pr.url))
            }
        }
        return (list, actions)
    }

    /// The English name of a sidebar item, so typing "monitor" finds «پایش».
    private func englishTitle(_ item: SidebarItem) -> String {
        item.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

/// Recent palette choices: ids only, in UserDefaults.
enum PaletteRecentsStore {
    static let key = "LCCPaletteRecents"

    static func load() -> PaletteRecents {
        guard let data = UserDefaults.standard.data(forKey: key) else { return PaletteRecents() }
        return (try? JSONDecoder().decode(PaletteRecents.self, from: data)) ?? PaletteRecents()
    }

    static func save(_ recents: PaletteRecents) {
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: key) }
    }
}
