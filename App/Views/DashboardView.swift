import LinumicCore
import SwiftUI

struct DashboardView: View {
    @Environment(InventoryModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let s = model.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if s.pendingConfirmations > 0 {
                    Button { router.sidebar = .verification } label: {
                        HStack {
                            Image(systemName: s.conflictingItems > 0 ? "exclamationmark.triangle.fill" : "person.badge.clock")
                                .foregroundStyle(s.conflictingItems > 0 ? .red : .orange)
                            Text("\(s.pendingConfirmations) facts need your confirmation\(s.conflictingItems > 0 ? ", \(s.conflictingItems) of them conflicting" : ""). Open Verification →")
                            Spacer()
                        }
                        .padding(10)
                        .background((s.conflictingItems > 0 ? Color.red : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 12) {
                    ForEach([VerificationStatus.verified, .partiallyVerified, .unknown, .conflicting]) { status in
                        HStack {
                            VerificationBadge(status: status)
                            Spacer()
                            Text("\(s.countsByVerification[status, default: 0])").font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        .padding(10)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
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

                HStack(alignment: .top, spacing: 16) {
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

                HStack(alignment: .top, spacing: 16) {
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

                HStack(alignment: .top, spacing: 16) {
                    DashboardPanel(title: "Store status") {
                        LabeledContent("Products on the App Store", value: "\(s.productsWithAppStoreListing)")
                        LabeledContent("Products on Google Play", value: "\(s.productsWithGooglePlayListing)")
                        Text("From public store pages and the owner's App Store Connect screenshot (2026-09-23). Live sync needs the store integrations, which aren't connected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DashboardPanel(title: "GitHub") {
                        LabeledContent("Products with repositories", value: "\(s.productsWithRepositories)")
                        Text("Live repository status (commits, PRs, CI) requires the GitHub integration (not connected).")
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

struct MetricTile: View {
    let title: String
    let value: Int
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(value)")
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
            Text(title).font(.headline)
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
    var body: some View { Text(text).foregroundStyle(.secondary) }
}
