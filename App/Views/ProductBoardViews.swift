import LinumicCore
import SwiftUI

// MARK: - Products (محصولات)

/// One card per product: each platform's live store version, newest build and version on main, whether its platforms are
/// level, then pull requests, CI, licences and health. Every value has its source and read time (on hover on the Mac, in
/// full on the product's page); a value not read says Unknown and why. Read-only.
struct ProductBoardView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, notLevel, unknown
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .notLevel: "Not level"
            case .unknown: "Level unknown"
            }
        }
    }

    @Environment(ProductsModel.self) private var products
    @Environment(AutomationEngine.self) private var automation
    @Environment(Router.self) private var router
    @State private var path: [String] = []
    @State private var filter: Filter = .all

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
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(report)
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if report.nothingRead {
                    ContentUnavailableView {
                        Label("Not read yet", systemImage: SidebarItem.productBoard.symbol)
                    } description: {
                        Text("This page is built from the Platforms and Release Center readings and the commits on each default branch. None has been read on this device yet.")
                    } actions: {
                        Button("Read now") { readNow() }
                    }
                } else if cards.isEmpty {
                    Text(filter == .notLevel ? "No product is known to be not level." : "No product's level is unknown.")
                        .foregroundStyle(.secondary)
                }
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

    /// The jobs this page is built from, one after another (the automation queue runs one job at a time).
    private func readNow() {
        automation.runNow(.platforms)
        automation.runNow(.releases)
        automation.runNow(.products)
    }

    private func header(_ report: ProductsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitRow(spacing: 8) {
                BoardPill(text: String(localized: "\(report.notLevel.count) not level"), symbol: "exclamationmark.triangle.fill",
                          color: report.notLevel.isEmpty ? .gray : .orange)
                BoardPill(text: String(localized: "\(report.level.count) level"), symbol: "checkmark.circle.fill", color: .green)
                BoardPill(text: String(localized: "\(report.unknown.count) level unknown"), symbol: "questionmark.circle.fill", color: .gray)
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
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Card

struct ProductBoardCard: View {
    let card: ProductCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: card.product.title).font(.headline)
                Spacer(minLength: 4)
                LevelBadge(state: card.level)
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            switch card.level {
            case .notLevel(let findings):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(findings.prefix(3)) { f in
                        Label { Text(verbatim: f.text).monospacedDigit() } icon: {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }
                    if findings.count > 3 {
                        Text("and \(findings.count - 3) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .unknown(let reasons):
                Text(verbatim: reasons.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            case .level, .nothingShipped:
                EmptyView()
            }
            platforms
            FitRow(spacing: 6) {
                pullsPill
                ciPill
                if let licences = card.licences { licencePill(licences) }
                healthPill
            }
            if let at = card.readAt {
                Text("Newest reading \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                      symbol: "arrow.triangle.pull", color: p.open > 0 ? .blue : .gray, help: BoardText.source(source, at))
        case .none(let why, _, _):
            BoardPill(text: String(localized: "No repository"), symbol: "arrow.triangle.pull", color: .gray, help: why)
        case .unknown(let why):
            BoardPill(text: String(localized: "PRs unknown"), symbol: "arrow.triangle.pull", color: .gray, help: why)
        }
    }

    private var ciPill: some View {
        switch card.ci {
        case .known(let ci, let source, let at):
            let failing = !ci.failing.isEmpty
            return BoardPill(text: failing ? String(localized: "CI failing") : (ci.passing.isEmpty ? String(localized: "No CI runs") : String(localized: "CI passing")),
                             symbol: failing ? "xmark.octagon.fill" : "checkmark.seal.fill", color: failing ? .red : (ci.passing.isEmpty ? .gray : .green),
                             help: BoardText.source(source, at))
        case .none(let why, _, _):
            return BoardPill(text: String(localized: "No repository"), symbol: "gearshape.2", color: .gray, help: why)
        case .unknown(let why):
            return BoardPill(text: String(localized: "CI unknown"), symbol: "gearshape.2", color: .gray, help: why)
        }
    }

    private func licencePill(_ value: Sourced<ProductLicences>) -> some View {
        switch value {
        case .known(let l, let source, let at):
            BoardPill(text: String(localized: "\(l.active) licences active"), symbol: "key.horizontal",
                      color: l.expired > 0 ? .red : (l.expiringSoon > 0 ? .orange : .teal), help: BoardText.source(source, at))
        case .none(let why, _, _), .unknown(let why):
            BoardPill(text: String(localized: "Licences unknown"), symbol: "key.horizontal", color: .gray, help: why)
        }
    }

    private var healthPill: some View {
        switch card.health {
        case .known(let h, let source, let at):
            // Addresses not checked yet are not "up": the pill says so instead of a green zero.
            BoardPill(text: h.unchecked == h.total ? String(localized: "Not checked yet")
                          : (h.down > 0 ? String(localized: "\(h.down) of \(h.total) down") : String(localized: "\(h.up + h.degraded) of \(h.total) up")),
                      symbol: "waveform.path.ecg",
                      color: h.down > 0 ? .red : (h.degraded > 0 || h.unchecked > 0 ? (h.unchecked == h.total ? .gray : .orange) : .green),
                      help: BoardText.source(source, at) + (h.unchecked > 0 ? " · " + String(localized: "\(h.unchecked) not checked") : ""))
        case .none(let why, _, _):
            BoardPill(text: String(localized: "Not monitored"), symbol: "waveform.path.ecg", color: .gray, help: why)
        case .unknown(let why):
            BoardPill(text: String(localized: "Health unknown"), symbol: "waveform.path.ecg", color: .gray, help: why)
        }
    }
}

// MARK: - One product

struct ProductBoardDetail: View {
    let productID: String
    @Environment(ProductsModel.self) private var products
    @Environment(Router.self) private var router

    var body: some View {
        if let card = products.report().card(productID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    levelPanel(card)
                    ForEach(card.tracks) { track in trackPanel(track) }
                    pullsPanel(card)
                    ciPanel(card)
                    if let licences = card.licences { licencePanel(licences) }
                    healthPanel(card)
                    linksPanel(card)
                }
                .padding(20)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .navigationTitle(Text(verbatim: card.product.title))
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark.circle")
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

    private func licencePanel(_ value: Sourced<ProductLicences>) -> some View {
        DashboardPanel(title: "Licences") {
            SourcedRow(title: "Licences", value: value) { l in
                String(localized: "\(l.active) active, \(l.expiringSoon) ending within 30 days, \(l.expired) expired, \(l.total) in the ledger")
            }
            Button { router.go(.licences) } label: { Label("Open Licences", systemImage: SidebarItem.licences.symbol) }
                .buttonStyle(.borderless)
        }
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

    private func linksPanel(_ card: ProductCard) -> some View {
        DashboardPanel(title: "Repositories") {
            ForEach(card.repos, id: \.self) { slug in
                if let url = URL(string: "https://github.com/\(slug)") {
                    Link(destination: url) { Label { Text(verbatim: slug) } icon: { Image(systemName: "chevron.left.forwardslash.chevron.right") } }
                        .font(.callout)
                }
            }
            FitRow(spacing: 12) {
                Button { router.go(.releaseCenter) } label: { Label("Open Releases", systemImage: SidebarItem.releaseCenter.symbol) }
                Button { router.go(.platforms) } label: { Label("Open Platforms", systemImage: SidebarItem.platforms.symbol) }
                Button { router.go(.agents) } label: { Label("Open Agents", systemImage: SidebarItem.agents.symbol) }
            }
            .buttonStyle(.borderless)
            Text(verbatim: card.product.source).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

/// "Level", "Not level", "Level unknown", "Nothing shipped yet", with an icon so color is never the only sign.
struct LevelBadge: View {
    let state: ProductLevelState

    var body: some View {
        let (symbol, color): (String, Color) = switch state {
        case .level: ("checkmark.circle.fill", .green)
        case .notLevel: ("exclamationmark.triangle.fill", .orange)
        case .unknown: ("questionmark.circle.fill", .gray)
        case .nothingShipped: ("circle.dashed", .gray)
        }
        BoardPill(text: state.title, symbol: symbol, color: color)
    }
}

struct BoardPill: View {
    let text: String
    let symbol: String
    let color: Color
    var help: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: typeSize.isAccessibilitySize ? 10 : 20, style: .continuous))
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
        .accessibilityElement(children: .combine)
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
