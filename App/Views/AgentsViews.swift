import LinumicCore
import SwiftUI

// MARK: - Agents (ایجنت‌ها)

/// The 20 scheduled agents from the registry in this repository, and what each one did on GitHub: its open pull requests
/// (waiting for the coordinator's review and the owner's merge), what it merged or closed lately, its last activity, and
/// "no pull request for more than 4 days". Read from GitHub only; nothing here talks to the service that runs them.
struct AgentsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, waiting, quiet, unknown
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .waiting: "Waiting for review"
            case .quiet: "Quiet"
            case .unknown: "Unknown"
            }
        }
    }

    @Environment(ProductsModel.self) private var products
    @Environment(AutomationEngine.self) private var automation
    @Environment(Router.self) private var router
    @State private var filter: Filter = .all
    @State private var highlighted: String?

    var body: some View {
        let report = products.agents()
        let statuses = report.statuses.filter { s in
            switch filter {
            case .all: true
            case .waiting: !s.waiting.isEmpty
            case .quiet: s.isQuiet
            case .unknown: if case .unknown = s.quiet { true } else { false }
            }
        }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(report)
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    if report.nothingRead {
                        ContentUnavailableView {
                            Label("Not read yet", systemImage: SidebarItem.agents.symbol)
                        } description: {
                            Text("The agents' pull requests are read from GitHub with the token in Settings → Integrations.")
                        } actions: {
                            Button("Read now") { automation.runNow(.products) }
                        }
                    } else if statuses.isEmpty {
                        Text("No agent matches.").foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(statuses) { status in
                            AgentCard(status: status, quietAfter: report.registry.rules.quietAfterDays, highlighted: highlighted == status.id)
                                .id(status.id)
                        }
                    }
                    Text(verbatim: report.registry.source).font(.caption).foregroundStyle(.secondary)
                    Text("Read-only. Pull requests are matched by a title that starts with [agent:<slug>] or a branch that starts with agent/<slug>/, on the newest 50 pull requests of each repository. Agents open pull requests only; the coordinator reviews them and the owner merges.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            // From the Desk, the Brief or the Command Palette: one agent, scrolled to and highlighted, or the waiting ones.
            .onChange(of: router.request, initial: true) {
                switch router.take({ r in
                    switch r {
                    case .agent, .agentsWaiting: true
                    default: false
                    }
                }) {
                case .agent(let slug)?:
                    filter = .all
                    highlighted = slug
                    withAnimation { proxy.scrollTo(slug, anchor: .center) }
                case .agentsWaiting?:
                    filter = .waiting
                default: break
                }
            }
        }
        .navigationTitle(SidebarItem.agents.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { automation.runNow(.products) } label: {
                    if products.isRefreshing { ProgressView().controlSize(.small) }
                    else { Label("Read now", systemImage: "arrow.clockwise") }
                }
                .disabled(products.isRefreshing)
                .keyboardShortcut("r")
                .help("Read the agents' pull requests from GitHub again (read-only)")
            }
        }
    }

    private func header(_ report: AgentsReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitRow(spacing: 8) {
                BoardPill(text: String(localized: "\(report.registry.agents.count) agents, every 2 days"), symbol: "clock.arrow.2.circlepath", color: .teal)
                BoardPill(text: String(localized: "\(report.waiting.count) pull requests waiting for review"), symbol: "arrow.triangle.pull",
                          color: report.waiting.isEmpty ? .gray : .orange)
                BoardPill(text: String(localized: "\(report.quiet.count) quiet for more than \(report.registry.rules.quietAfterDays) days"),
                          symbol: "moon.zzz.fill", color: report.quiet.isEmpty ? .gray : .red)
            }
            Group {
                if let at = report.readAt {
                    Text("Pull requests last read from GitHub: \(at.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Pull requests not read from GitHub yet.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(report.notRead, id: \.self) { repo in
                Label { Text("\(repo): pull requests not read yet.") } icon: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                    .font(.caption)
            }
            ForEach(report.failures.sorted(by: { $0.key < $1.key }), id: \.key) { repo, error in
                Label { Text(verbatim: "\(repo): \(error)") } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AgentCard: View {
    let status: AgentStatus
    let quietAfter: Int
    let highlighted: Bool

    private var agent: AgentEntry { status.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The status on its own line, so a long slug never wraps letter by letter on an iPhone.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: agent.label).font(.headline)
                Text(verbatim: agent.slug).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            pills
            Text(verbatim: L(agent.title)).font(.callout)
            FitRow(spacing: 10) {
                Label { Text(verbatim: agent.products.joined(separator: L(", "))) } icon: { Image(systemName: "shippingbox") }
                if !agent.platformKinds.isEmpty {
                    Label { Text(verbatim: agent.platformKinds.map(\.title).joined(separator: L(", "))) } icon: { Image(systemName: "iphone.and.arrow.forward") }
                }
                Label {
                    Text(agent.days == .odd ? "Every 2 days at \(agent.utcTime) UTC (odd days)" : "Every 2 days at \(agent.utcTime) UTC (even days)")
                } icon: { Image(systemName: "clock") }
            }
            .font(.caption).foregroundStyle(.secondary)
            FitRow(spacing: 8) {
                ForEach(agent.repositories, id: \.self) { repo in
                    if let url = URL(string: "https://github.com/\(repo)/pulls") {
                        Link(destination: url) { Text(verbatim: repo).font(.caption.monospaced()) }
                            .help(Text("Open the pull requests of \(repo) on GitHub"))
                    }
                }
            }
            Group {
                if let last = status.lastActivity {
                    Text("Last activity: \(last.formatted(date: .abbreviated, time: .shortened))")
                } else if status.readAt != nil {
                    Text("No pull request of this agent on the pages read.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !status.open.isEmpty {
                Text("Open pull requests").font(.caption.weight(.semibold))
                ForEach(status.open) { pr in pullLink(pr) }
            }
            if !status.recent.isEmpty {
                Text("Recently merged or closed").font(.caption.weight(.semibold))
                ForEach(status.recent.prefix(3)) { pr in pullLink(pr) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    @ViewBuilder private var pills: some View {
        FitRow(spacing: 6) {
            if !status.waiting.isEmpty {
                BoardPill(text: String(localized: "Waiting for review: \(status.waiting.count)"), symbol: "arrow.triangle.pull", color: .orange)
            }
            switch status.quiet {
            case .yes(let days, let since, _, let asOf):
                BoardPill(text: String(localized: "No pull request for \(days) days"), symbol: "moon.zzz.fill", color: .red,
                          help: String(localized: "None since \(since.formatted(date: .abbreviated, time: .omitted)), as read \(asOf.formatted(date: .abbreviated, time: .shortened)). It runs every 2 days; more than \(quietAfter) days without one is a Desk item."))
            case .unknown(let why):
                BoardPill(text: String(localized: "Unknown"), symbol: "questionmark.circle.fill", color: .gray, help: why)
            case .no:
                if status.lastActivity != nil {
                    BoardPill(text: String(localized: "Active"), symbol: "checkmark.circle.fill", color: .green)
                } else {
                    BoardPill(text: String(localized: "No pull request yet"), symbol: "circle.dashed", color: .gray,
                              help: String(localized: "Created less than \(quietAfter) days ago, and none opened yet."))
                }
            }
        }
    }

    private func pullLink(_ pr: AgentPull) -> some View {
        Link(destination: pr.url) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "#\(pr.number) \(pr.title)").lineLimit(2)
                    Text(verbatim: "\(pr.repo) · \(pr.state.title)\(pr.isDraft ? " · " + String(localized: "Draft") : "") · \(pr.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: pr.state == .open ? "arrow.triangle.pull" : (pr.state == .merged ? "arrow.triangle.merge" : "xmark.circle"))
            }
        }
        .font(.callout)
    }
}
