import LinumicCore
import SwiftUI

// MARK: - Labels shared by the screen and the menu bar panel

extension AutomationHealth.Level {
    var color: Color {
        switch self {
        case .ok: .statusGood
        case .attention: .statusWarn
        case .failing: .statusBad
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .failing: "xmark.octagon.fill"
        }
    }
}

extension AutomationOutcome {
    var title: String {
        switch self {
        case .succeeded: String(localized: "Done")
        case .partial: String(localized: "Partly done")
        case .failed: String(localized: "Failed")
        case .skipped(let reason): reason.title
        }
    }

    var color: Color {
        switch self {
        case .succeeded: .statusGood
        case .partial: .statusWarn
        case .failed: .statusBad
        case .skipped: .secondary
        }
    }

    var note: String? {
        switch self {
        case .succeeded(let n): n
        case .partial(let n), .failed(let n): n
        case .skipped(let reason): reason.explanation
        }
    }
}

extension AutomationSkipReason {
    var title: String {
        switch self {
        case .offline: String(localized: "Offline")
        case .turnedOff: String(localized: "Off in Settings")
        case .notConnected: String(localized: "Not connected")
        case .notReady: String(localized: "Not ready")
        case .alreadyRunning: String(localized: "Already running")
        case .unchanged: String(localized: "Unchanged")
        case .notDeployed: String(localized: "Not deployed")
        }
    }

    var explanation: String {
        switch self {
        case .offline: String(localized: "No network. It runs as soon as the connection returns.")
        case .turnedOff: String(localized: "Its automatic refresh is off in Settings → Integrations.")
        case .notConnected: String(localized: "Needs a key, token, sign-in or folder this device doesn't have yet.")
        case .notReady: String(localized: "The data it works on hadn't loaded yet.")
        case .alreadyRunning: String(localized: "The same refresh was already running from its screen.")
        case .unchanged: String(localized: "Nothing changed since the last run.")
        case .notDeployed: String(localized: "Its server side isn't deployed yet (docs/sentinel.md).")
        }
    }
}

extension AutomationTrigger {
    var title: String {
        switch self {
        case .schedule: String(localized: "Scheduled")
        case .manual: String(localized: "Run by you")
        case .launch: String(localized: "At launch")
        case .wake: String(localized: "After wake")
        case .network: String(localized: "Network back")
        case .background: String(localized: "Background")
        }
    }
}

private func cadenceText(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

private func relative(_ date: Date, now: Date) -> String {
    if abs(date.timeIntervalSince(now)) < 45 { return String(localized: "now") }
    return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

// MARK: - Automation screen

struct AutomationView: View {
    @Environment(AutomationEngine.self) private var engine
    @State private var historyFilter: AutomationJobID?
    @State private var failuresOnly = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AutomationStatusCard(now: context.date)
                    SentinelCard(now: context.date)
                    jobs(now: context.date)
                    AutomationPreferencesCard()
                    history(now: context.date)
                    Text("Every job only reads, exactly as its own screen does, with the keys already saved on this device. The run log stays on this device (automation.json, the last 14 days).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .navigationTitle(SidebarItem.automation.title)
        .toolbar {
            ToolbarItem {
                Button { engine.runAll() } label: { Label("Run all now", systemImage: "play.circle") }
                    .help("Run every enabled job now, one after another")
                    .disabled(engine.running != nil)
            }
        }
    }

    private func jobs(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jobs").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(engine.specs) { spec in
                    AutomationJobCard(spec: spec, now: now)
                }
            }
        }
    }

    private func history(now: Date) -> some View {
        let runs = engine.ledger.runs.filter { run in
            (historyFilter == nil || run.job == historyFilter) && (!failuresOnly || run.outcome.isFailure)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Run history").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle("Failures only", isOn: $failuresOnly).toggleStyle(.switch).controlSize(.small).fixedSize()
                Picker("Job", selection: $historyFilter) {
                    Text("All jobs").tag(AutomationJobID?.none)
                    ForEach(engine.specs) { Text(L($0.title)).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if runs.isEmpty {
                Text("No runs to show.").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs.prefix(150)) { run in
                        AutomationRunRow(run: run, now: now)
                        if run.id != runs.prefix(150).last?.id { Divider().padding(.leading, 30) }
                    }
                }
                .padding(.vertical, 4)
                .cardSurface()
            }
        }
    }
}

struct AutomationStatusCard: View {
    @Environment(AutomationEngine.self) private var engine
    let now: Date

