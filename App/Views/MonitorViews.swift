import LinumicCore
import SwiftUI

// MARK: - Shared visuals

extension MonitorState {
    var color: Color {
        switch self {
        case .up: .green
        case .degraded: .orange
        case .down: .red
        case .unknown: .gray
        }
    }

    var symbol: String {
        switch self {
        case .up: "checkmark.circle.fill"
        case .degraded: "tortoise.fill"
        case .down: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case .up: L("Up")
        case .degraded: L("Slow")
        case .down: L("Down")
        case .unknown: L("Not checked")
        }
    }
}

extension MonitorReason {
    var title: String {
        switch self {
        case .transport: L("No answer")
        case .httpStatus: L("HTTP error")
        case .unhealthy: L("Reports unhealthy")
        case .unreadableHealth: L("Health answer unreadable")
        case .slow: L("Slower than expected")
        }
    }
}

extension ExpiryLevel {
    var color: Color {
        switch self {
        case .ok: .green
        case .within30: .yellow
        case .within14: .orange
        case .within7, .expired: .red
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.seal"
        case .within30: "clock"
        case .within14: "clock.badge.exclamationmark"
        case .within7, .expired: "exclamationmark.triangle.fill"
        }
    }
}

/// Status as icon + text, so it never depends on colour alone.
struct MonitorStateBadge: View {
    let state: MonitorState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol).foregroundStyle(state.color)
            Text(state.title).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(state.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(state.color.opacity(0.55), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status: \(state.title)"))
    }
}

/// "42 days" with the 30/14/7-day colour and icon, or "Expired".
struct ExpiryDaysLabel: View {
    let days: Int

    var body: some View {
        let level = ExpiryLevel.level(daysLeft: days)
        HStack(spacing: 3) {
            Image(systemName: level.symbol).foregroundStyle(level.color).imageScale(.small).accessibilityHidden(true)
            if level == .expired {
                Text("Expired").foregroundStyle(.red)
            } else {
                Text("\(days) days").monospacedDigit()
            }
        }
    }
}

/// Latency over the last 24 hours, oldest on the left. Gaps are checks without an answer.
struct LatencySparkline: View {
    let values: [Int?]
    var tint: Color = .accentColor

    var body: some View {
        let known = values.compactMap { $0 }
        Canvas { context, size in
            guard values.count > 1, let maxValue = known.max() else { return }
            let top = Double(max(maxValue, 1))
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            var drawing = false
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * step
                guard let value else {
                    drawing = false
                    // A failed check: a short red tick on the baseline.
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height))
                    tick.addLine(to: CGPoint(x: x, y: size.height - 5))
                    context.stroke(tick, with: .color(.red), lineWidth: 1.5)
                    continue
                }
                let y = size.height - CGFloat(Double(value) / top) * (size.height - 2) - 1
                if drawing { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); drawing = true }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        // Time runs left to right in both languages, like a chart axis.
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let known = values.compactMap { $0 }
        guard let lo = known.min(), let hi = known.max() else { return String(localized: "No latency recorded yet") }
        return String(localized: "Latency over \(values.count) checks: \(lo) to \(hi) milliseconds")
    }
}

// MARK: - Monitor screen

struct MonitorView: View {
    @Environment(MonitorModel.self) private var monitor

