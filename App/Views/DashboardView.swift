import LinumicCore
import SwiftUI

struct DashboardView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var statusColumns: Int { sizeClass == .compact ? 2 : 4 }
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
                    DashboardPanel(title: "Recent activity") {
                        EmptyPanelText("An activity feed will come with the backend audit log.")
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
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
