import LinumicCore
import SwiftUI

/// Project oversight: every repository "from 0 to 100", watched read-only for latest changes and
/// security. Data comes from GitHub via `OversightSync`. Unread facts show as Unknown, never guessed.
struct OversightView: View {
    @Environment(InventoryModel.self) private var model

    var body: some View {
        let summary = model.oversightSummary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.oversight.isEmpty {
                    emptyState
                } else {
                    header(summary)
                    workspaceBar(summary)
                    metrics(summary)
                    repoList
                }
                footnote(summary)
            }
            .padding(20)
        }
        .navigationTitle("Oversight")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshOversight() }
                } label: {
                    if model.isSyncingOversight {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Scan all repositories", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isSyncingOversight)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nothing scanned yet", systemImage: "scope").font(.title2.weight(.semibold))
            Text("Run a read-only sweep to put every repository you own under oversight: latest changes, open pull requests, CI status and security alerts. This only reads from GitHub.")
                .foregroundStyle(.secondary)
            Button {
                Task { await model.refreshOversight() }
            } label: {
                Label(model.isSyncingOversight ? "Scanning…" : "Scan all repositories", systemImage: "arrow.clockwise")
            }
            .disabled(model.isSyncingOversight)
            if let err = model.lastOversightSync?.report.listError {
                Text(verbatim: err).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Header (0 → 100 health score)

    private func header(_ s: OversightSummary) -> some View {
        HStack(alignment: .center, spacing: 20) {
            HealthScoreRing(score: s.healthScore)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fleet health").font(.headline)
                Text("\(s.healthyRepos) of \(s.totalRepos) repositories healthy")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    HealthChip(health: .critical, count: s.criticalRepos)
                    HealthChip(health: .attention, count: s.attentionRepos)
                    HealthChip(health: .unknown, count: s.neverScanned)
                }
                if let last = s.lastScan {
                    Text("Last scan: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Local workspace (macOS)

    @ViewBuilder private func workspaceBar(_ s: OversightSummary) -> some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let path = model.workspacePath {
                    Text("Local workspace: \(path)").font(.callout)
                    Text("\(s.reposScannedLocally) checkouts scanned · \(s.reposWithUncommittedChanges) with uncommitted changes · \(s.reposDivergedFromOrigin) diverged")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No local folder chosen. Pick the folder that holds your repositories to track uncommitted and unpushed work (read-only).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.hasWorkspace {
                Button {
                    Task { await model.refreshLocal() }
                } label: {
                    if model.isScanningLocal { ProgressView().controlSize(.small) }
                    else { Label("Scan local", systemImage: "arrow.clockwise.circle") }
                }
                .disabled(model.isScanningLocal)
            }
            Button {
                Task { await model.chooseWorkspace() }
            } label: {
                Label(model.hasWorkspace ? "Change folder" : "Choose folder", systemImage: "folder")
            }
            .disabled(model.isScanningLocal)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        #else
        EmptyView()
        #endif
    }

    // MARK: Metric tiles

    private func metrics(_ s: OversightSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            MetricTile(title: "Repositories", value: s.totalRepos, symbol: "folder")
            MetricTile(title: "Open security alerts", value: s.openSecurityAlerts, symbol: "exclamationmark.shield",
                       tint: s.openSecurityAlerts > 0 ? .red : .green)
            MetricTile(title: "Repos with alerts", value: s.reposWithOpenAlerts, symbol: "shield.lefthalf.filled",
                       tint: s.reposWithOpenAlerts > 0 ? .red : .secondary)
            MetricTile(title: "Failing CI", value: s.reposWithFailingCI, symbol: "xmark.octagon",
                       tint: s.reposWithFailingCI > 0 ? .red : .secondary)
            MetricTile(title: "Unprotected branches", value: s.unprotectedDefaultBranches, symbol: "lock.open",
                       tint: s.unprotectedDefaultBranches > 0 ? .orange : .secondary)
            MetricTile(title: "Stale (30d+)", value: s.staleRepos, symbol: "clock.badge.exclamationmark",
                       tint: s.staleRepos > 0 ? .orange : .secondary)
            MetricTile(title: "Open pull requests", value: s.totalOpenPullRequests, symbol: "arrow.triangle.pull", tint: .indigo)
            MetricTile(title: "Open issues", value: s.totalOpenIssues, symbol: "exclamationmark.triangle", tint: .indigo)
            MetricTile(title: "Uncommitted (local)", value: s.reposWithUncommittedChanges, symbol: "pencil.and.list.clipboard",
                       tint: s.reposWithUncommittedChanges > 0 ? .orange : .secondary)
            MetricTile(title: "Diverged from origin", value: s.reposDivergedFromOrigin, symbol: "arrow.triangle.branch",
                       tint: s.reposDivergedFromOrigin > 0 ? .orange : .secondary)
        }
    }

    // MARK: Per-repository list

    private var repoList: some View {
        let repos = model.oversight.sorted {
            let lh = $0.health(), rh = $1.health()
            if lh != rh { return lh < rh }                       // most urgent first
            return ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast)
        }
        return DashboardPanel(title: "Repositories") {
            ForEach(repos) { repo in
                OversightRepoRow(repo: repo)
                if repo.id != repos.last?.id { Divider() }
            }
        }
    }

    private func footnote(_ s: OversightSummary) -> some View {
        Text("Read-only. A repository is counted healthy only when it was scanned and nothing was flagged; anything unread shows as \u{201C}Not scanned\u{201D} and is never assumed clean. Security alerts need a GitHub token with the right scope; where a category can't be read it stays Unknown.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Health score ring

struct HealthScoreRing: View {
    let score: Int?

    private var color: Color {
        guard let score else { return .gray }
        switch score {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text("/ 100").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "Fleet health \($0) out of 100" } ?? "Fleet health unknown")
    }
}

// MARK: - Health chip

struct HealthChip: View {
    let health: OversightHealth
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(health.color).frame(width: 7, height: 7)
                Text("\(count) \(health.title)").font(.caption)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(health.color.opacity(0.12), in: Capsule())
        }
    }
}

// MARK: - Repository row

struct OversightRepoRow: View {
    let repo: OversightRepo

    var body: some View {
        let health = repo.health()
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(health.color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.body.weight(.semibold))
                    if repo.isPrivate {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if repo.isArchived {
                        StatusBadge(text: "Archived", color: .secondary)
                    }
                    if let branch = repo.snapshot?.defaultBranch {
                        Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let pushed = repo.pushedAt {
                        Label(pushed.formatted(.relative(presentation: .named)), systemImage: "arrow.up.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let ci = repo.snapshot?.ciConclusion, ci != .none {
                        Label(ciText(ci), systemImage: "bolt.horizontal.circle")
                            .font(.caption).foregroundStyle(ci.color)
                    }
                    if let prs = repo.snapshot?.openPullRequests, prs > 0 {
                        Label("\(prs) PRs", systemImage: "arrow.triangle.pull").font(.caption).foregroundStyle(.secondary)
                    }
                    if let issues = repo.snapshot?.openIssues, issues > 0 {
                        Label("\(issues) issues", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                securityLine
                localLine
                if let err = repo.scanError {
                    Text(verbatim: err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let url = URL(string: "https://github.com/\(repo.slug)") {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var localLine: some View {
        if let local = repo.local {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").font(.caption2).foregroundStyle(.secondary)
                if let branch = local.branch {
                    Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else if local.isDetached {
                    Text("detached").font(.caption).foregroundStyle(.secondary)
                }
                switch local.syncState {
                case .diverged: StatusBadge(text: "Diverged from origin", color: .orange)
                case .inSync: StatusBadge(text: "In sync with origin", color: .green)
                case .noRemoteRef: StatusBadge(text: "No remote branch", color: .secondary)
                case .unknown: EmptyView()
                }
                if let modified = local.modifiedTrackedFiles {
                    if modified > 0 {
                        StatusBadge(text: "\(modified) uncommitted", color: .orange)
                    } else {
                        StatusBadge(text: "Clean", color: .green)
                    }
                } else {
                    StatusBadge(text: "Changes unknown", color: .secondary)
                }
            }
        }
    }

    @ViewBuilder private var securityLine: some View {
        if let sec = repo.snapshot?.security {
            HStack(spacing: 6) {
                alertChip(L("Dependabot"), sec.dependabotAlerts)
                alertChip(L("Secrets"), sec.secretScanningAlerts)
                alertChip(L("Code scan"), sec.codeScanningAlerts)
                if sec.defaultBranchProtected == false {
                    StatusBadge(text: "Branch unprotected", color: .orange)
                }
            }
        }
    }

    /// `nil` count renders nothing (Unknown); 0 renders a green "clear"; >0 renders a red alert count.
    @ViewBuilder private func alertChip(_ label: String, _ count: Int?) -> some View {
        if let count {
            StatusBadge(text: "\(label) \(count)", color: count > 0 ? .red : .green)
        }
    }

    private func ciText(_ ci: RepositorySnapshot.CIConclusion) -> String {
        switch ci {
        case .success: L("CI passing")
        case .failure: L("CI failing")
        case .cancelled: L("CI cancelled")
        case .inProgress: L("CI running")
        case .none: ""
        }
    }
}

extension OversightHealth {
    var color: Color {
        switch self {
        case .critical: .red
        case .attention: .orange
        case .healthy: .green
        case .unknown: .gray
        }
    }
}
