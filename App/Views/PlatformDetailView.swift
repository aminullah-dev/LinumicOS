import LinumicCore
import SwiftUI

/// Everything known about one platform: drift, versions on main, store versions, releases, CI,
/// repositories, licences and links. Each value carries its source and date.
struct PlatformDetailView: View {
    let productID: String
    @Environment(PlatformHubModel.self) private var hub
    @Environment(LicenceModel.self) private var licences
    @Environment(Router.self) private var router

    var body: some View {
        if let row = hub.row(productID: productID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(row)
                    driftPanel(row)
                    versionsPanel(row)
                    storePanel(row)
                    releasesPanel(row)
                    ciPanel(row)
                    reposPanel(row)
                    if let product = row.profile.licenceProduct { licencePanel(product) }
                    linksPanel(row)
                }
                .padding(20)
            }
            .navigationTitle(Text(verbatim: row.profile.title))
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark.circle")
        }
    }

    // MARK: Header

    private func header(_ row: PlatformRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitRow(spacing: 8) {
                BusinessModelBadge(model: row.profile.businessModel)
                if let status = row.product?.status.value {
                    StatusBadge(text: status.title, color: status.color)
                }
            }
            SourceLine(reference: row.profile.businessModelSource.reference, date: row.profile.businessModelSource.checkedAt)
            if let note = row.profile.trackingNote {
                Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle") }
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                router.open(productID: row.id)
            } label: {
                Label("Open product record", systemImage: "shippingbox")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Drift

    private func driftPanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "Drift") {
            if row.repos.isEmpty {
                EmptyPanelText("Not read from GitHub yet, so nothing can be compared.")
            } else if row.flags.isEmpty {
                Label("Nothing to flag: no failing CI on main, and no release or store version behind main where both versions are known.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(row.flags) { flag in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: flag.kind.symbol).foregroundStyle(flag.kind.color).accessibilityHidden(true)
                            Text(flag.kind.title).font(.callout.weight(.semibold))
                            if let url = flag.url {
                                Spacer(minLength: 4)
                                Link(destination: url) { Label("Open", systemImage: "arrow.up.right.square") }.font(.caption)
                            }
                        }
                        Text(verbatim: flag.detail).font(.callout).monospacedDigit()
                        ForEach(flag.evidence, id: \.self) { line in
                            Text(verbatim: line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if flag.id != row.flags.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: Versions on main

    private func versionsPanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "Version on main") {
            if row.profile.versionFiles.isEmpty {
                EmptyPanelText("No version file is recorded for this product.")
            }
            ForEach(row.versions, id: \.spec.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: item.spec.component).font(.callout.weight(.semibold))
                        Spacer(minLength: 4)
                        ValueOrUnknown(value: item.reading?.label).monospacedDigit()
                    }
                    if let reading = item.reading {
                        SourceLine(reference: reading.sourceReference, date: reading.fetchedAt)
                        if let error = reading.error {
                            Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        SourceLine(reference: "\(item.spec.repo) \(item.spec.path)", date: nil)
                    }
                    Text(verbatim: String(localized: "Location from \(item.spec.source.reference)"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if item.spec.id != row.versions.last?.spec.id { Divider() }
            }
        }
    }

    // MARK: Stores

    private func storePanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "Store versions") {
            if row.storeListings.isEmpty {
                EmptyPanelText("No store listing is recorded for this product.")
            }
            ForEach(row.storeListings) { listing in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "\(listing.store.title) · \(listing.appName ?? listing.appIdentifier ?? "?")").font(.callout.weight(.semibold))
                        Spacer(minLength: 4)
                        EvidenceButton(verification: listing.verification)
                    }
                    HStack(spacing: 6) {
                        Text("Live").foregroundStyle(.secondary)
                        ValueOrUnknown(value: listing.productionVersion).monospacedDigit()
                    }
                    .font(.callout)
                    if let submitted = listing.latestSubmittedVersion {
                        HStack(spacing: 6) {
                            Text("Submitted").foregroundStyle(.secondary)
                            Text(verbatim: submitted).monospacedDigit()
                            ReviewPhaseBadge(phase: listing.reviewPhase)
                        }
                        .font(.callout)
                    }
                    if let source = listing.verification.sources.max(by: { $0.observedAt < $1.observedAt }) {
                        SourceLine(reference: source.reference, date: listing.verification.verifiedAt ?? source.observedAt)
                    }
                }
                if listing.id != row.storeListings.last?.id { Divider() }
            }
        }
    }

    // MARK: Releases

    private func releasesPanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "GitHub releases") {
            let withReleases = row.repos.filter { !$0.recentReleases.isEmpty || $0.release != nil }
            if row.repos.isEmpty {
                UnknownLabel()
            } else if withReleases.isEmpty {
                EmptyPanelText("No published release on GitHub.")
            }
            ForEach(withReleases) { repo in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: repo.slug).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let latest = repo.release {
                        ReleaseRow(release: latest, isLatest: true)
                    }
                    ForEach(repo.recentReleases.filter { $0.tag != repo.release?.tag }.prefix(9)) { release in
                        ReleaseRow(release: release, isLatest: false)
                    }
                    SourceLine(reference: "GitHub /releases/latest, /releases", date: repo.fetchedAt)
                }
            }
        }
    }

    // MARK: CI

    private func ciPanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "CI on main (latest run per workflow)") {
            if row.repos.isEmpty || row.repos.allSatisfy({ $0.workflows == nil }) {
                UnknownLabel()
            } else if row.workflows.isEmpty {
                EmptyPanelText("No workflows in .github/workflows.")
            }
            ForEach(row.workflows, id: \.workflow.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let outcome = item.workflow.latestRun?.outcome ?? .none
                    Image(systemName: outcome.symbol).foregroundStyle(outcome.color).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: item.workflow.name).font(.callout)
                        Text(verbatim: "\(item.repo) · \(item.workflow.path)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let run = item.workflow.latestRun {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(outcome.title).font(.callout)
                            if let at = run.createdAt { Text(verbatim: at.shortDate).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let url = run.url {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                .help("Open the run on GitHub")
                                .accessibilityLabel(Text("Open the run on GitHub"))
                        }
                    } else {
                        Text("No run on main").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Repositories

    private func reposPanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "Repositories") {
            ForEach(row.repos) { repo in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Link(repo.slug, destination: URL(string: "https://github.com/\(repo.slug)")!).font(.callout)
                        Spacer(minLength: 4)
                        if let n = repo.openPullRequests {
                            Text("\(n) open PRs").font(.callout).monospacedDigit()
                        } else {
                            UnknownLabel()
                        }
                    }
                    Text("Default branch \(repo.defaultBranch ?? "?") · read \(repo.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = repo.error {
                        Text("Last refresh failed: \(error). Showing the previous read.").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(repo.problems, id: \.self) { problem in
                        Text(verbatim: problem).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            ForEach(row.unreadRepos, id: \.self) { slug in
                HStack {
                    Text(verbatim: slug).font(.callout)
                    Spacer()
                    Text("Not read yet").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    // MARK: Licences

    private func licencePanel(_ product: LicenceProduct) -> some View {
        let s = licences.summary
        let expiring = s.expiringSoon.filter { $0.product == product }.count
        let expired = s.expired.filter { $0.product == product }.count
        return Button { router.sidebar = .licences } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal").foregroundStyle(.indigo).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Licences").font(.headline)
                    Text("\(s.activeByProduct[product, default: 0]) active · \(expiring) ending within 30 days · \(expired) expired")
                        .font(.callout).monospacedDigit()
                    Text("From the licence ledger on this device").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Licences screen")
    }

    // MARK: Links

    private func linksPanel(_ row: PlatformRow) -> some View {
        DashboardPanel(title: "Links") {
            if row.profile.links.isEmpty {
                EmptyPanelText("No admin or public page is recorded for this product.")
            }
            let groups: [(String, [PlatformLink])] = [
                (L("Admin"), row.profile.links.filter(\.kind.isAdmin)),
                (L("Public"), row.profile.links.filter { !$0.kind.isAdmin }),
            ]
            ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { title, links in
                Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(links) { link in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Link(destination: link.url) {
                                Label { Text(verbatim: link.title) } icon: { Image(systemName: "arrow.up.right.square") }
                            }
                            Text(link.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        SourceLine(reference: link.source.reference, date: link.source.checkedAt)
                    }
                }
            }
        }
    }
}

struct ReleaseRow: View {
    let release: GitHubRelease
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let url = release.url {
                    Link(release.tag, destination: url).font(.callout.weight(isLatest ? .semibold : .regular))
                } else {
                    Text(verbatim: release.tag).font(.callout.weight(isLatest ? .semibold : .regular))
                }
                if isLatest { StatusBadge(text: "Latest", color: .green) }
                if release.isPrerelease { StatusBadge(text: "Pre-release", color: .orange) }
                Spacer(minLength: 4)
                Text(verbatim: release.publishedAt?.shortDate ?? "?").font(.caption).foregroundStyle(.secondary)
            }
            if !release.assets.isEmpty {
                ForEach(release.assets, id: \.name) { asset in
                    HStack {
                        Text(verbatim: asset.name).font(.caption.monospaced())
                        Spacer()
                        Text("\(asset.downloadCount) downloads").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
