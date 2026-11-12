import LinumicCore
import SwiftUI

// MARK: - Products (محصولات)

/// One card per product: each platform's live store version, newest build and version on main, whether its platforms are
/// level, then pull requests, CI, licences and health. Every value has its source and read time (on hover on the Mac, in
/// full on the product's page); a value not read says Unknown and why. Read-only.
struct ProductBoardView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, notLevel, unknown
        /// Not a filter of the cards: every project's readiness scorecard, the weakest first (docs/readiness.md).
        case readiness
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .notLevel: "Not level"
            case .unknown: "Level unknown"
            case .readiness: "Readiness"
            }
        }

        /// The view the page opens on. Debug-only screenshot aid: `-LCCProjectsView readiness`.
        static var initial: Filter {
            #if DEBUG
            if let filter = UserDefaults.standard.string(forKey: "LCCProjectsView").flatMap(Filter.init(rawValue:)) { return filter }
            #endif
            return .all
        }
    }

    @Environment(ProductsModel.self) private var products
    @Environment(DeskModel.self) private var desk
    @Environment(KeysModel.self) private var keys
    @Environment(ObligationsModel.self) private var obligations
    @Environment(ContinuityModel.self) private var continuity
    @Environment(AutomationEngine.self) private var automation
    @Environment(Router.self) private var router
    @State private var path: [String] = []
    @State private var filter = Filter.initial

    var body: some View {
        NavigationStack(path: $path) {
            board
                .navigationDestination(for: String.self) { id in ProductBoardDetail(productID: id) }
        }
        // From the Desk, the Brief or the Command Palette: one product's page.
        .onChange(of: router.request, initial: true) {
            if case .productCard(let id) = router.take({ if case .productCard = $0 { true } else { false } }) { path = [id] }
        }
    }

    private var board: some View {
        let report = products.report()
        let cards: [ProductCard] = switch filter {
        case .all: report.cards
        case .notLevel: report.notLevel
        case .unknown: report.unknown
        case .readiness: []
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(report)
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)
                if report.nothingRead {
                    ContentUnavailableView {
                        Label("Not read yet", systemImage: SidebarItem.productBoard.symbol)
                    } description: {
                        Text("This page is built from the Platforms and Release Center readings and the commits on each default branch. None has been read on this device yet.")
                    } actions: {
                        Button("Read now") { readNow() }
                    }
                } else if cards.isEmpty, filter != .readiness {
                    Text(filter == .notLevel ? "No product is known to be not level." : "No product's level is unknown.")
                        .foregroundStyle(.secondary)
                }
                if filter == .readiness {
                    ReadinessPortfolioView(portfolio: readiness(report)) { path.append($0) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(cards) { card in
                            Button { path.append(card.id) } label: { ProductBoardCard(card: card) }
                                .buttonStyle(.plain)
                                .accessibilityHint(Text("Opens every value of this product with its source"))
                        }
                    }
                    Text("Read-only. Live versions come from App Store Connect and Google Play through the Release Center (or, when they were not read, the inventory's store listing), builds from those consoles or the product's GitHub releases, versions on main from each repository's version file, and commits on main from GitHub. Only real version numbers are compared.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle(SidebarItem.productBoard.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { readNow() } label: {
                    if products.isRefreshing { ProgressView().controlSize(.small) }
                    else { Label("Read now", systemImage: "arrow.clockwise") }
                }
                .disabled(products.isRefreshing)
                .keyboardShortcut("r")
                .help("Read the platforms, the stores, pull requests and CI, and the commits on main again (read-only)")
            }
        }
        .alert("Error", isPresented: Binding(get: { products.errorMessage != nil }, set: { if !$0 { products.errorMessage = nil } })) {
            Button("OK") { products.errorMessage = nil }
        } message: {
            Text(verbatim: products.errorMessage ?? "")
        }
    }

    /// Every project's scorecard, the weakest first, archived projects apart (the owner's tiers).
    private func readiness(_ report: ProductsReport) -> ReadinessPortfolio {
        let input = ReadinessInput.collect(cards: report.cards, products: products, desk: desk, keys: keys, obligations: obligations, continuity: continuity)
        let tiers = products.tiers
        return ReadinessBuilder.portfolio(ReadinessBuilder.build(input)) { tiers.tier(forProduct: $0) }
    }

    /// The jobs this page is built from, one after another (the automation queue runs one job at a time).
    private func readNow() {
        automation.runNow(.platforms)
        automation.runNow(.releases)
        automation.runNow(.products)
    }

    private func header(_ report: ProductsReport) -> some View {
        PageHeader(.productBoard) {
            PillRow(spacing: 8) {
                BoardPill(text: String(localized: "\(report.notLevel.count) not level"), symbol: "exclamationmark.triangle.fill",
                          color: report.notLevel.isEmpty ? .statusUnknown : .statusWarn)
                BoardPill(text: String(localized: "\(report.level.count) level"), symbol: "checkmark.circle.fill", color: .statusGood)
                BoardPill(text: String(localized: "\(report.unknown.count) level unknown"), symbol: "questionmark.circle.fill", color: .statusUnknown)
            }
            Group {
                if let last = products.file.lastRefresh {
                    Text("Commits and agents last read from GitHub: \(last.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Commits on main not read from GitHub yet.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let report = products.lastReport, !report.failed.isEmpty {
                ForEach(report.failed.sorted(by: { $0.key < $1.key }).prefix(4), id: \.key) { repo, message in
                    Label { Text(verbatim: "\(repo): \(message)") } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.statusWarn)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Card

struct ProductBoardCard: View {
    let card: ProductCard
    /// Desk rows of this product that wait on the owner, on the management centre; 0 shows nothing.
    var waiting = 0
    @State private var isOpen = false
    /// Every card is this tall until it is opened (owner, 2026-11-02): one size, and the detail one click away. Tall
    /// enough for two lines of the summary: at 132 the second line had no room and the sentence was cut at one.
    @ScaledMetric(relativeTo: .body) private var closedHeight: CGFloat = 144
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two lines of summary; at an accessibility text size, where a line holds few words, up to five.
    private var summaryLines: Int { typeSize.isAccessibilitySize ? 5 : 2 }

    var body: some View {
        // At an accessibility text size the badge goes under the name and the card is as tall as it needs: beside the
        // badge the name was cut ("WorkTr…"), and the fixed height hid what did not fit.
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: card.product.title).font(.headline).lineLimit(large ? 2 : 1)
                Spacer(minLength: 4)
                if !large { LevelBadge(state: card.level) }
                Button { withAnimation(.snappy) { isOpen.toggle() } } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .frame(width: 32, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .minTapTarget()
                .accessibilityLabel(isOpen ? Text("Close the card") : Text("Open the card"))
                .help(isOpen ? Text("Close the card") : Text("Open the card"))
            }
            if large { LevelBadge(state: card.level) }
            summary
            ProjectStatusPills(card: card, waiting: waiting)
            if isOpen {
                details.transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: isOpen || large ? nil : closedHeight, maxHeight: isOpen || large ? nil : closedHeight, alignment: .topLeading)
        .clipped()
        .cardSurface()
        // The level on the leading edge: green, amber, or grey when it is not known.
        .overlay(alignment: .leading) { AccentEdge(tint: card.level.tint) }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .hoverHighlight(cornerRadius: Theme.Radius.card)
    }

    /// What a closed card says about its level, in two lines at most: one line cut the sentence before what it is
    /// about ("… is behind main, 76 commits"), on iPhone and in a two-column grid alike.
    @ViewBuilder
    private var summary: some View {
        switch card.level {
        case .notLevel(let findings):
            if let first = findings.first {
                Label { DirectionalText(first.text).monospacedDigit().lineLimit(summaryLines).multilineTextAlignment(.leading) } icon: {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.statusWarn)
                }
                .font(.callout)
            }
        case .unknown(let reasons):
            DirectionalText(reasons.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(summaryLines).multilineTextAlignment(.leading)
        case .level, .nothingShipped, .nothingCompared:
            EmptyView()
        }
    }

    /// What an open card adds.
    @ViewBuilder
    private var details: some View {
        Divider()
        switch card.level {
        case .notLevel(let findings) where findings.count > 1:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(findings.dropFirst()) { f in
                    Label { DirectionalText(f.text).monospacedDigit() } icon: {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.statusWarn)
                    }
                    .font(.callout)
                }
            }
        case .unknown(let reasons) where reasons.count > 1:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(reasons.dropFirst(), id: \.self) { DirectionalText($0).font(.caption).foregroundStyle(.secondary) }
            }
        default:
            EmptyView()
        }
        // A project with no compared platform has no rows: no grid of empty headers.
        if card.tracks.contains(where: { $0.slots.contains(where: \.slot.compared) }) { platforms }
        FitRow(spacing: 6) {
            pullsPill
            ciPill
            healthPill
        }
        if let licences = card.licences { licencePill(licences) }
        if let at = card.readAt {
            Text("Newest reading \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// The compared platforms (the apps people install), one row each: store, build, main.
    private var platforms: some View {
        let tracks = card.tracks.filter { $0.slots.contains(where: \.slot.compared) }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text(verbatim: "")
                Text("Store").foregroundStyle(.secondary)
                Text("Build").foregroundStyle(.secondary)
                Text("Main").foregroundStyle(.secondary)
            }
            .font(.caption)
            ForEach(tracks) { track in
                if tracks.count > 1 {
                    GridRow {
                        Text(verbatim: L(track.track.title)).font(.caption.weight(.semibold)).gridCellColumns(4)
                    }
                }
                ForEach(track.slots.filter(\.slot.compared)) { s in
                    GridRow {
                        Text(s.slot.platform.title).foregroundStyle(.secondary)
                        SourcedCell(value: s.live)
                        SourcedCell(value: s.build)
                        SourcedCell(value: s.main)
                    }
                }
            }
        }
        .font(.callout)
    }

    private var pullsPill: some View {
        switch card.pulls {
        case .known(let p, let source, let at):
            BoardPill(text: p.byAgents > 0 ? String(localized: "\(p.open) open PRs, \(p.byAgents) by agents") : String(localized: "\(p.open) open PRs"),
                      symbol: "arrow.triangle.pull", color: p.open > 0 ? .statusInfo : .statusUnknown, help: BoardText.source(source, at))
        case .none(let why, _, _):
            BoardPill(text: String(localized: "No repository"), symbol: "arrow.triangle.pull", color: .statusUnknown, help: why)
        case .unknown(let why):
            BoardPill(text: String(localized: "PRs unknown"), symbol: "arrow.triangle.pull", color: .statusUnknown, help: why)
        }
    }

    private var ciPill: some View {
        switch card.ci {
        case .known(let ci, let source, let at):
            let failing = !ci.failing.isEmpty
            return BoardPill(text: failing ? String(localized: "CI failing") : (ci.passing.isEmpty ? String(localized: "No CI runs") : String(localized: "CI passing")),
                             symbol: failing ? "xmark.octagon.fill" : "checkmark.seal.fill", color: failing ? .statusBad : (ci.passing.isEmpty ? .statusUnknown : .statusGood),
                             help: BoardText.source(source, at))
        case .none(let why, _, _):
            return BoardPill(text: String(localized: "No repository"), symbol: "gearshape.2", color: .statusUnknown, help: why)
        case .unknown(let why):
            return BoardPill(text: String(localized: "CI unknown"), symbol: "gearshape.2", color: .statusUnknown, help: why)
        }
    }

    private func licencePill(_ value: Sourced<ProductLicences>) -> some View {
        switch value {
        case .known(let l, let source, let at):
            BoardPill(text: String(localized: "\(l.active) licences active"), symbol: "key.horizontal",
                      color: l.expired > 0 ? .statusBad : (l.expiringSoon > 0 ? .statusWarn : .statusInfo), help: BoardText.source(source, at))
        case .none(let why, _, _), .unknown(let why):
            BoardPill(text: String(localized: "Licences unknown"), symbol: "key.horizontal", color: .statusUnknown, help: why)
        }
    }

    private var healthPill: some View {
        switch card.health {
        case .known(let h, let source, let at):
            // Addresses not checked yet are not "up": the pill says so instead of a green zero.
            BoardPill(text: h.unchecked == h.total ? String(localized: "Not checked yet")
                          : (h.down > 0 ? String(localized: "\(h.down) of \(h.total) down") : String(localized: "\(h.up + h.degraded) of \(h.total) up")),
                      symbol: "waveform.path.ecg",
                      color: h.down > 0 ? .statusBad : (h.degraded > 0 || h.unchecked > 0 ? (h.unchecked == h.total ? .statusUnknown : .statusWarn) : .statusGood),
                      help: BoardText.source(source, at) + (h.unchecked > 0 ? " · " + String(localized: "\(h.unchecked) not checked") : ""))
        case .none(let why, _, _):
            BoardPill(text: String(localized: "Not monitored"), symbol: "waveform.path.ecg", color: .statusUnknown, help: why)
        case .unknown(let why):
            BoardPill(text: String(localized: "Health unknown"), symbol: "waveform.path.ecg", color: .statusUnknown, help: why)
        }
    }
}

// MARK: - One project (its page, with tabs)

/// The tabs of a project's page. Each tab shows only this project's part of an existing page, with the same views, and
/// ends with a link to the whole page.
enum ProjectTab: String, CaseIterable, Identifiable {
    case overview, releases, code, health

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .releases: "Releases"
        case .code: "Code"
        case .health: "Health"
        }
    }

    /// The tab a page opens on. Debug-only screenshot aid: `-LCCProjectTab releases`.
    static var initial: ProjectTab {
        #if DEBUG
        if let tab = UserDefaults.standard.string(forKey: "LCCProjectTab").flatMap(ProjectTab.init(rawValue:)) { return tab }
        #endif
        return .overview
    }
}