    var body: some View {
        let health = engine.health
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: health.level.symbol).font(.title2).foregroundStyle(health.level.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(health)).font(.title3.weight(.semibold))
                    Text(subline(health)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                pauseControl
            }
            FitRow(spacing: 8) {
                StatusBadge(text: engine.online ? String(localized: "Online") : String(localized: "Offline"),
                            color: engine.online ? .statusGood : .statusWarn)
                if engine.lowPower { StatusBadge(text: String(localized: "Low Power Mode: half speed"), color: .yellow) }
                if NotificationGate.quietHours.contains(now) { StatusBadge(text: String(localized: "Quiet hours"), color: .indigo) }
                if let job = engine.running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running: \(L(AutomationCatalog.spec(job).title))").font(.callout)
                    }
                }
                if !engine.waiting.isEmpty {
                    Text("\(engine.waiting.count) waiting").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(health.failing, id: \.job) { f in
                Label {
                    Text("\(L(AutomationCatalog.spec(f.job).title)): \(f.message)").font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(f.count >= AutomationHealth.failingAfter ? .statusBad : .statusWarn)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(.large)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(health.level.color.opacity(health.level == .ok ? 0 : 0.35)))
    }

    private func headline(_ h: AutomationHealth) -> String {
        if engine.isPaused { return String(localized: "Automation is paused") }
        switch h.level {
        case .ok: return String(localized: "Everything runs on its own")
        case .attention: return String(localized: "\(h.failing.count) jobs need a look")
        case .failing: return String(localized: "A job keeps failing")
        }
    }

    private func subline(_ h: AutomationHealth) -> String {
        if engine.isPaused, let until = engine.ledger.pausedUntil {
            return String(localized: "Until \(until.formatted(date: .omitted, time: .shortened)). Run now still works.")
        }
        let next = engine.specs.filter { engine.isEnabled($0.id) }.compactMap { engine.nextDue($0.id) }.min()
        var parts: [String] = []
        if let last = h.lastRunAt { parts.append(String(localized: "Last run \(relative(last, now: now))")) }
        if let next { parts.append(String(localized: "next \(relative(next, now: now))")) }
        parts.append(String(localized: "running since \(engine.startedAt.formatted(date: .omitted, time: .shortened))"))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var pauseControl: some View {
        if engine.isPaused {
            Button("Resume") { engine.resume() }.buttonStyle(.borderedProminent)
        } else {
            Menu {
                Button("1 hour") { engine.pause(for: 3600) }
                Button("3 hours") { engine.pause(for: 3 * 3600) }
                Button("Until tomorrow morning") { engine.pause(for: untilMorning()) }
            } label: {
                Label("Pause", systemImage: "pause.circle")
            }
            .fixedSize()
        }
    }

    private func untilMorning() -> TimeInterval {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: now.addingTimeInterval(86_400))
        let eight = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return eight.timeIntervalSince(now)
    }
}

struct AutomationJobCard: View {
    @Environment(AutomationEngine.self) private var engine
    let spec: AutomationJobSpec
    let now: Date

