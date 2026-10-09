import LinumicCore
import SwiftUI

/// Platforms hub: one card per Linumic platform with its versions, releases, CI, store status and links.
/// Every value shows where it came from and when; anything unread is Unknown.
struct PlatformsView: View {
    @Environment(PlatformHubModel.self) private var hub
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: String.self) { id in
                    PlatformDetailView(productID: id)
                }
        }
    }

    private var list: some View {
        let rows = hub.rows
        let summary = hub.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(summary)
                if rows.isEmpty {
                    ContentUnavailableView("No platforms", systemImage: SidebarItem.platforms.symbol,
                                           description: Text("None of the catalogued products is in the inventory."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(rows) { row in
                        Button { path.append(row.id) } label: { PlatformCard(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the platform details")
                    }
                }
                Text("Read-only. Versions on main are read from each repository's version file through the GitHub contents API; releases, CI runs and pull requests from the GitHub API; store versions from the store listings already in the inventory. A drift is shown only when two real version numbers can be compared.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Platforms")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await hub.refresh() }
                } label: {
                    if hub.isRefreshing { ProgressView().controlSize(.small) }
                    else { Label("Refresh from GitHub", systemImage: "arrow.clockwise") }
                }
                .disabled(hub.isRefreshing)
                .keyboardShortcut("r")
                .help("Read versions, releases, CI and pull requests from GitHub (read-only)")
            }
        }
        .alert("Error", isPresented: Binding(get: { hub.errorMessage != nil }, set: { if !$0 { hub.errorMessage = nil } })) {
            Button("OK") { hub.errorMessage = nil }
        } message: {
            Text(verbatim: hub.errorMessage ?? "")
        }
    }

    private func header(_ s: PlatformHubSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitRow(spacing: 8) {
                DriftCountChip(kind: .ciFailing, count: s.withCIFailing)
                DriftCountChip(kind: .releaseBehindMain, count: s.withReleaseDrift)
                DriftCountChip(kind: .storeBehindMain, count: s.withStoreDrift)
                if s.notRead > 0 {
                    StatusBadge(text: String(localized: "\(s.notRead) not read yet"), color: .gray)
                }
            }
            Group {
                if let last = hub.lastRefresh {
                    Text("Last read from GitHub: \(last.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Not read from GitHub yet. Use Refresh from GitHub (a token is needed for private repositories).")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let report = hub.lastReport, !report.failed.isEmpty {
                ForEach(report.failed.sorted(by: { $0.key < $1.key }), id: \.key) { slug, message in
                    Label { Text(verbatim: "\(slug): \(message)") } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        .font(.caption)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Card

struct PlatformCard: View {
    let row: PlatformRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: row.profile.title).font(.headline)
                Spacer(minLength: 4)
                BusinessModelBadge(model: row.profile.businessModel)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            if !row.flags.isEmpty {
                FitRow(spacing: 6) {
                    ForEach(DriftFlag.Kind.allCases, id: \.self) { kind in
                        let n = row.flags.filter { $0.kind == kind }.count
                        if n > 0 { DriftCountChip(kind: kind, count: n, showsTitle: true) }
                    }
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Main").foregroundStyle(.secondary)
                    mainVersions
                }
                GridRow {
                    Text("Release").foregroundStyle(.secondary)
                    releaseText
                }
                GridRow {
                    Text("Stores").foregroundStyle(.secondary)
                    storeText
                }
                GridRow {
                    Text("CI").foregroundStyle(.secondary)
                    ciText
                }
                GridRow {
                    Text("Open PRs").foregroundStyle(.secondary)
                    if let n = row.openPullRequests { Text(n, format: .number).monospacedDigit() } else { UnknownLabel() }
                }
            }
            .font(.callout)
            if let last = row.lastRead {
                Text("GitHub read \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var mainVersions: some View {
        let known = row.versions.compactMap { v in v.reading?.label.map { (v.spec.component, $0) } }
        if row.profile.versionFiles.isEmpty {
            Text("No version file").foregroundStyle(.secondary)
        } else if known.isEmpty {
            UnknownLabel()
        } else {
            Text(verbatim: compact(known)).monospacedDigit().lineLimit(2)
        }
    }

    /// "Android 1.3.0 (6) · iOS 1.3.0 (4)", folding equal versions together.
    private func compact(_ items: [(String, String)]) -> String {
        if Set(items.map(\.1)).count == 1 { return items[0].1 }
        return items.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    @ViewBuilder private var releaseText: some View {
        if let latest = row.latestRelease {
            Text(verbatim: "\(latest.release.tag) · \(latest.release.publishedAt?.shortDate ?? "?") · \(String(localized: "\(latest.release.totalDownloads) downloads"))")
                .monospacedDigit()
        } else if row.hasNoRelease {
            Text("No GitHub release").foregroundStyle(.secondary)
        } else {
            UnknownLabel()
        }
    }

    @ViewBuilder private var storeText: some View {
        let live = row.storeListings.compactMap { l in l.productionVersion.map { "\(l.store.title) \($0)" } }
        if row.storeListings.isEmpty {
            Text("Not in a store").foregroundStyle(.secondary)
        } else if live.isEmpty {
            UnknownLabel()
        } else {
            Text(verbatim: Array(Set(live)).sorted().joined(separator: " · ")).monospacedDigit().lineLimit(2)
        }
    }

    @ViewBuilder private var ciText: some View {
        let runs = row.workflows.compactMap(\.workflow.latestRun)
        if row.repos.allSatisfy({ $0.workflows == nil }) {
            UnknownLabel()
        } else if row.workflows.isEmpty {
            Text("No workflows").foregroundStyle(.secondary)
        } else {
            let failing = runs.filter { $0.outcome == .failure }.count
            let passing = runs.filter { $0.outcome == .success }.count
            HStack(spacing: 4) {
                Image(systemName: failing > 0 ? RepositorySnapshot.CIConclusion.failure.symbol : RepositorySnapshot.CIConclusion.success.symbol)
                    .foregroundStyle(failing > 0 ? .red : .green)
                    .accessibilityHidden(true)
                Text("\(passing) passing, \(failing) failing, \(row.workflows.count - runs.count) not run on main")
            }
        }
    }
}

// MARK: - Badges

struct BusinessModelBadge: View {
    let model: BusinessModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(model.title).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Business model: \(model.title)"))
    }

    private var symbol: String {
        switch model {
        case .selfServe: "person.crop.circle.badge.plus"
        case .licence: "key.horizontal"
        case .consumer: "iphone"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch model {
        case .selfServe: .teal
        case .licence: .indigo
        case .consumer: .blue
        case .unknown: .gray
        }
    }
}

extension DriftFlag.Kind {
    var symbol: String {
        switch self {
        case .releaseBehindMain: "tag"
        case .storeBehindMain: "bag"
        case .ciFailing: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .releaseBehindMain: .orange
        case .storeBehindMain: .yellow
        case .ciFailing: .red
        }
    }

    var shortTitle: String {
        switch self {
        case .releaseBehindMain: L("Release drift")
        case .storeBehindMain: L("Store drift")
        case .ciFailing: L("CI failing")
        }
    }
}

/// "2 CI failing": icon + number + words, never color alone. Hidden when the count is zero, unless asked.
struct DriftCountChip: View {
    let kind: DriftFlag.Kind
    let count: Int
    var showsTitle = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: count > 0 ? kind.symbol : "checkmark.circle").foregroundStyle(count > 0 ? kind.color : .green)
            Text(verbatim: "\(count.formatted()) \(kind.shortTitle)")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background((count > 0 ? kind.color : .green).opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(kind.title): \(count)"))
    }
}

/// A small "source · date" line under a value.
struct SourceLine: View {
    let reference: String
    let date: Date?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text.magnifyingglass").accessibilityHidden(true)
            Text(verbatim: reference).textSelection(.enabled)
            if let date { Text(verbatim: "· \(date.shortDate)") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Source: \(reference)"))
    }
}