/// A project's page: what waits on the owner and the level first, then, one tab at a time, its releases, its code and
/// its health. Every value keeps its source and read time. Read-only.
struct ProductBoardDetail: View {
    let productID: String
    @Environment(ProductsModel.self) private var products
    @Environment(DeskModel.self) private var desk
    @Environment(ReleaseCenterModel.self) private var releases
    @Environment(MonitorModel.self) private var monitor
    @Environment(KeysModel.self) private var keys
    @Environment(ObligationsModel.self) private var obligations
    @Environment(ContinuityModel.self) private var continuity
    @Environment(Router.self) private var router
    @State private var tab = ProjectTab.initial
    @State private var showUncompared = false

    private let grid = [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)]

    var body: some View {
        if let card = products.report().card(productID) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(card)
                        switch tab {
                        case .overview: overview(card)
                        case .releases: releasesTab(card)
                        case .code: codeTab(card)
                        case .health: healthTab(card)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1000, alignment: .leading)
                }
                #if DEBUG
                // Debug-only screenshot aid: `-LCCScrollTo readiness` opens the page scrolled to that panel.
                .task {
                    guard let anchor = UserDefaults.standard.string(forKey: "LCCScrollTo") else { return }
                    try? await Task.sleep(for: .milliseconds(700))
                    proxy.scrollTo(anchor, anchor: .top)
                }
                #endif
            }
            .navigationTitle(Text(verbatim: card.product.title))
            // From the Center: a line about an app on this Mac opens this page on Releases.
            .onChange(of: router.pendingProjectTab, initial: true) {
                if let next = router.pendingProjectTab {
                    tab = next
                    router.pendingProjectTab = nil
                }
            }
            .toolbar {
                ToolbarItem {
                    // Where this project sits on the centre. Nothing else about it changes.
                    Picker("Show on the management center as", selection: Binding(
                        get: { products.tiers.tier(forProduct: productID) },
                        set: { products.setTier($0, forProduct: productID) }
                    )) {
                        ForEach(CenterTier.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark.circle")
        }
    }

    /// The project's name, its status in the same pills as its card, and the tabs.
    private func header(_ card: ProductCard) -> some View {
        PageHeader(title: card.product.title, symbol: SidebarItem.productBoard.symbol) {
            PillRow(spacing: 6) {
                LevelBadge(state: card.level)
                ProjectStatusPills(card: card, waiting: waitingRows(card).count)
            }
            Picker("Section", selection: $tab) {
                ForEach(ProjectTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
        }
    }

    // MARK: Overview

    @ViewBuilder
    private func overview(_ card: ProductCard) -> some View {
        waitingPanel(card)
        levelPanel(card)
        readinessPanel(card)
        relatedPanel(card)
    }

    /// The project's readiness scorecard: the same checks as every other project's, from what the app already holds.
    @ViewBuilder
    private func readinessPanel(_ card: ProductCard) -> some View {
        let input = ReadinessInput.collect(cards: [card], products: products, desk: desk, keys: keys, obligations: obligations, continuity: continuity)
        if let readiness = ReadinessBuilder.build(input).first {
            ReadinessPanel(readiness: readiness).id("readiness")
        }
    }

    private func waitingRows(_ card: ProductCard) -> [DeskRow] {
        desk.desk().open.filter { $0.item.ownerAction && $0.item.domain == card.product.deskDomain }
    }

    /// What waits on the owner for this project, from the Desk. Nothing shows when nothing does. Quiet agents are one
    /// line, as on the centre, that opens this project's Code tab, where their cards are.
    @ViewBuilder
    private func waitingPanel(_ card: ProductCard) -> some View {
        let rows = waitingRows(card)
        let quiet = rows.filter(CenterBuilder.isQuietAgentRow)
        if !rows.isEmpty {
            DashboardPanel(title: "Waiting on you") {
                // Flush with the panel's title: the panel's own padding is the rows' margin.
                ForEach(rows.filter { !CenterBuilder.isQuietAgentRow($0) }) { CenterDeskRow(row: $0, inset: 0) }
                if !quiet.isEmpty {
                    Button { tab = .code } label: {
                        Label { Text("\(quiet.count) agents with no recent pull request") } icon: { Image(systemName: "moon.zzz") }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func levelPanel(_ card: ProductCard) -> some View {
        DashboardPanel(title: "Level across platforms") {
            LevelBadge(state: card.level)
            switch card.level {
            case .level:
                Text("Every compared platform was read: the same versions, and no build is behind main.").foregroundStyle(.secondary)
            case .nothingShipped:
                Text("No compared platform has a build or a store version yet.").foregroundStyle(.secondary)
            case .nothingCompared:
                Text("No platform of this project is compared: none is read from a store, a GitHub release or a version file, so there is nothing to level.")
                    .foregroundStyle(.secondary)
            case .notLevel(let findings):
                // The track's name only when the product has more than one app that is compared (VELRO Ride, Driver, Ops).
                let named = card.product.tracks.filter { $0.slots.contains(where: \.compared) }.count > 1
                ForEach(findings) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        if named { Text(verbatim: L(f.track)).font(.caption).foregroundStyle(.secondary) }
                        Text(verbatim: f.text).monospacedDigit().textSelection(.enabled)
                    }
                }
            case .unknown:
                EmptyView()
            }
            if !card.unread.isEmpty {
                Text("Not read, so not known:").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(card.unread, id: \.self) { u in
                    Label { Text(verbatim: u) } icon: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                        .font(.caption)
                }
            }
            Text("Not level: built or live versions differ, a platform has no build while another has one, or a build is behind main by version, or by commits for \(ProductLevelRule.behindDays) days or more.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The other pages that hold something of this project (its customers, its operations, its licences, its marketing
    /// queue). They are company-wide pages under More; this is the way to them from here.
    @ViewBuilder
    private func relatedPanel(_ card: ProductCard) -> some View {
        let pages = related(card)
        if !pages.isEmpty {
            DashboardPanel(title: "Also on other pages") {
                FitRow(spacing: 14) {
                    ForEach(pages, id: \.self) { page in
                        Button { open(page) } label: { Label(title(page), systemImage: page.item.symbol) }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Releases

    /// The apps people install first; parts that are never compared (a console, a backend) behind one tap.
    @ViewBuilder
    private func releasesTab(_ card: ProductCard) -> some View {
        let compared = card.tracks.filter { $0.slots.contains(where: \.slot.compared) }
        let others = card.tracks.filter { !$0.slots.contains(where: \.slot.compared) }
        installedPanel(card)
        ForEach(compared) { track in trackPanel(track) }
        storeCards(card)
        if !others.isEmpty {
            DisclosureGroup(isExpanded: $showUncompared) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(others) { track in trackPanel(track) }
                }
                .padding(.top, 8)
            } label: {
                Text("Parts that are not compared").font(.headline)
            }
        }
        FitRow(spacing: 14) {
            Button { router.go(.releaseCenter) } label: { Label("Open Releases", systemImage: SidebarItem.releaseCenter.symbol) }
            Button { router.go(.platforms) } label: { Label("Open Platforms", systemImage: SidebarItem.platforms.symbol) }
        }
        .buttonStyle(.borderless)
    }

    /// This project's Mac apps as /Applications holds them, against its newest release. Mac only (iPhone and iPad have no
    /// /Applications to read); nothing shows for a project with no catalogued Mac app.
    @ViewBuilder
    private func installedPanel(_ card: ProductCard) -> some View {
        let apps = products.installedStatuses().filter { $0.spec.productID == card.product.id }
        if !apps.isEmpty {
            DashboardPanel(title: "Installed on this Mac") {
                ForEach(apps) { app in
                    InstalledAppRow(status: app).padding(.vertical, 4)
                    if app.id != apps.last?.id { Divider() }
                }
                Text("Only each app's Info.plist is read; the app is never run and its data is never opened. It is called current only when it records that it was built from the release's tag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { products.readInstalledApps() }
        }
    }

    private func trackPanel(_ track: TrackReading) -> some View {
        DashboardPanel(title: L(track.track.title)) {
            ForEach(track.slots) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(s.slot.platform.title).font(.callout.weight(.semibold))
                        Text(verbatim: L(s.slot.label)).font(.callout).foregroundStyle(.secondary)
                        if !s.slot.compared {
                            Text("not compared").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    SourcedRow(title: "In the store", value: s.live) { BoardText.stamp($0) }
                    SourcedRow(title: "Newest build", value: s.build) { BoardText.stamp($0) }
                    SourcedRow(title: "On main", value: s.main) { BoardText.stamp($0) }
                    if s.build.isKnown { SourcedRow(title: "Behind main", value: s.behind) { BoardText.behind($0) } }
                    if let health = s.health { SourcedRow(title: "Health", value: health) { BoardText.health($0) } }
                }
                .padding(.vertical, 4)
                if s.id != track.slots.last?.id { Divider() }
            }
        }
    }

    /// This project's apps as the Releases page reads them from App Store Connect and Google Play, with the same cards.
    /// Releasing a version stays on the Releases page, where its confirmation is.
    @ViewBuilder
    private func storeCards(_ card: ProductCard) -> some View {
        let id = card.product.inventoryID
        let apps = releases.snapshot.appStore.filter { id != nil && $0.app.productID == id }
        let play = releases.snapshot.play.filter { id != nil && $0.app.productID == id }
        if !apps.isEmpty || !play.isEmpty {
            sectionTitle("In the stores")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(apps) { AppStoreCard(status: $0, onRelease: { _ in router.go(.releaseCenter) }) }
                ForEach(play) { PlayCard(status: $0) }
            }
        }
    }

    // MARK: Code

    @ViewBuilder
    private func codeTab(_ card: ProductCard) -> some View {
        pullsPanel(card)
        ciPanel(card)
        agentCards(card)
        linksPanel(card)
    }

    private func pullsPanel(_ card: ProductCard) -> some View {
        DashboardPanel(title: "Open pull requests") {
            SourcedRow(title: "Open", value: card.pulls) { p in
                p.byAgents > 0 ? String(localized: "\(p.open) open, \(p.drafts) drafts, \(p.byAgents) by agents") : String(localized: "\(p.open) open, \(p.drafts) drafts")
            }
            if let pulls = card.pulls.value?.pulls {
                ForEach(pulls) { p in
                    Link(destination: p.pull.url) {
                        Label { Text(verbatim: "#\(p.pull.number) \(p.pull.title)").lineLimit(2) } icon: {
                            Image(systemName: p.pull.isDraft ? "pencil.circle" : "arrow.triangle.pull")
                        }
                    }
                    .font(.callout)
                    .help(Text(verbatim: "\(p.repo) · \(p.pull.head) → \(p.pull.base) · \(p.pull.ci.title)"))
                }
            }
        }
    }

    private func ciPanel(_ card: ProductCard) -> some View {
        DashboardPanel(title: "CI on the default branch") {
            SourcedRow(title: "CI", value: card.ci) { ci in
                var parts: [String] = []
                if !ci.failing.isEmpty { parts.append(String(localized: "failing: \(ci.failing.joined(separator: ", "))")) }
                if !ci.running.isEmpty { parts.append(String(localized: "running: \(ci.running.joined(separator: ", "))")) }
                if !ci.passing.isEmpty { parts.append(String(localized: "passing: \(ci.passing.joined(separator: ", "))")) }
                if !ci.noRuns.isEmpty { parts.append(String(localized: "no runs: \(ci.noRuns.joined(separator: ", "))")) }
                return parts.joined(separator: " · ")
            }
        }
    }

    /// The scheduled agents that work on this project's repositories, with the Agents page's own cards.
    @ViewBuilder
    private func agentCards(_ card: ProductCard) -> some View {
        let repos = Set(card.repos.map { $0.lowercased() })
        let report = products.agents()
        let mine = report.statuses.filter { s in s.agent.repositories.contains { repos.contains($0.lowercased()) } }
        if !mine.isEmpty {
            sectionTitle("Agents")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(mine, id: \.agent.slug) { AgentCard(status: $0, quietAfter: report.registry.rules.quietAfterDays, highlighted: false) }
            }
        }
    }

    private func linksPanel(_ card: ProductCard) -> some View {
        DashboardPanel(title: "Repositories") {
            ForEach(card.repos, id: \.self) { slug in
                if let url = URL(string: "https://github.com/\(slug)") {
                    Link(destination: url) { Label { Text(verbatim: slug) } icon: { Image(systemName: "chevron.left.forwardslash.chevron.right") } }
                        .font(.callout)
                }
            }
            FitRow(spacing: 12) {
                Button { router.go(.agents) } label: { Label("Open Agents", systemImage: SidebarItem.agents.symbol) }
                Button { router.go(.oversight) } label: { Label("Open Oversight", systemImage: SidebarItem.oversight.symbol) }
            }
            .buttonStyle(.borderless)
            Text(verbatim: card.product.source).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Health

    @ViewBuilder
    private func healthTab(_ card: ProductCard) -> some View {
        healthPanel(card)
        if let product = card.product.monitor {
            let targets = monitor.targets(for: product)
            if !targets.isEmpty {
                LazyVGrid(columns: grid, spacing: 12) {
                    ForEach(targets) { MonitorCard(target: $0) }
                }
            }
        }
        if let licences = card.licences { licencePanel(licences) }
    }

    private func healthPanel(_ card: ProductCard) -> some View {
        DashboardPanel(title: "Health") {
            SourcedRow(title: "Monitor", value: card.health) { BoardText.health($0) }
            if card.product.monitor != nil {
                Button { router.go(.monitor) } label: { Label("Open Monitor", systemImage: SidebarItem.monitor.symbol) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func licencePanel(_ value: Sourced<ProductLicences>) -> some View {
        DashboardPanel(title: "Licences") {
            SourcedRow(title: "Licences", value: value) { l in
                String(localized: "\(l.active) active, \(l.expiringSoon) ending within 30 days, \(l.expired) expired, \(l.total) in the ledger")
            }
            Button { router.go(.licences) } label: { Label("Open Licences", systemImage: SidebarItem.licences.symbol) }
                .buttonStyle(.borderless)
        }
    }

    // MARK: Parts

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader).padding(.top, 4)
    }

    /// A company-wide page that holds part of a project.
    private enum RelatedPage: Hashable {
        case page(SidebarItem)
        case operations(OperationsProduct)

        var item: SidebarItem {
            switch self {
            case .page(let item): item
            case .operations: .operations
            }
        }
    }

    private func related(_ card: ProductCard) -> [RelatedPage] {
        var out: [RelatedPage] = []
        switch card.product.id {
        case "worktrack": out += [.page(.worktrackCustomers), .page(.sales), .page(.money)]
        case "talar": out.append(.operations(.talar))
        case "safebeauty": out += [.operations(.safeBeauty), .page(.money)]
        case "velro": out.append(.operations(.velro))
        default: break
        }
        if card.product.licence != nil { out.append(.page(.licences)) }
        // The brands with a marketing queue (MarketingQueue: WorkTrack, SafeBeauty, VELRO).
        if ["worktrack", "safebeauty", "velro"].contains(card.product.id) { out.append(.page(.marketingQueue)) }
        return out
    }

    private func title(_ page: RelatedPage) -> String {
        switch page {
        case .page(let item): item.title
        case .operations(let product): "\(SidebarItem.operations.title): \(product.title)"
        }
    }

    private func open(_ page: RelatedPage) {
        switch page {
        case .page(let item): router.go(item)
        case .operations(let product):
            router.operationsTab = product
            router.go(.operations)
        }
    }
}

/// The few things a project's card and its page always say, short enough to stay on one line: what waits on the owner,
/// pull requests, CI and health. The full sentence is the pill's help, the open card and the project's tabs.
struct ProjectStatusPills: View {
    let card: ProductCard
    var waiting = 0

    var body: some View {
        HStack(spacing: 6) {
            // Each pill is short on screen and says its whole sentence to VoiceOver. A reading that is not known is quiet
            // (no capsule), so the pills that say something are the ones seen.
            if waiting > 0 {
                BoardPill(text: waiting.formatted(), symbol: "person.fill.checkmark", color: .statusWarn, help: String(localized: "\(waiting) waiting"),
                          spoken: String(localized: "\(waiting) waiting"))
            }
            switch card.pulls {
            case .known(let p, let source, let at):
                BoardPill(text: String(localized: "\(p.open) PR"), symbol: "arrow.triangle.pull",
                          color: p.open > 0 ? .statusInfo : .statusUnknown, help: BoardText.source(source, at),
                          spoken: String(localized: "\(p.open) open PRs"))
            case .none(let why, _, _), .unknown(let why):
                BoardPill(text: "PR ?", symbol: "arrow.triangle.pull", color: .statusUnknown, help: why, spoken: why, quiet: true)
            }
            switch card.ci {
            case .known(let ci, let source, let at):
                BoardPill(text: "CI", symbol: !ci.failing.isEmpty ? "xmark.octagon.fill" : "checkmark.seal.fill",
                          color: !ci.failing.isEmpty ? .statusBad : (ci.passing.isEmpty ? .statusUnknown : .statusGood), help: BoardText.source(source, at),
                          spoken: !ci.failing.isEmpty ? String(localized: "CI failing") : (ci.passing.isEmpty ? String(localized: "No CI runs") : String(localized: "CI passing")))
            case .none(let why, _, _), .unknown(let why):
                BoardPill(text: "CI ?", symbol: "gearshape.2", color: .statusUnknown, help: why, spoken: why, quiet: true)
            }
            switch card.health {
            case .known(let h, let source, let at):
                BoardPill(text: "\(h.up.formatted())/\(h.total.formatted())", symbol: "waveform.path.ecg",
                          color: h.down > 0 ? .statusBad : (h.degraded > 0 ? .statusWarn : (h.unchecked > 0 ? .statusUnknown : .statusGood)), help: BoardText.source(source, at),
                          spoken: BoardText.health(h))
            case .none(let why, _, _), .unknown(let why):
                BoardPill(text: "–", symbol: "waveform.path.ecg", color: .statusUnknown, help: why, spoken: why, quiet: true)
            }
        }
    }
}

// MARK: - Pieces

/// "Level", "Not level", "Level unknown", "Nothing shipped yet", "No platform compared", with an icon so color is never
/// the only sign.
extension ProductLevelState {
    /// Level is green, not level orange; unknown, nothing shipped and nothing compared stay grey, never green.
    var tint: Color {
        switch self {
        case .level: .statusGood
        case .notLevel: .statusWarn
        case .unknown, .nothingShipped, .nothingCompared: .statusUnknown
        }
    }
}

struct LevelBadge: View {
    let state: ProductLevelState

    var body: some View {
        let symbol = switch state {
        case .level: "checkmark.circle.fill"
        case .notLevel: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        case .nothingShipped: "circle.dashed"
        case .nothingCompared: "minus.circle"
        }
        BoardPill(text: state.title, symbol: symbol, color: state.tint)
    }
}

/// One app on this Mac: its verdict, the sentence, and the two readings it is built from, each with its source.
struct InstalledAppRow: View {
    let status: InstalledAppStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: status.spec.name).font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                InstalledVerdictBadge(verdict: status.verdict)
            }
            // Unknown and not installed are said by the reading itself, below; the sentence would repeat it.
            switch status.verdict {
            case .notInstalled, .unknown: EmptyView()
            default: DirectionalText(status.verdict.sentence).font(.callout).monospacedDigit().textSelection(.enabled)
            }
            SourcedRow(title: "Installed", value: status.installed) { $0.label }
            SourcedRow(title: "Newest release", value: status.newest) { $0.label }
        }
    }
}

/// Current is green; behind and a test build amber; a build newer than every release blue; the same version (how it was
/// built not recorded), not installed and unknown grey, never green.
extension InstalledVerdict {
    var tint: Color {
        switch self {
        case .current: .statusGood
        case .behind, .testBuild: .statusWarn
        case .unreleased: .statusInfo
        case .sameVersion, .notInstalled, .unknown: .statusUnknown
        }
    }

    var symbol: String {
        switch self {
        case .current: "checkmark.circle.fill"
        case .sameVersion: "equal.circle"
        case .behind: "arrow.down.circle.fill"
        case .testBuild: "testtube.2"
        case .unreleased: "arrow.up.circle"
        case .notInstalled: "minus.circle"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

struct InstalledVerdictBadge: View {
    let verdict: InstalledVerdict

    var body: some View {
        BoardPill(text: verdict.title, symbol: verdict.symbol, color: verdict.tint, help: verdict.sentence)
    }
}

struct BoardPill: View {
    let text: String
    let symbol: String
    let color: Color
    var help: String?
    /// What VoiceOver says when the pill's text is an abbreviation ("PR ?", "3/3"); the text itself otherwise.
    var spoken: String?
    /// Icon and word in the secondary colour with no capsule: for a reading that is not known, beside pills that say
    /// something. A card with nothing read had three grey capsules that weighed as much as its one real status.
    var quiet = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(color)).accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(PillTone.text(color, in: environment)))
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, quiet ? 2 : 8)
        .padding(.vertical, 3)
        .pillBackground(quiet ? .clear : color, radius: typeSize.isAccessibilitySize ? 10 : nil)
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken ?? text))
        .help(Text(verbatim: help ?? text))
    }
}

/// A value in the card's grid: the version, a dash for none, or Unknown; the source and read time on hover.
struct SourcedCell: View {
    let value: Sourced<VersionStamp>

    var body: some View {
        switch value {
        case .known(let v, let source, let at):
            Text(verbatim: v.label).monospacedDigit().lineLimit(1)
                .help(Text(verbatim: BoardText.source(source, at)))
        case .none(let why, _, _):
            Text(verbatim: "—").foregroundStyle(.tertiary)
                .help(Text(verbatim: why))
                .accessibilityLabel(Text(verbatim: why))
        case .unknown(let why):
            Text("Unknown").italic().foregroundStyle(.secondary).lineLimit(1)
                .help(Text(verbatim: why))
                .accessibilityLabel(Text("Unknown: \(why)"))
        }
    }
}

/// A labelled value with its source and read time below it, or what was found (none) or why it is unknown.
struct SourcedRow<Value: Hashable & Sendable>: View {
    let title: LocalizedStringKey
    let value: Sourced<Value>
    let text: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                switch value {
                case .known(let v, _, _): Text(verbatim: text(v)).monospacedDigit().textSelection(.enabled)
                case .none(let why, _, _): Text(verbatim: why).foregroundStyle(.secondary)
                case .unknown(let why):
                    Text("Unknown").italic().foregroundStyle(.secondary)
                    Text(verbatim: why).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let source = value.source {
                SourceLine(reference: source, date: value.readAt)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum BoardText {
    static func source(_ source: String, _ at: Date?) -> String {
        guard let at else { return source }
        return "\(source) · \(at.formatted(date: .abbreviated, time: .shortened))"
    }

    /// "1.4.0 (11) · 2026/10/13 · Rolled out".
    static func stamp(_ v: VersionStamp) -> String {
        ([v.label] + [v.date?.shortDate, v.detail].compactMap { $0 }).joined(separator: " · ")
    }

    static func behind(_ b: BehindMain) -> String {
        b.commits == 0 ? String(localized: "No commit on main after this build")
            : String(localized: "\(b.commitsText) on main after this build; the newest is \(b.days) days later")
    }

    static func health(_ h: HealthSummary) -> String {
        var parts = [String(localized: "\(h.up) up")]
        if h.degraded > 0 { parts.append(String(localized: "\(h.degraded) slow")) }
        if h.down > 0 { parts.append(String(localized: "\(h.down) down")) }
        if h.unchecked > 0 { parts.append(String(localized: "\(h.unchecked) not checked")) }
        return parts.joined(separator: ", ")
    }
}