    var body: some View {
        let state = engine.state(spec.id)
        let enabled = engine.isEnabled(spec.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(spec.title)).font(.headline)
                Spacer(minLength: 6)
                Toggle(L(spec.title), isOn: Binding(get: { enabled }, set: { engine.setEnabled(spec.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text(L(spec.detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let run = state?.lastRun {
                HStack(spacing: 6) {
                    StatusBadge(text: run.outcome.title, color: run.outcome.color)
                    Text(relative(run.finishedAt, now: now)).font(.caption).foregroundStyle(.secondary)
                    if (state?.consecutiveFailures ?? 0) > 1 {
                        Text("\(state!.consecutiveFailures)× in a row").font(.caption).foregroundStyle(.statusBad)
                    }
                }
                if let note = run.outcome.note {
                    Text(verbatim: note).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Text("Not run yet").font(.caption).foregroundStyle(.secondary)
            }
            if spec.id == .backup { backupFolderLine }
            Divider()
            HStack(spacing: 8) {
                Text("Every \(cadenceText(spec.cadence))").font(.caption).foregroundStyle(.secondary)
                if enabled {
                    Text("·").foregroundStyle(.tertiary)
                    nextText(now: now).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if engine.running == spec.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run now") { engine.runNow(spec.id) }
                        .controlSize(.small)
                        .disabled(engine.waiting.contains(spec.id))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .opacity(enabled ? 1 : 0.6)
    }

    /// What `Backups/` holds now, beside what the log says: the two can differ (a file deleted after the run).
    @ViewBuilder private var backupFolderLine: some View {
        if let s = engine.backupFolder {
            if let error = s.listError {
                Label { Text("Backups/ could not be read: \(error)") } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.statusBad) }
                    .font(.caption)
            } else if let newest = s.newest {
                Label {
                    Text(s.restores ? "In Backups/ now: \(newest.name) (\(s.files) in all), read back"
                                    : "In Backups/ now: \(newest.name) (\(s.files) in all), does not restore")
                } icon: {
                    Image(systemName: s.restores ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.restores ? .statusGood : .statusBad)
                }
                .font(.caption)
            } else {
                Label { Text("Backups/ is empty now.") } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.statusBad) }
                    .font(.caption)
            }
        } else {
            Text("Backups/ not checked yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func nextText(now: Date) -> Text {
        if engine.isPaused { return Text("paused") }
        if spec.needsNetwork, !engine.online { return Text("when online") }
        guard let next = engine.nextDue(spec.id), next > now else { return Text("next: due now") }
        return Text("next \(relative(next, now: now))")
    }
}

struct AutomationRunRow: View {
    let run: AutomationRun
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(run.outcome.color).frame(width: 8, height: 8).padding(.leading, 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L(AutomationCatalog.spec(run.job).title)).font(.callout.weight(.medium))
                    Text(run.outcome.title).font(.caption).foregroundStyle(run.outcome.color)
                }
                if let note = run.outcome.note {
                    Text(verbatim: note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).monospacedDigit()
                Text("\(run.trigger.title) · \(run.duration.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Preferences

struct AutomationPreferencesCard: View {
    @Environment(AutomationEngine.self) private var engine
    @AppStorage(AutomationNotifier.notifyKey) private var notifyFailures = true
    #if os(macOS)
    @AppStorage(MacPresence.menuBarKey) private var showMenuBar = true
    @AppStorage(MacPresence.hideDockKey) private var hideDock = false
    @AppStorage(MacPresence.startHiddenKey) private var startHidden = false
    @State private var loginItemOn = LoginItem.isOn
    @State private var loginItemNeedsApproval = LoginItem.needsApproval
    @State private var loginItemError: String?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preferences").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                #if os(macOS)
                Toggle(isOn: Binding(get: { loginItemOn }, set: setLoginItem)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        Text("So the automation runs from the moment the Mac starts, with no window needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if loginItemNeedsApproval {
                    HStack {
                        Text("macOS needs your approval in Login Items.").font(.caption).foregroundStyle(.statusWarn)
                        Button("Open Login Items") { LoginItem.openSystemSettings() }.controlSize(.small)
                    }
                }
                if let loginItemError { Text(verbatim: loginItemError).font(.caption).foregroundStyle(.statusBad) }
                Toggle(isOn: $showMenuBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in the menu bar")
                        Text("Status, what's waiting on you and Run now, without opening the window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $hideDock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide the Dock icon when no window is open")
                        Text("The app keeps running in the menu bar. Open it again from there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!showMenuBar)
                Toggle(isOn: $startHidden) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start in the menu bar")
                        Text("At launch, open no window. Takes effect from the next launch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!showMenuBar)
                Divider()
                #endif
                Toggle(isOn: $notifyFailures) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify when a job keeps failing")
                        Text("After \(AutomationHealth.failingAfter) failures in a row, and once more when it works again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                QuietHoursEditor()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    #if os(macOS)
    private func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemOn = LoginItem.isOn
        loginItemNeedsApproval = LoginItem.needsApproval
    }
    #endif
}

struct QuietHoursEditor: View {
    @Environment(AutomationEngine.self) private var engine

    var body: some View {
        let q = engine.ledger.quietHours
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { q.enabled }, set: { var c = q; c.enabled = $0; engine.setQuietHours(c) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiet hours")
                    Text("Alerts still arrive in Notification Center, silently: no banner, no sound. Checks keep running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if q.enabled {
                HStack(spacing: 12) {
                    DatePicker("From", selection: minuteBinding(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minuteBinding(\.end), displayedComponents: .hourAndMinute)
                }
                .fixedSize()
            }
        }
    }

    private func minuteBinding(_ key: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = engine.ledger.quietHours[keyPath: key]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                var q = engine.ledger.quietHours
                q[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                engine.setQuietHours(q)
            }
        )
    }
}

// MARK: - Dashboard strip

struct AutomationStatusStrip: View {
    @Environment(AutomationEngine.self) private var engine
    @Environment(Router.self) private var router

    var body: some View {
        let health = engine.health
        Button { router.go(.automation) } label: {
            HStack(spacing: 10) {
                Image(systemName: health.level.symbol).foregroundStyle(health.level.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automation").font(.headline)
                    Group {
                        if engine.isPaused {
                            Text("Paused")
                        } else if health.failing.isEmpty {
                            Text("\(engine.specs.count - engine.ledger.disabled.count) jobs on schedule")
                        } else {
                            Text(verbatim: health.failing.map { L(AutomationCatalog.spec($0.job).title) }.joined(separator: " · "))
                        }
                    }
                    .font(.callout).foregroundStyle(health.failing.isEmpty ? Color.secondary : health.level.color)
                }
                Spacer()
                if let job = engine.running {
                    ProgressView().controlSize(.small).help(L(AutomationCatalog.spec(job).title))
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Menu bar (Mac)

#if os(macOS)
struct MenuBarLabel: View {
    @Environment(AutomationEngine.self) private var engine
    @Environment(ReleaseCenterModel.self) private var releases

    var body: some View {
        let health = engine.health
        let symbol = engine.isPaused ? "pause.circle" : health.level == .ok ? "circle.hexagongrid" : "exclamationmark.triangle"
        let waiting = releases.waiting.filter { $0.severity == .high }.count + health.failing.count
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if waiting > 0 { Text(verbatim: "\(waiting)").monospacedDigit() }
        }
        .accessibilityLabel(Text("Linumic OS"))
    }
}

struct MenuBarPanel: View {
    @Environment(AutomationEngine.self) private var engine
    @Environment(ReleaseCenterModel.self) private var releases
    @Environment(MonitorModel.self) private var monitor
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                header(now: context.date)
                monitorRow
                waitingList
                jobsList(now: context.date)
                footer
            }
            .padding(14)
            .frame(width: 360)
        }
    }

    private func header(now: Date) -> some View {
        let health = engine.health
        return HStack(spacing: 10) {
            Image(systemName: health.level.symbol).font(.title2).foregroundStyle(health.level.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Linumic OS").font(.headline)
                Group {
                    if engine.isPaused, let until = engine.ledger.pausedUntil {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    } else if let job = engine.running {
                        Text("Running: \(L(AutomationCatalog.spec(job).title))")
                    } else if let last = health.lastRunAt {
                        Text("Last run \(relative(last, now: now))")
                    } else {
                        Text("Starting…")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !engine.online { StatusBadge(text: String(localized: "Offline"), color: .statusWarn) }
        }
    }

    private var monitorRow: some View {
        let s = monitor.summary
        return Button { open(.monitor) } label: {
            HStack(spacing: 8) {
                Image(systemName: SidebarItem.monitor.symbol).foregroundStyle(.secondary)
                if s.checked == 0 {
                    Text("Monitor: not checked yet").foregroundStyle(.secondary)
                } else {
                    MonitorCountChip(state: .up, count: s.up)
                    if s.degraded > 0 { MonitorCountChip(state: .degraded, count: s.degraded) }
                    if s.down > 0 { MonitorCountChip(state: .down, count: s.down) }
                }
                Spacer()
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var waitingList: some View {
        let items = Array(releases.waiting.sorted { $0.severity < $1.severity }.prefix(4))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Waiting on you").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(items) { item in
                    Button { open(.releaseCenter) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(item.severity == .high ? Color.statusBad : item.severity == .normal ? .statusWarn : .secondary)
                                .frame(width: 6, height: 6)
                            Text(verbatim: "\(item.subject): \(item.title)").font(.callout).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func jobsList(now: Date) -> some View {
        let health = engine.health
        let attention = engine.specs.filter { spec in health.failing.contains { $0.job == spec.id } }
        return VStack(alignment: .leading, spacing: 6) {
            Text(attention.isEmpty ? "Jobs" : "Needs a look").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(attention.isEmpty ? Array(engine.specs.prefix(5)) : attention) { spec in
                HStack(spacing: 8) {
                    Circle().fill(engine.state(spec.id)?.lastRun?.outcome.color ?? .secondary).frame(width: 7, height: 7)
                    Text(L(spec.title)).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    if engine.running == spec.id {
                        ProgressView().controlSize(.mini)
                    } else if let last = engine.state(spec.id)?.lastRun {
                        Text(relative(last.finishedAt, now: now)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { engine.runNow(spec.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Run now")
                        .disabled(engine.running == spec.id || engine.waiting.contains(spec.id))
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Button { engine.runAll() } label: { Label("Run all", systemImage: "play.circle") }
                    .disabled(engine.running != nil)
                if engine.isPaused {
                    Button { engine.resume() } label: { Label("Resume", systemImage: "play") }
                } else {
                    Button { engine.pause(for: 3600) } label: { Label("Pause 1 h", systemImage: "pause") }
                }
                Spacer()
                Button { open(.desk) } label: { Text("Open Linumic OS") }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            HStack {
                Button("Automation…") { open(.automation) }.buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link).keyboardShortcut("q")
            }
            .font(.caption)
        }
    }

    /// Brings the main window forward (opening one if none is open) on the given screen.
    private func open(_ item: SidebarItem) {
        router.go(item)
        MacPresence.activate()
        if let window = MacPresence.mainWindows.first ?? NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
#endif

// MARK: - Server watch (Sentinel)

struct SentinelCard: View {
    @Environment(SentinelModel.self) private var sentinel
    @Environment(AutomationEngine.self) private var engine
    let now: Date
    @State private var roundMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Server watch", systemImage: "server.rack").font(.headline)
                Spacer()
                if sentinel.isConnected, sentinel.isDeployed {
                    Button {
                        Task {
                            let accepted = await sentinel.requestRound()
                            roundMessage = accepted ? nil : String(localized: "A round was asked for less than 2 minutes ago.")
                        }
                    } label: {
                        if sentinel.isRequestingRound { ProgressView().controlSize(.small) } else { Text("Ask for a round now") }
                    }
                    .controlSize(.small)
                    .disabled(sentinel.isRequestingRound)
                }
            }
            content
            if let roundMessage { Text(verbatim: roundMessage).font(.caption).foregroundStyle(.secondary) }
            Text("Checks run on Supabase every 10 minutes, so an outage or an expiring licence is caught even while this Mac is off. The app reads the results; on iPhone, background refresh reads them too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(.large)
    }

    @ViewBuilder private var content: some View {
        if !sentinel.isConnected {
            Text("Sign in to the cloud (Settings → Account) to read the server's checks.").foregroundStyle(.secondary)
        } else if !sentinel.isDeployed {
            Text("Not deployed yet. The migrations and the sentinel function are ready in the repository; the deploy steps are in docs/sentinel.md.")
                .foregroundStyle(.secondary)
        } else if let summary = sentinel.summary {
            FitRow(spacing: 8) {
                switch summary.health {
                case .notRunning: StatusBadge(text: String(localized: "No round yet"), color: .statusWarn)
                case .stale: StatusBadge(text: String(localized: "Schedule stopped?"), color: .statusBad)
                case .down(let n): StatusBadge(text: String(localized: "\(n) down"), color: .statusBad)
                case .slow(let n): StatusBadge(text: String(localized: "\(n) slow"), color: .yellow)
                case .allUp: StatusBadge(text: String(localized: "All up"), color: .statusGood)
                }
                if let at = summary.lastRoundAt {
                    Text("Last server round \(relativeText(at))").font(.callout).foregroundStyle(.secondary)
                }
                if let snap = summary.lastSnapshotAt {
                    Text("Cloud backup \(snap.formatted(date: .abbreviated, time: .omitted))")
                        .font(.callout).foregroundStyle(summary.snapshotOverdue ? .statusWarn : .secondary)
                }
            }
            ForEach(summary.down) { status in
                Text(verbatim: "\(title(of: status.targetID)): \(status.lastFailure ?? "")")
                    .font(.callout).foregroundStyle(.statusBad).lineLimit(2)
            }
            let open = sentinel.unacknowledged
            if !open.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not acknowledged").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(open.prefix(8)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(event.severity == .critical ? Color.statusBad : event.severity == .warning ? .statusWarn : .secondary)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: sentinel.line(for: event)).font(.callout)
                                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            Button("Seen") { Task { await sentinel.acknowledge(event) } }.controlSize(.small)
                        }
                    }
                }
            }
        } else if let error = sentinel.loadError {
            Text(verbatim: error).foregroundStyle(.statusBad)
        } else {
            Text("Not read yet.").foregroundStyle(.secondary)
        }
    }

    private func title(of targetID: String) -> String {
        MonitorCatalog.targets.first { $0.id == targetID }.map { "\($0.product.title) \(L($0.name))" } ?? targetID
    }

    private func relativeText(_ date: Date) -> String {
        abs(date.timeIntervalSince(now)) < 45 ? String(localized: "now") : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
