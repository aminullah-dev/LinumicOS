import LinumicCore
import SwiftUI

// MARK: - Shared visuals

extension AppStoreVersionPhase {
    var color: Color {
        switch self {
        case .live: .green
        case .pendingDeveloperRelease: .orange
        case .rejected: .red
        case .waitingForReview, .inReview, .pendingAppleRelease, .processing: .blue
        case .preparing, .developerRejected: .yellow
        case .historical, .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .live: "checkmark.circle.fill"
        case .pendingDeveloperRelease: "hand.raised.fill"
        case .rejected: "xmark.octagon.fill"
        case .waitingForReview: "clock.fill"
        case .inReview: "magnifyingglass.circle.fill"
        case .pendingAppleRelease, .processing: "arrow.triangle.2.circlepath"
        case .preparing: "pencil.circle.fill"
        case .developerRejected: "arrow.uturn.backward.circle"
        case .historical: "clock.arrow.circlepath"
        case .unknown: "questionmark.circle"
        }
    }
}

extension PlayTrackStatus {
    var color: Color {
        switch self {
        case .completed: .green
        case .inProgress: .blue
        case .halted: .red
        case .draft: .yellow
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "chart.bar.fill"
        case .halted: "pause.octagon.fill"
        case .draft: "pencil.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

extension CIRollup {
    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .pending: .blue
        case .none: .gray
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .pending: "clock"
        case .none: "minus.circle"
        }
    }
}

extension WaitingItem.Severity {
    var color: Color {
        switch self {
        case .high: .red
        case .normal: .orange
        case .info: .blue
        }
    }

    var symbol: String {
        switch self {
        case .high: "exclamationmark.triangle.fill"
        case .normal: "hand.raised.fill"
        case .info: "info.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .high: L("Urgent")
        case .normal: L("Needs you")
        case .info: L("For information")
        }
    }
}

/// Icon + text on a tinted capsule, the same shape as the other status badges, so colour never carries meaning alone.
struct ReleaseBadge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// "Source: … · read 14:02" in the small caption style used everywhere a fact is shown.
struct ReleaseSourceLine: View {
    let source: String
    let at: Date

    var body: some View {
        Text("Source: \(source), read \(at.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
    }
}

/// A card with a status stripe on the leading edge (mirrors in Dari), like the Monitor cards.
struct StripeCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(tint).frame(width: 4)
                    .accessibilityHidden(true)
            }
    }
}

private func shortTime(_ date: Date?) -> String {
    date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–"
}

// MARK: - Release Center screen

struct ReleaseCenterView: View {
    @Environment(ReleaseCenterModel.self) private var releases
    @State private var pendingRelease: PendingRelease?
    @State private var result: ReleaseActionRecord?