    var body: some View {
        let s = monitor.summary
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(s)
                ForEach(MonitorProduct.allCases) { product in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: product.title).font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], spacing: 12) {
                            ForEach(monitor.targets(for: product)) { target in
                                MonitorCard(target: target)
                            }
                        }
                        if product == .website { cachePanel }
                    }
                }
                domainsPanel
                Text("Every check is a plain GET to a public page or health endpoint listed in MonitorCatalog (each with the repository file and line it comes from). No sign-in, cookie or token is sent, and nothing is written. Uptime is the share of checks that answered in the last 24 hours while this app was open; the history stays on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle(SidebarItem.monitor.title)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await monitor.checkNow() }
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isChecking)
                .help("Check every endpoint now")
            }
        }
    }

    private func header(_ s: MonitorSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitRow(spacing: 8) {
                MonitorCountChip(state: .up, count: s.up)
                MonitorCountChip(state: .degraded, count: s.degraded)
                MonitorCountChip(state: .down, count: s.down)
                if s.notChecked > 0 { MonitorCountChip(state: .unknown, count: s.notChecked) }
                if s.expiryWarnings > 0 {
                    StatusBadge(text: String(localized: "\(s.expiryWarnings) expiry warnings"), color: .orange)
                }
            }
            HStack(spacing: 8) {
                if monitor.isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                } else if let at = s.lastRoundAt {
                    Text("Last checked \(at.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
                } else {
                    Text("Not checked yet.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await monitor.checkNow() }
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isChecking)
            }
            .font(.callout)
            Text("Checked when the app opens and every 5 minutes while it runs (less often in Low Power Mode or when nothing answers). A notification comes after two failed checks in a row, and when a certificate or domain enters the 30, 14 or 7-day window.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cachePanel: some View {
        DashboardPanel(title: "Caching of the home page") {
            if let c = monitor.snapshot.cache {
                LabeledContent("Cache-Control") { Text(verbatim: c.cacheControl ?? "–").font(.callout.monospaced()).textSelection(.enabled) }
                LabeledContent("cf-cache-status") { Text(verbatim: c.cdnStatus ?? "–").font(.callout.monospaced()) }
                if let age = c.age {
                    LabeledContent("Age") { Text("\(age) seconds").monospacedDigit() }
                }
                if c.isLongerThanADay {
                    let maxAge = max(c.maxAge ?? 0, c.sharedMaxAge ?? 0)
                    Label {
                        Text("Pages may be cached for \(maxAge / 86_400) days, so an edit can take that long to reach visitors who already have the page. The GoDaddy CDN sets this and the plan has no setting for it; purge the cache from the GoDaddy dashboard after an important edit. For information only.")
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                } else {
                    Label("Cached for a day or less.", systemImage: "checkmark.circle").font(.callout)
                }
                Text("Read from \(c.url) at \(c.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            } else {
                EmptyPanelText("Not read yet. It is read with the home page check.")
            }
        }
    }

    private var domainsPanel: some View {
        DashboardPanel(title: "Domain registrations") {
            ForEach(MonitorCatalog.domains) { domain in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: domain.name).font(.headline)
                        Spacer()
                        if let days = monitor.snapshot.domains[domain.name]?.daysLeft(now: monitor.now) {
                            ExpiryDaysLabel(days: days)
                        }
                    }
                    if let d = monitor.snapshot.domains[domain.name] {
                        if let exp = d.expiresAt {
                            LabeledContent("Expires") { Text(exp.formatted(date: .long, time: .omitted)) }
                        } else {
                            LabeledContent("Expires") { UnknownLabel() }
                        }
                        if let registrar = d.registrar { LabeledContent("Registrar") { Text(verbatim: registrar) } }
                        Text("Source: \(d.sourceURL), read \(d.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if monitor.isCheckingDomains {
                        Text("Reading from RDAP…").foregroundStyle(.secondary)
                    } else {
                        UnknownLabel()
                    }
                    if let error = monitor.snapshot.domainErrors[domain.name] {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Text("Read from public RDAP (rdap.org) every 12 hours. Hosts on web.app and cloudfunctions.net belong to Google and are not renewed by Linumic.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Read now") { Task { await monitor.checkDomains() } }
                    .disabled(monitor.isCheckingDomains)
            }
        }
    }
}

struct MonitorCountChip: View {
    let state: MonitorState
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol).foregroundStyle(state.color).accessibilityHidden(true)
            Text(verbatim: "\(count.formatted())").font(.callout.weight(.semibold)).monospacedDigit()
            Text(state.title).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.color.opacity(count > 0 && state != .up ? 0.14 : 0.06), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct MonitorCard: View {
    @Environment(MonitorModel.self) private var monitor
    let target: MonitorTarget

    var body: some View {
        let result = monitor.result(for: target)
        let state = result?.state ?? .unknown
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MonitorStateBadge(state: state)
                Text(L(target.name)).font(.headline).lineLimit(2)
                if target.environment == .demo { StatusBadge(text: "Demo", color: .blue) }
                Spacer(minLength: 0)
            }
            Text(verbatim: target.url.absoluteString)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(target.url.absoluteString)
                .environment(\.layoutDirection, .leftToRight)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Latency").foregroundStyle(.secondary)
                    if let ms = result?.latencyMS { Text("\(ms) ms").monospacedDigit() } else { Text(verbatim: "–") }
                    Text("Uptime 24h").foregroundStyle(.secondary)
                    if let up = monitor.uptime(for: target) {
                        Text(up.formatted(.percent.precision(.fractionLength(up == 1 ? 0 : 1)))).monospacedDigit()
                    } else { Text(verbatim: "–") }
                }
                GridRow {
                    Text("Certificate").foregroundStyle(.secondary)
                    if let cert = monitor.snapshot.certificate(for: target) {
                        ExpiryDaysLabel(days: cert.daysLeft(now: monitor.now))
                            .help(Text("Ends \(cert.notAfter.formatted(date: .long, time: .shortened)); read \(cert.readAt.formatted(date: .abbreviated, time: .shortened))"))
                    } else { Text(verbatim: "–") }
                    Text("Domain").foregroundStyle(.secondary)
                    if let days = monitor.snapshot.domain(for: target)?.daysLeft(now: monitor.now) {
                        ExpiryDaysLabel(days: days)
                    } else if MonitorCatalog.domain(for: target.host) == nil {
                        Text("Google").foregroundStyle(.secondary).help("This host is on a Google-owned domain (web.app or cloudfunctions.net).")
                    } else { Text(verbatim: "–") }
                }
            }
            .font(.callout)

            LatencySparkline(values: monitor.latencies(for: target), tint: state == .down ? .red : .accentColor)

            if let r = result {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Checked \(r.checkedAt, style: .relative) ago")
                        if let code = r.statusCode { Text(verbatim: "HTTP \(code)").monospacedDigit() }
                        if let health = r.healthStatus { Text(verbatim: "\u{201C}\(health)\u{201D}") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let reason = r.reason {
                        Text(reason.title).font(.caption.weight(.semibold)).foregroundStyle(state.color)
                    }
                    if let failure = r.failure {
                        Text(verbatim: failure).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else {
                Text("Not checked yet.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Source: \(target.source)").font(.caption2).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            // A status stripe on the leading edge (mirrors in Dari).
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(state.color).frame(width: 4)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Dashboard strip

struct MonitorStatusStrip: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(Router.self) private var router

    var body: some View {
        let s = monitor.summary
        Button { router.sidebar = .monitor } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: SidebarItem.monitor.symbol).foregroundStyle(.secondary)
                    Text("Live status").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                if s.checked == 0 {
                    Text(monitor.isChecking ? "Checking every endpoint…" : "Not checked yet. Open Monitor →")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    FitRow(spacing: 8) {
                        MonitorCountChip(state: .up, count: s.up)
                        MonitorCountChip(state: .degraded, count: s.degraded)
                        MonitorCountChip(state: .down, count: s.down)
                        if let days = s.soonestExpiryDays {
                            HStack(spacing: 4) {
                                Text("Next expiry").foregroundStyle(.secondary)
                                ExpiryDaysLabel(days: days)
                            }
                            .font(.callout)
                        }
                    }
                    let down = monitor.targets.filter { monitor.result(for: $0)?.state == .down }
                    if !down.isEmpty {
                        Text(verbatim: down.map { "\($0.product.title): \(L($0.name))" }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.red)
                    }
                    if let at = s.lastRoundAt {
                        Text("Checked \(at.formatted(date: .omitted, time: .shortened)), public endpoints only")
                            .font(.caption).foregroundStyle(.tertiary)
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
