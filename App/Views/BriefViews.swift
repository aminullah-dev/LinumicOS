import LinumicCore
import SwiftUI

// MARK: - Daily Brief screen (گزارش روز)

extension BriefSeverity {
    var color: Color {
        switch self {
        case .high: .red
        case .normal: .orange
        case .info: .blue
        }
    }

    var symbol: String {
        switch self {
        case .high: "exclamationmark.octagon.fill"
        case .normal: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .high: String(localized: "Needs you now")
        case .normal: String(localized: "Needs you soon")
        case .info: String(localized: "For information")
        }
    }
}

/// The brief, built from what the app already read. Every line says where it was read and when, and opens its screen.
struct DailyBriefView: View {
    @Environment(BriefModel.self) private var briefs
    @Environment(Router.self) private var router
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        // Reading `monitor.now` re-renders every minute, so "read 3 min ago" style day counts stay current.
        let brief = briefs.brief(now: max(.now, monitor.now))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(brief)
                ForEach(brief.sections) { section in
                    BriefSectionCard(section: section) { router.open($0) }
                }
                Text("The brief is built on this device from what Monitor, Releases, Licences, WorkTrack customers, Operations and Oversight last read. It makes no requests of its own. A source that was never read says so instead of showing zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(SidebarItem.brief.title)
        .toolbar {
            ToolbarItem {
                Button { router.isPalettePresented = true } label: {
                    Label("Search and commands", systemImage: "magnifyingglass")
                }
                .help("Search screens, records and commands (⌘K)")
            }
        }
    }

    private func header(_ brief: DailyBrief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(brief.generatedAt.formatted(date: .complete, time: .omitted))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            FitRow(spacing: 8) {
                let high = brief.attention.count { $0.severity == .high }
                let normal = brief.attention.count { $0.severity == .normal }
                if brief.attention.isEmpty {
                    ReleaseBadge(text: String(localized: "Nothing needs you"), symbol: "checkmark.circle.fill", color: .green)
                } else {
                    if high > 0 { ReleaseBadge(text: String(localized: "\(high) now"), symbol: BriefSeverity.high.symbol, color: .red) }
                    if normal > 0 { ReleaseBadge(text: String(localized: "\(normal) soon"), symbol: BriefSeverity.normal.symbol, color: .orange) }
                }
                let never = brief.neverRead.filter { $0 != .changes }.count
                if never > 0 {
                    ReleaseBadge(text: String(localized: "\(never) sources not read"), symbol: "questionmark.circle", color: .gray)
                }
            }
            Group {
                if BriefModel.isNotificationOn {
                    if let next = briefs.nextNotification {
                        Text("Morning notification: next on \(next.formatted(date: .abbreviated, time: .shortened)). Change it in Settings → Integrations.")
                    } else {
                        Text("Morning notification is on but not scheduled yet (it is scheduled after the first refresh, if notifications are allowed).")
                    }
                } else {
                    Text("Morning notification is off. Turn it on in Settings → Integrations.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One source: a stripe card whose colour follows the most urgent line. "All clear" and "not read" collapse to one row.
struct BriefSectionCard: View {
    let section: BriefSection
    let open: (BriefDestination) -> Void

    private var tint: Color {
        switch section.state {
        case .neverRead: .gray
        case .unavailable: .red
        case .allClear: .green
        case .items: section.highest?.color ?? .green
        }
    }

    var body: some View {
        StripeCard(tint: tint) {
            HStack(spacing: 8) {
                Label(section.kind.title, systemImage: section.kind.symbol)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                stateBadge
            }
            switch section.state {
            case .neverRead(let why):
                Label { Text(verbatim: why) } icon: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                    .font(.callout).foregroundStyle(.secondary)
            case .unavailable(let why):
                Label { Text(verbatim: why) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    .font(.callout)
            case .allClear, .items:
                ForEach(section.lines) { line in
                    BriefLineRow(line: line, open: open)
                    if line.id != section.lines.last?.id { Divider() }
                }
            }
            ForEach(section.notes, id: \.self) { note in
                Label { Text(verbatim: note) } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let at = section.readAt {
                ReleaseSourceLine(source: section.source, at: at)
            } else {
                Text("Source: \(section.source)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch section.state {
        case .neverRead:
            ReleaseBadge(text: String(localized: "Not read"), symbol: "questionmark.circle", color: .gray)
        case .unavailable:
            ReleaseBadge(text: String(localized: "Could not read"), symbol: "exclamationmark.triangle.fill", color: .red)
        case .allClear:
            ReleaseBadge(text: String(localized: "All clear"), symbol: "checkmark.circle.fill", color: .green)
        case .items:
            if section.attentionCount > 0 {
                ReleaseBadge(text: String(localized: "\(section.attentionCount) need you"),
                             symbol: section.highest?.symbol ?? "circle", color: section.highest?.color ?? .orange)
            } else {
                ReleaseBadge(text: String(localized: "\(section.lines.count) for information"), symbol: BriefSeverity.info.symbol, color: .blue)
            }
        }
    }
}

struct BriefLineRow: View {
    let line: BriefLine
    let open: (BriefDestination) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: line.severity.symbol)
                .foregroundStyle(line.severity.color)
                .accessibilityLabel(Text(verbatim: line.severity.title))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: line.text).fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let at = line.readAt {
                    ReleaseSourceLine(source: line.source, at: at)
                } else {
                    Text("Source: \(line.source)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                open(line.destination)
            } label: {
                Label("Open", systemImage: "chevron.forward")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Open the screen this line comes from")
            .minTapTarget()
        }
        .accessibilityElement(children: .contain)
    }
}