    struct PendingRelease: Identifiable {
        let status: AppStoreAppStatus
        let version: AppStoreVersionInfo
        var id: String { version.id }
    }

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)]

    var body: some View {
        let s = releases.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(s)
                waitingSection(releases.waiting)
                sectionTitle("App Store", symbol: "applelogo", readAt: s.appStoreReadAt, note: s.appStoreNote)
                if s.appStore.isEmpty {
                    EmptyPanelText(s.appStoreNote == nil ? "Not read yet. Press Refresh." : "Nothing read yet.")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(s.appStore) { status in AppStoreCard(status: status, onRelease: { pendingRelease = PendingRelease(status: status, version: $0) }) }
                    }
                }
                sectionTitle("Google Play", symbol: "play.rectangle", readAt: s.playReadAt, note: s.playNote)
                if s.play.isEmpty {
                    EmptyPanelText(s.playNote == nil ? "Not read yet. Press Refresh." : "Nothing read yet.")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(s.play) { PlayCard(status: $0) }
                    }
                }
                sectionTitle("GitHub", symbol: "arrow.triangle.pull", readAt: s.gitHubReadAt, note: s.gitHubNote)
                if s.repos.isEmpty {
                    EmptyPanelText("Not read yet. Press Refresh.")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(s.repos) { RepoCard(status: $0) }
                    }
                }
                if !releases.actions.isEmpty { actionsPanel }
                Text("App Store Connect and Google Play are read with the keys in Settings → Integrations, GitHub with its token. Google Play is read through an edit that is deleted right away and never committed. The only change this screen can make is releasing an approved App Store version, after you confirm it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle(SidebarItem.releaseCenter.title)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await releases.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(releases.isRefreshing)
                .keyboardShortcut("r")
                .help("Read the stores and GitHub now")
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pendingRelease != nil }, set: { if !$0 { pendingRelease = nil } }),
                            titleVisibility: .visible, presenting: pendingRelease) { p in
            Button("Release \(p.status.app.name) \(p.version.versionString) now") {
                Task { result = await releases.release(p.version, of: p.status) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("\(p.status.app.name) \(p.version.platformTitle) \(p.version.versionString) (build \(p.version.build?.number ?? "?")) will go live on the App Store for everyone. This can't be undone from here. Apple only accepts it from an App Manager or Admin key; with a Developer key it refuses and nothing changes.")
        }
        .alert(resultTitle, isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } }), presenting: result) { _ in
            Button("OK") { result = nil }
        } message: { r in
            Text(verbatim: [r.message, r.stateAfter.map { String(localized: "State now: \($0)") }].compactMap { $0 }.joined(separator: "\n"))
        }
        .alert("Error", isPresented: Binding(get: { releases.errorMessage != nil }, set: { if !$0 { releases.errorMessage = nil } })) {
            Button("OK") { releases.errorMessage = nil }
        } message: {
            Text(verbatim: releases.errorMessage ?? "")
        }
    }

    private var confirmTitle: String {
        guard let p = pendingRelease else { return "" }
        return String(localized: "Release \(p.status.app.name) \(p.version.versionString)?")
    }

    private var resultTitle: String {
        switch result?.outcome {
        case .verified: String(localized: "Released")
        case .unverified: String(localized: "Sent, not confirmed yet")
        case .failed: String(localized: "Not released")
        case .notSent, nil: String(localized: "Nothing was sent")
        }
    }

    private func header(_ s: ReleaseCenterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if releases.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Reading the stores and GitHub…").foregroundStyle(.secondary)
                } else {
                    Text("App Store \(shortTime(s.appStoreReadAt)) · Google Play \(shortTime(s.playReadAt)) · GitHub \(shortTime(s.gitHubReadAt))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await releases.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(releases.isRefreshing)
            }
            .font(.callout)
            Text("Read when the app opens and every 30 minutes while it runs. Each value shows where it was read and when.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String, symbol: String, readAt: Date?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(LocalizedStringKey(title), systemImage: symbol).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let note {
                Label { Text(verbatim: note) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func waitingSection(_ items: [WaitingItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Waiting on you", systemImage: "person.badge.clock").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: items.count.formatted()).font(.callout.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((items.isEmpty ? Color.green : .orange).opacity(0.15), in: Capsule())
            }
            if items.isEmpty {
                Text("Nothing waits on you in what was last read.").foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in WaitingRow(item: item, onRelease: release(for: item)) }
            }
        }
    }

    /// For a "release this version" item, the action that opens the confirmation.
    private func release(for item: WaitingItem) -> (() -> Void)? {
        guard item.kind == .releaseVersion, let sid = item.appStatusID, let vid = item.versionID,
              let status = releases.snapshot.appStore.first(where: { $0.id == sid }),
              let version = status.versions.first(where: { $0.id == vid }) else { return nil }
        return { pendingRelease = PendingRelease(status: status, version: version) }
    }

    private var actionsPanel: some View {
        DashboardPanel(title: "Sent from Linumic OS") {
            ForEach(releases.actions.prefix(10)) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        switch r.outcome {
                        case .verified: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(Text("Verified"))
                        case .unverified: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).accessibilityLabel(Text("Not verified"))
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel(Text("Failed"))
                        case .notSent: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).accessibilityLabel(Text("Nothing was sent"))
                        }
                        Text(verbatim: "\(r.appName) \(r.versionString)").fontWeight(.medium)
                    }
                    Text(verbatim: "\(r.action) · \(r.stateBefore) → \(r.stateAfter ?? "?") · \(r.at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let m = r.message { Text(verbatim: m).font(.caption).foregroundStyle(r.outcome == .verified ? Color.secondary : .red) }
                }
                .accessibilityElement(children: .combine)
            }
            Text("This device's own log of store actions sent (release-actions.json, never deleted).").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WaitingRow: View {
    let item: WaitingItem
    var onRelease: (() -> Void)?

    var body: some View {
        StripeCard(tint: item.severity.color) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ReleaseBadge(text: item.severity.title, symbol: item.severity.symbol, color: item.severity.color)
                Text(verbatim: item.subject).font(.headline)
                Spacer(minLength: 0)
            }
            Text(verbatim: item.title).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let d = item.detail { Text(verbatim: d).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            FitRow(spacing: 8) {
                if let onRelease {
                    Button("Release this version…", action: onRelease).buttonStyle(.borderedProminent)
                }
                if let url = item.url {
                    Link(destination: url) { Label("Open in browser", systemImage: "safari") }
                }
            }
            ReleaseSourceLine(source: item.source, at: item.observedAt)
        }
    }
}

