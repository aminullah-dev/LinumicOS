import LinumicCore
import SwiftUI

struct DashboardView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(LicenceModel.self) private var licences
    @Environment(PlatformHubModel.self) private var platforms
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(OperationsModel.self) private var operations
    @Environment(SiteMessagesModel.self) private var siteMessages
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private var statusColumns: Int { sizeClass != .compact ? 4 : typeSize.isAccessibilitySize ? 1 : 2 }
    #else
    private let statusColumns = 4
    #endif

    var body: some View {
        let s = model.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if s.pendingConfirmations > 0 {
                    Button { router.sidebar = .verification } label: {
                        HStack {
                            Image(systemName: s.conflictingItems > 0 ? "exclamationmark.triangle.fill" : "person.badge.clock")
                                .foregroundStyle(s.conflictingItems > 0 ? .red : .orange)
                            if s.conflictingItems > 0 {
                                Text("\(s.pendingConfirmations) facts need your confirmation, \(s.conflictingItems) of them conflicting. Open Verification →")
                            } else {
                                Text("\(s.pendingConfirmations) facts need your confirmation. Open Verification →")
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background((s.conflictingItems > 0 ? Color.red : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                MonitorStatusStrip()

                WaitingOnYouCard()

                platformsCard

                oversightCard

                licencesCard

                worktrackCard

                waitingCard

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: statusColumns), spacing: 12) {
                    ForEach([VerificationStatus.verified, .partiallyVerified, .unknown, .conflicting]) { status in
                        VStack(alignment: .leading, spacing: 6) {
                            VerificationBadge(status: status)
                            Text("\(s.countsByVerification[status, default: 0]) products").font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(s.countsByVerification[status, default: 0]) products \(status.title)")
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Total products", value: s.totalProducts, symbol: "shippingbox")
                    MetricTile(title: "Active (recorded)", value: s.activeCount, symbol: "checkmark.circle", tint: .green)
                    MetricTile(title: "In development (recorded)", value: s.inDevelopmentCount, symbol: "hammer", tint: .blue)
                    MetricTile(title: "Status unknown", value: s.unknownStatusCount, symbol: "questionmark.circle", tint: .gray)
                    MetricTile(title: "Upcoming releases", value: s.upcomingReleases.count, symbol: "tag", tint: .indigo)
                    MetricTile(title: "Blocked releases", value: s.blockedReleases.count, symbol: "xmark.octagon", tint: s.blockedReleases.isEmpty ? .secondary : .red)
                    MetricTile(title: "Critical issues", value: s.openCriticalIssues.count, symbol: "exclamationmark.triangle", tint: s.openCriticalIssues.isEmpty ? .secondary : .red)
                }

                AdaptiveStack {
                    DashboardPanel(title: "Upcoming releases") {
                        if s.upcomingReleases.isEmpty {
                            EmptyPanelText("No upcoming releases recorded.")
                        } else {
                            ForEach(s.upcomingReleases.prefix(8)) { ref in
                                releaseRow(ref)
                            }
                        }
                    }
                    DashboardPanel(title: "Current releases") {
                        if s.currentReleases.isEmpty {
                            EmptyPanelText("No released versions recorded.")
                        } else {
                            ForEach(s.currentReleases.prefix(8)) { ref in
                                releaseRow(ref)
                            }
                        }
                    }
                }

                AdaptiveStack {
                    DashboardPanel(title: "Critical issues") {
                        if s.openCriticalIssues.isEmpty {
                            EmptyPanelText("No open critical issues recorded.")
                        } else {
                            ForEach(s.openCriticalIssues) { ref in
                                Button { router.open(productID: ref.productID) } label: {
                                    HStack {
                                        Text(ref.productName).bold()
                                        Text(ref.issue.title)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    DashboardPanel(title: "Deployments") {
                        if s.deploymentsByStatus.isEmpty {
                            EmptyPanelText("No deployments recorded.")
                        } else {
                            ForEach(DeploymentStatus.allCases.filter { s.deploymentsByStatus[$0] != nil }) { status in
                                HStack {
                                    StatusBadge(text: status.title, color: status.color)
                                    Spacer()
                                    Text("\(s.deploymentsByStatus[status] ?? 0)").monospacedDigit()
                                }
                            }
                        }
                    }
                }

                AdaptiveStack {
                    DashboardPanel(title: "Store status") {
                        LabeledContent("Products on the App Store") { Text(s.productsWithAppStoreListing, format: .number) }
                        LabeledContent("Products on Google Play") { Text(s.productsWithGooglePlayListing, format: .number) }
                        Text("From public store pages and the owner's App Store Connect screenshot (2026-09-23), or live from the consoles once their read-only keys are added in Settings → Integrations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DashboardPanel(title: "GitHub") {
                        let repos = model.products.flatMap(\.repositories).compactMap(\.gitHub)
                        LabeledContent("Products with repositories") { Text(s.productsWithRepositories, format: .number) }
                        LabeledContent("Failing CI") { Text(repos.count { $0.ciConclusion == .failure }, format: .number) }
                        LabeledContent("Open pull requests") { Text(repos.compactMap(\.openPullRequests).reduce(0, +), format: .number) }
                        Text("Last snapshot: \(repos.map(\.fetchedAt).max()?.formatted(date: .abbreviated, time: .shortened) ?? "never"). Refresh from Development → Repositories (read-only).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DashboardPanel(title: "Store changes") {
                        if model.recentStoreChanges.isEmpty {
                            EmptyPanelText("No store changes yet. They appear here after each automatic refresh of App Store Connect and Google Play.")
                        } else {
                            ForEach(model.recentStoreChanges.prefix(6)) { change in
                                Button { router.open(productID: change.productID) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: change.isImportant ? "bell.badge.fill" : "bell")
                                            .foregroundStyle(change.isImportant ? .orange : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(verbatim: change.message).font(.callout)
                                            Text(change.detectedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
    }

    /// Platforms hub summary: how many platforms have CI failing, a release behind main, or a store version behind main.
    private var platformsCard: some View {
        let p = platforms.summary
        return Button { router.sidebar = .platforms } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: SidebarItem.platforms.symbol).foregroundStyle(.secondary)
                    Text("Platforms").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if p.lastRead == nil {
                    Text("\(p.products) platforms, not read from GitHub yet. Open Platforms to refresh →")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    FitRow(spacing: 8) {
                        DriftCountChip(kind: .ciFailing, count: p.withCIFailing)
                        DriftCountChip(kind: .releaseBehindMain, count: p.withReleaseDrift)
                        DriftCountChip(kind: .storeBehindMain, count: p.withStoreDrift)
                    }
                    Text("Across \(p.products) platforms · GitHub read \(p.lastRead!.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Live project-oversight summary: the 0→100 fleet health and the counts that need a person.
    private var oversightCard: some View {
        let o = model.oversightSummary
        return Button { router.sidebar = .oversight } label: {
            HStack(spacing: 16) {
                HealthScoreRing(score: o.healthScore)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "scope").foregroundStyle(.secondary)
                        Text("Project oversight").font(.headline)
                    }
                    if o.totalRepos == 0 {
                        Text("No repositories scanned yet. Open Oversight to run a read-only sweep →")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(o.healthyRepos) of \(o.totalRepos) repositories healthy")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            HealthChip(health: .critical, count: o.criticalRepos)
                            HealthChip(health: .attention, count: o.attentionRepos)
                            HealthChip(health: .unknown, count: o.neverScanned)
                            if o.openSecurityAlerts > 0 {
                                StatusBadge(text: "\(o.openSecurityAlerts) security alerts", color: .red)
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Licence centre summary: active licences per product and the ones ending within 30 days.
    private var licencesCard: some View {
        let s = licences.summary
        return Button { router.sidebar = .licences } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "key.horizontal").foregroundStyle(.secondary)
                    Text("Licences").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if s.total == 0 {
                    Text("No licences in the ledger yet. Open Licences to issue one or import issued.csv →")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        ForEach(LicenceProduct.allCases) { p in
                            Text("\(p.displayName): \(s.activeByProduct[p, default: 0]) active").font(.callout).monospacedDigit()
                        }
                        if !s.expired.isEmpty {
                            StatusBadge(text: String(localized: "\(s.expired.count) expired"), color: .red)
                        }
                    }
                    if s.expiringSoon.isEmpty {
                        Text("None ends in the next 30 days.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(s.expiringSoon.prefix(5)) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                                Text(verbatim: "\(r.customer) · \(r.product.displayName)")
                                Spacer(minLength: 4)
                                LicenceExpiryText(record: r).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// WorkTrack customers whose licence ends within 30 days (TEST / DUPLICATE left out), with where and when it was read.
    private var worktrackCard: some View {
        let s = worktrack.summary
        return Button { router.sidebar = .worktrackCustomers } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: SidebarItem.worktrackCustomers.symbol).foregroundStyle(.secondary)
                    Text("WorkTrack customers").font(.headline)
                    if let env = worktrack.environment { WorkTrackEnvironmentBadge(environment: env) }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if !worktrack.isSignedIn {
                    Text("Not signed in. Open WorkTrack customers to sign in with your vendor account →")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let error = worktrack.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                } else if worktrack.lastRead == nil {
                    Text(worktrack.isRefreshing ? "Reading from WorkTrack…" : "Not read yet.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 16) {
                        Text("\(s.total) companies").font(.callout).monospacedDigit()
                        if !s.expired.isEmpty {
                            StatusBadge(text: String(localized: "\(s.expired.count) expired"), color: .red)
                        }
                    }
                    if s.expiringSoon.isEmpty {
                        Text("No customer licence ends in the next 30 days.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(s.expiringSoon.prefix(5)) { c in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                                Text(verbatim: "\(c.name) · \(c.license.plan.rawValue)")
                                Spacer(minLength: 4)
                                WorkTrackExpiryText(company: c).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    if let at = worktrack.lastRead {
                        Text("Read \(at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// "Waiting for you": the Talar, SafeBeauty and VELRO queues that block someone from starting, each with its
    /// environment and the time it was read. A product that isn't signed in says so instead of showing a number.
    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: SidebarItem.operations.symbol).foregroundStyle(.secondary)
                Text("Waiting for you").font(.headline)
                Spacer()
            }
            ForEach(operations.waiting, id: \.queue) { line in
                Button {
                    router.operationsTab = line.queue.product
                    router.sidebar = .operations
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: line.queue.product.symbol).foregroundStyle(.secondary).frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: line.queue.title)
                            Text(verbatim: line.queue.product.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        if let c = line.count {
                            if !c.isProduction { OpsEnvironmentBadge(rawEnvironment: c.environment) }
                            Text(verbatim: "\(c.count)").font(.title3.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(c.count > 0 ? .orange : .secondary)
                        } else if operations.isSignedIn(line.queue.product) {
                            Text("Not read yet").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Not signed in").font(.callout).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.count.map { Text(verbatim: line.queue.sentence($0.count)) } ?? Text("\(line.queue.product.title): \(line.queue.title), not read"))
            }
            siteMessagesRow
            if let newest = operations.waiting.compactMap(\.count?.readAt).max() {
                Text("Read \(newest.formatted(date: .abbreviated, time: .shortened)), from each product's own admin API").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Website messages not marked seen: a waiting item, because the form's emails don't reach the owner.
    private var siteMessagesRow: some View {
        Button { router.go(.siteMessages) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: SidebarItem.siteMessages.symbol).foregroundStyle(.secondary).frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New website messages")
                    Text(verbatim: "linumic.com").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let n = siteMessages.newCount {
                    Text(verbatim: "\(n)").font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(n > 0 ? .orange : .secondary)
                } else if siteMessages.isConfigured {
                    Text("Not read yet").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Not connected").font(.callout).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func releaseRow(_ ref: DashboardSummary.ReleaseRef) -> some View {
        Button { router.open(productID: ref.productID) } label: {
            HStack {
                Text(ref.productName).bold()
                Text(ref.release.version).monospacedDigit()
                Text(ref.release.platform.title).foregroundStyle(.secondary)
                Spacer()
                if let date = ref.release.releaseDate { Text(date.shortDate).foregroundStyle(.secondary) }
                StatusBadge(text: ref.release.stage.title, color: ref.release.stage.color)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Side by side on Mac and iPad; stacked on an iPhone, where side-by-side panels would overflow.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
        #else
        HStack(alignment: .top, spacing: spacing) { content }
        #endif
    }
}

struct MetricTile: View {
    let title: String
    let value: Int
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct DashboardPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyPanelText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(LocalizedStringKey(text)).foregroundStyle(.secondary) }
}