// MARK: - App Store card

struct AppStoreCard: View {
    @Environment(ReleaseCenterModel.self) private var releases
    let status: AppStoreAppStatus
    let onRelease: (AppStoreVersionInfo) -> Void

    private var headline: AppStoreVersionPhase? {
        status.platforms.compactMap { status.inProgress(platform: $0)?.phase }.first ?? (status.versions.isEmpty ? nil : .live)
    }

    var body: some View {
        StripeCard(tint: status.error != nil ? .gray : (headline?.color ?? .gray)) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: status.app.name).font(.headline).lineLimit(2)
                Spacer(minLength: 0)
            }
            Text(verbatim: status.app.appIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                .environment(\.layoutDirection, .leftToRight)
            if let error = status.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    .font(.callout)
            } else {
                ForEach(status.platforms, id: \.self) { platform in platformBlock(platform) }
                if !status.builds.isEmpty { buildsBlock }
                ReleaseSourceLine(source: status.endpoint, at: status.fetchedAt)
            }
            Text("Listing source: \(status.app.source)").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
    }

    @ViewBuilder
    private func platformBlock(_ platform: String) -> some View {
        let live = status.live(platform: platform)
        let pending = status.inProgress(platform: platform)
        VStack(alignment: .leading, spacing: 4) {
            if status.platforms.count > 1 {
                Text(verbatim: AppStoreVersionInfo(id: "", versionString: "", platform: platform, state: "").platformTitle)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Live").foregroundStyle(.secondary)
                    if let live {
                        Text(verbatim: live.versionString + (live.build.map { " (\($0.number))" } ?? "")).monospacedDigit()
                    } else {
                        Text("Not live").foregroundStyle(.secondary)
                    }
                }
                if let pending {
                    GridRow {
                        Text("In progress").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(verbatim: pending.versionString).monospacedDigit()
                            ReleaseBadge(text: pending.phase.title, symbol: pending.phase.symbol, color: pending.phase.color)
                        }
                    }
                    GridRow {
                        Text("Build").foregroundStyle(.secondary)
                        if let b = pending.build {
                            Text("\(b.number), uploaded \(shortTime(b.uploadedAt))").monospacedDigit()
                        } else {
                            Text("No build attached").foregroundStyle(.secondary)
                        }
                    }
                    if let type = pending.releaseTypeTitle {
                        GridRow {
                            Text("Release").foregroundStyle(.secondary)
                            Text(verbatim: type)
                        }
                    }
                    GridRow {
                        Text("State").foregroundStyle(.secondary)
                        Text(verbatim: pending.state).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            if let pending, pending.canBeReleasedByOwner {
                Button {
                    onRelease(pending)
                } label: {
                    if releases.releasing.contains(pending.id) {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Releasing…") }
                    } else {
                        Label("Release this version…", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(releases.releasing.contains(pending.id))
                .accessibilityHint(Text("Asks for confirmation, then asks App Store Connect to release this version"))
            }
        }
    }

    private var buildsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Latest builds").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(status.builds.prefix(3)) { b in
                HStack(spacing: 6) {
                    Text(verbatim: "\(b.version ?? "?") (\(b.number))").monospacedDigit()
                    Text(verbatim: b.processingState ?? "?").font(.caption.monospaced())
                        .foregroundStyle(b.processingFailed ? Color.red : .secondary)
                    Spacer(minLength: 0)
                    Text(verbatim: shortTime(b.uploadedAt)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Google Play card

struct PlayCard: View {
    let status: PlayAppStatus

    var body: some View {
        let live = status.tracks.first { $0.track == "production" }?.releases.contains { $0.status == .completed } ?? false
        StripeCard(tint: status.error != nil ? .gray : (status.tracks.flatMap(\.releases).contains { $0.status == .halted } ? .red : live ? .green : .blue)) {
            Text(verbatim: status.app.name).font(.headline).lineLimit(2)
            Text(verbatim: status.app.appIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                .environment(\.layoutDirection, .leftToRight)
            if let error = status.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    .font(.callout)
            } else if status.tracks.allSatisfy({ $0.releases.isEmpty }) {
                Text("No releases on any track.").foregroundStyle(.secondary)
            } else {
                ForEach(status.tracks) { track in
                    ForEach(Array(track.releases.enumerated()), id: \.offset) { _, r in
                        if !r.isEmptyDraft { releaseRow(track.track, r) }
                    }
                }
            }
            if let note = status.detailNote {
                Text(verbatim: note).font(.caption).foregroundStyle(.orange)
            }
            ReleaseSourceLine(source: status.endpoint, at: status.fetchedAt)
        }
    }

    private func releaseRow(_ track: String, _ r: PlayTrackRelease) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: track).font(.callout.weight(.semibold))
                Text(verbatim: r.label).monospacedDigit()
                ReleaseBadge(text: r.status.title, symbol: r.status.symbol, color: r.status.color)
                if let f = r.userFraction {
                    Text(f.formatted(.percent.precision(.fractionLength(0...1)))).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Group {
                if let langs = r.releaseNoteLanguages {
                    if langs.isEmpty { Text("No release notes") } else { Text("Release notes: \(langs.joined(separator: ", "))") }
                } else {
                    Text("Release notes: unknown (not in this read)")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - GitHub card

struct RepoCard: View {
    let status: RepoReleaseStatus

    var body: some View {
        StripeCard(tint: status.error != nil ? .gray : status.mainCI.color) {
            HStack(alignment: .firstTextBaseline) {
                Link(destination: status.repo.url) { Text(verbatim: status.repo.slug).font(.headline) }
                    .environment(\.layoutDirection, .leftToRight)
                Spacer(minLength: 0)
            }
            Text(verbatim: status.repo.productName).font(.caption).foregroundStyle(.secondary)
            if let error = status.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    .font(.callout)
            } else {
                FitRow(spacing: 8) {
                    Text("CI on \(status.defaultBranch ?? "main")").foregroundStyle(.secondary)
                    ReleaseBadge(text: status.mainCI.title, symbol: status.mainCI.symbol, color: status.mainCI.color)
                    if let run = status.mainRuns.first, let url = run.url {
                        Link(destination: url) { Text("Latest run \(shortTime(run.createdAt))") }.font(.caption)
                    }
                }
                .font(.callout)
                HStack(spacing: 6) {
                    Text("Last release").foregroundStyle(.secondary)
                    if let r = status.lastRelease {
                        if let url = r.url {
                            Link(destination: url) { Text(verbatim: r.name.map { "\($0) (\(r.tag))" } ?? r.tag) }
                        } else {
                            Text(verbatim: r.tag)
                        }
                        if r.kind == .tag { Text("tag").foregroundStyle(.secondary) }
                        if let at = r.publishedAt { Text(verbatim: shortTime(at)).foregroundStyle(.secondary) }
                    } else if status.lastReleaseRead {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        UnknownLabel()
                    }
                }
                .font(.callout)
                pullsBlock
            }
            ReleaseSourceLine(source: "GitHub /repos/\(status.repo.slug) (pulls, actions/runs, releases)", at: status.fetchedAt)
        }
    }

    @ViewBuilder
    private var pullsBlock: some View {
        let stacks = status.stacks
        let stacked = Set(stacks.flatMap { $0.pulls.map(\.number) })
        let others = status.pulls.filter { !stacked.contains($0.number) }
        if status.pulls.isEmpty {
            Text("No open pull requests").font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Open pull requests: \(status.pulls.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(stacks) { stack in
                VStack(alignment: .leading, spacing: 4) {
                    Label("Stacked, in merge order", systemImage: "square.stack.3d.down.right").font(.caption.weight(.semibold))
                    ForEach(Array(stack.pulls.enumerated()), id: \.element.number) { i, pr in
                        PullRow(pr: pr, position: i + 1)
                    }
                    Text(LocalizedStringKey(PullStack.mergeHint)).font(.caption).foregroundStyle(.secondary)
                    if !stack.targetsDefaultBranch {
                        Text("The bottom PR targets \(stack.rootBase), not \(status.defaultBranch ?? "main").").font(.caption).foregroundStyle(.orange)
                    }
                    if stack.isBranched {
                        Text("Two PRs build on the same PR; merge order is shown depth-first.").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(others.prefix(8)) { PullRow(pr: $0, position: nil) }
            if others.count > 8 {
                Link(destination: URL(string: "https://github.com/\(status.repo.slug)/pulls")!) {
                    Text("\(others.count - 8) more on GitHub")
                }
                .font(.caption)
            }
        }
    }
}

struct PullRow: View {
    let pr: GitHubPullInfo
    let position: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let position { Text(verbatim: "\(position).").monospacedDigit().foregroundStyle(.secondary) }
                Link(destination: pr.url) { Text(verbatim: "#\(pr.number)").monospacedDigit() }
                Text(verbatim: pr.title).lineLimit(2)
            }
            .font(.callout)
            HStack(spacing: 6) {
                Text(verbatim: "\(pr.base) ← \(pr.head)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
            }
            FitRow(spacing: 6) {
                ReleaseBadge(text: pr.ci.title, symbol: pr.ci.symbol, color: pr.ci.color)
                ReleaseBadge(text: pr.isDraft ? L("Draft") : pr.mergeableTitle,
                             symbol: pr.isCleanlyMergeable ? "arrow.triangle.merge" : "exclamationmark.circle",
                             color: pr.isCleanlyMergeable ? .green : .orange)
                if pr.isBot { Text("bot").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Dashboard card

struct WaitingOnYouCard: View {
    @Environment(ReleaseCenterModel.self) private var releases
    @Environment(Router.self) private var router

    var body: some View {
        let items = releases.waiting
        Button { router.sidebar = .releaseCenter } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: SidebarItem.releaseCenter.symbol).foregroundStyle(.secondary)
                    Text("Releases: waiting on you").font(.headline)
                    Text(verbatim: items.count.formatted()).font(.headline).monospacedDigit()
                        .foregroundStyle(items.contains { $0.severity == .high } ? .red : items.isEmpty ? .green : .orange)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if items.isEmpty {
                    let s = releases.snapshot
                    if s.appStoreReadAt == nil && s.playReadAt == nil && s.gitHubReadAt == nil {
                        Text("Not read yet. Open Releases →").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing waits on you in what was last read.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items.prefix(3)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.severity.symbol).foregroundStyle(item.severity.color).accessibilityHidden(true)
                            Text(verbatim: "\(item.subject): \(item.title)").font(.callout).lineLimit(2)
                        }
                    }
                    if items.count > 3 {
                        Text("\(items.count - 3) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
