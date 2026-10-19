import LinumicCore
import SwiftUI

// MARK: - Desk screen (میز کار)

/// The home screen: what needs the owner today, this week and later, grouped by product (WorkTrack, then SafeBeauty,
/// then the others). Every row says where it was read and when, and opens the place to act. Built on this device from
/// the Daily Brief and the ledgers; nothing here writes anywhere except the owner's marks in desk-state.json.
struct DeskView: View {
    @Environment(DeskModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(MonitorModel.self) private var monitor
    @State private var showLater = false
    @State private var showMarked = true
    @State private var showHidden = false
    @State private var dismissing: DeskItem?
    @State private var highlighted: String?

    var body: some View {
        // Reading `monitor.now` re-renders every minute, so "stale" and due days stay current.
        let now = max(.now, monitor.now)
        let desk = model.desk(now: now)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(desk, now: now)
                    if let error = model.loadError {
                        Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            .font(.callout)
                    } else if let error = model.errorMessage {
                        HStack(alignment: .firstTextBaseline) {
                            Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            Spacer()
                            Button("OK") { model.errorMessage = nil }.buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                    bucket(.today, desk.today)
                    bucket(.thisWeek, desk.thisWeek)
                    DisclosureGroup(isExpanded: $showLater) {
                        groups(desk.later).padding(.top, 8)
                    } label: {
                        sectionTitle(DeskBucket.later.title, count: desk.later.count)
                    }
                    if !desk.markedNotTicked.isEmpty {
                        DisclosureGroup(isExpanded: $showMarked) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("You marked these done on the Desk. A PRIORITIES.md line stays here until it is ticked or changed in the ledger, so the ledger stays the record. A NEXT-ACTIONS item has no checkbox: it stays until its title changes or it is no longer in the newest report.")
                                    .font(.caption).foregroundStyle(.secondary)
                                groups(desk.markedNotTicked)
                            }
                            .padding(.top, 8)
                        } label: {
                            sectionTitle(String(localized: "You marked it, the ledger isn't ticked yet"), count: desk.markedNotTicked.count)
                        }
                    }
                    if !desk.hidden.isEmpty {
                        DisclosureGroup(isExpanded: $showHidden) {
                            groups(desk.hidden).padding(.top, 8)
                        } label: {
                            sectionTitle(String(localized: "Snoozed, waiting, dismissed or done"), count: desk.hidden.count)
                        }
                    }
                    Text("The Desk is built on this device from the Daily Brief and the ledgers (the PRIORITIES.md files and the newest NEXT-ACTIONS), read-only. A source that was not read is shown as an item, never as zero. Only your marks are saved, in desk-state.json on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 940, alignment: .leading)
            }
            .onChange(of: router.request, initial: true) {
                guard case .deskItem(let id)? = router.take({ if case .deskItem = $0 { true } else { false } }) else { return }
                reveal(id, in: desk, proxy: proxy)
            }
        }
        .navigationTitle(SidebarItem.desk.title)
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button {
                    Task { await model.refreshLedgers() }
                } label: {
                    Label("Read ledgers now", systemImage: "arrow.clockwise")
                }
                .help("Read the PRIORITIES.md files and the newest NEXT-ACTIONS again")
                .disabled(model.isReading)
            }
            #endif
            ToolbarItem {
                Button { router.isPalettePresented = true } label: {
                    Label("Search and commands", systemImage: "magnifyingglass")
                }
                .help("Search screens, records and commands (⌘K)")
            }
        }
        .sheet(item: $dismissing) { item in
            DeskDismissSheet(item: item) { reason in model.dismiss(item, reason: reason) }
        }
    }

    // MARK: Parts

    private func header(_ desk: Desk, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(now.formatted(date: .complete, time: .omitted))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            // Green only when nothing is open today and every source was read: an unread source is not "all clear".
            let unknown = desk.open.count { $0.item.kind == .source }
            FitRow(spacing: 8) {
                ReleaseBadge(text: String(localized: "\(desk.today.count) today"), symbol: "sun.max",
                             color: !desk.today.isEmpty ? .red : (unknown > 0 ? .gray : .green))
                ReleaseBadge(text: String(localized: "\(desk.thisWeek.count) this week"), symbol: "calendar", color: .orange)
                ReleaseBadge(text: String(localized: "\(desk.later.count) later"), symbol: "tray", color: .gray)
                if unknown > 0 {
                    ReleaseBadge(text: String(localized: "\(unknown) sources to check"), symbol: "questionmark.circle", color: .gray)
                }
            }
            ledgerLine(desk)
            DeskBackupCard()
        }
    }

    @ViewBuilder
    private func ledgerLine(_ desk: Desk) -> some View {
        if DeskModel.supportsLedgers {
            let read = desk.sources.filter(\.isRead)
            HStack(spacing: 8) {
                if model.isReading {
                    ProgressView().controlSize(.small)
                    Text("Reading the ledgers…")
                } else if let at = model.reading?.readAt {
                    Text("Ledgers: \(read.count) of \(desk.sources.count) read, \(at.formatted(date: .omitted, time: .shortened)).")
                } else {
                    Text("Ledgers: not read yet.")
                }
                if read.count < desk.sources.count {
                    Button("Ledger access…") { router.go(.integrations) }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Ledgers are read on the Mac. On this device the Desk shows the Daily Brief's items only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).font(.title3.weight(.semibold))
            Text(count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func bucket(_ bucket: DeskBucket, _ rows: [DeskRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(bucket.title, count: rows.count)
            if rows.isEmpty {
                Text("Nothing here in what was read.").font(.callout).foregroundStyle(.secondary)
            } else {
                groups(rows)
            }
        }
    }

    private func groups(_ rows: [DeskRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Desk.groups(rows)) { group in
                StripeCard(tint: group.rows.map(\.item.severity).min()?.color ?? .gray) {
                    HStack(spacing: 6) {
                        Text(verbatim: group.domain.displayTitle).font(.headline)
                        if group.domain.isFocus {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                .accessibilityLabel(Text("Focus product"))
                        }
                        Spacer()
                        Text(group.rows.count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        DeskRowView(row: row, highlighted: highlighted == row.id,
                                    open: { open(row.item) }, dismiss: { dismissing = row.item })
                            .id(row.id)
                        if row.id != group.rows.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func open(_ item: DeskItem) {
        switch item.destination {
        case .file(let path, _):
            #if os(macOS)
            model.openFile(path)
            #endif
        default:
            router.open(item.destination)
        }
    }

    /// Opens the section that holds the item (from the Command Palette), scrolls to it and highlights it briefly.
    private func reveal(_ id: String, in desk: Desk, proxy: ScrollViewProxy) {
        if desk.later.contains(where: { $0.id == id }) { showLater = true }
        if desk.markedNotTicked.contains(where: { $0.id == id }) { showMarked = true }
        if desk.hidden.contains(where: { $0.id == id }) { showHidden = true }
        highlighted = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            try? await Task.sleep(for: .seconds(3))
            if highlighted == id { highlighted = nil }
        }
    }
}

// MARK: - One row

struct DeskRowView: View {
    @Environment(DeskModel.self) private var model
    @Environment(Router.self) private var router
    let row: DeskRow
    let highlighted: Bool
    let open: () -> Void
    let dismiss: () -> Void
    @State private var expanded = false
    @State private var copied = false

    private var item: DeskItem { row.item }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: item.severity.symbol)
                .foregroundStyle(item.severity.color)
                .accessibilityLabel(Text(verbatim: item.severity.title))
            VStack(alignment: .leading, spacing: 4) {
                Text(DeskText.text(item.title, of: item)).fixedSize(horizontal: false, vertical: true)
                FitRow(spacing: 6) {
                    ReleaseBadge(text: item.domain.displayTitle, symbol: "shippingbox", color: .accentColor)
                    ForEach(item.related) { other in
                        ReleaseBadge(text: other.displayTitle, symbol: "shippingbox", color: .gray)
                    }
                    if let due = item.due {
                        ReleaseBadge(text: String(localized: "Due \(due.start().formatted(date: .abbreviated, time: .omitted))"),
                                     symbol: "calendar.badge.clock", color: .red)
                    }
                    if row.isStale {
                        ReleaseBadge(text: String(localized: "Stale"), symbol: "clock.badge.exclamationmark", color: .orange)
                    }
                    if item.ownerAction {
                        ReleaseBadge(text: String(localized: "Yours"), symbol: "person", color: .purple)
                    }
                    // The report scheduled it for this week; the Desk puts the owner's work in a focus product in Today.
                    // Say so, so the Desk and the report don't seem to disagree.
                    if item.horizon == .thisWeek, row.bucket == .today {
                        ReleaseBadge(text: String(localized: "This week in the report"), symbol: "calendar", color: .gray)
                    }
                }
                status
                if let detail = item.detail, !detail.isEmpty {
                    Text(DeskText.text(detail, of: item))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The report's own «منبع» line can say what is not known («… ندیده‌ام»), so it is shown as written.
                if let reference = item.reference, !reference.isEmpty {
                    Text("Source in the report: \(reference)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // The ledger's own dated corrections under the line are always shown: the line above may be wrong.
                ForEach(Array(item.corrections.enumerated()), id: \.offset) { _, note in
                    Label { Text(DeskText.text(note, of: item)).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .accessibilityLabel(Text("Correction in the ledger: \(note)"))
                }
                if expanded, !item.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Under this line in the ledger:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in
                            Text(DeskText.text(note, of: item)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if hasMore {
                    Button(expanded ? String(localized: "Less") : String(localized: "More")) { expanded.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                }
                sourceLine
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(4)
        .background(highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    /// More to show than the collapsed row holds: a long detail, or lines under it in the ledger.
    private var hasMore: Bool {
        let detail = item.detail ?? ""
        return detail.count > 140 || detail.contains("\n") || !item.notes.isEmpty
    }

    /// Where it was read and when; "checked" for a source that says it was not read, since its time is an attempt.
    @ViewBuilder
    private var sourceLine: some View {
        if let at = item.evidence.readAt {
            if item.wasRead {
                ReleaseSourceLine(source: item.evidence.location, at: at)
            } else {
                Text("Source: \(item.evidence.location), checked \(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
            }
        } else {
            Text("Source: \(item.evidence.location), read time unknown").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    /// What the owner did with it, in words (colour is never the only sign).
    @ViewBuilder
    private var status: some View {
        if let note = row.stillOpenNote {
            Label { Text(verbatim: note) } icon: { Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange) }
                .font(.caption)
        }
        switch row.resolution {
        case .markedNotTicked(let m):
            Label {
                if item.origin == .nextActions {
                    Text("You marked it done \(m.at.formatted(date: .abbreviated, time: .shortened)); the newest NEXT-ACTIONS still lists it.")
                } else {
                    Text("You marked it done \(m.at.formatted(date: .abbreviated, time: .shortened)); the ledger still lists it.")
                }
            } icon: {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
            .font(.caption)
        case .hidden(let m):
            Label { Text(verbatim: DeskText.hiddenReason(m, of: item)) } icon: { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                .font(.caption).foregroundStyle(.secondary)
        case .open, .reopened:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if copied {
                Text("Copied").font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
            Button(action: open) {
                Label("Open", systemImage: "chevron.forward").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help(openHelp)
            .minTapTarget()
            .disabled(!canOpen)
            switch row.resolution {
            case .open, .reopened:
                if item.closesAtSource, let id = obligationID, case .screen(let destination) = item.destination {
                    // A live obligation (the continuity export, a restore test, a licence) closes only when its source
                    // records it: Done goes there, never to a typed sentence or a Desk mark.
                    Button { router.closeAtSource(id, destination: destination) } label: {
                        Label("Done…", systemImage: "checkmark").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .help("It closes when its source records it (an export off this Mac, a restore test, a renewal): this opens that place")
                    .minTapTarget()
                } else if let id = obligationID {
                    // An obligation is done only with what proves it: the Obligations screen asks for it.
                    Button { router.go(.obligations, request: .completeObligation(id)) } label: {
                        Label("Done…", systemImage: "checkmark").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .help("Record it done with what proves it (a receipt, a page, a screenshot's name)")
                    .minTapTarget()
                } else {
                    Button { model.markDone(item) } label: { Label("Done", systemImage: "checkmark").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderless)
                        .help(doneHelp)
                        .minTapTarget()
                }
                Menu {
                    Menu("Snooze") {
                        Button("Until tomorrow") { model.snooze(item, days: 1) }
                        Button("For 3 days") { model.snooze(item, days: 3) }
                        Button("For a week") { model.snooze(item, days: 7) }
                    }
                    Button("Waiting on others") { model.markWaiting(item) }
                    Button("Dismiss…", action: dismiss)
                    Divider()
                    Button("Copy agent brief") { copy() }
                } label: {
                    Label("More actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Snooze, waiting on others, dismiss, or copy a brief for an agent")
                .minTapTarget()
            case .markedNotTicked, .hidden:
                Button { model.restore(item.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderless)
                    .help("Undo the mark and show it with the others again")
                    .minTapTarget()
                Menu {
                    Button("Copy agent brief") { copy() }
                } label: {
                    Label("More actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .minTapTarget()
            }
        }
        .labelStyle(.iconOnly)
    }

    /// The obligation this item is about, if it is one: from the Brief line, or (for an item made before lines carried
    /// it) from an obligation destination.
    private var obligationID: String? {
        if let id = item.obligationID { return id }
        if case .screen(.obligation(let id)) = item.destination { return id }
        return nil
    }

    /// What pressing Done will do, worded as the action (nothing is done until it is pressed).
    private var doneHelp: Text {
        switch (item.kind, item.origin) {
        case (.task, .nextActions): Text("Mark it done here: it stays listed until its title changes or it leaves the newest NEXT-ACTIONS.")
        case (.task, _): Text("Mark it done here: it stays listed until the ledger line is ticked.")
        default:
            item.evidence.readAt == nil ? Text("Mark it done: hidden until this fact changes, since its source gives no read time.")
                                        : Text("Mark it done: it comes back if the next reading still shows it.")
        }
    }

    private var canOpen: Bool {
        #if os(macOS)
        true
        #else
        if case .file = item.destination { return false }
        return true
        #endif
    }

    private var openHelp: LocalizedStringKey {
        switch item.destination {
        case .file: "Open the ledger file"
        case .ledgerAccess: "Open Settings → Integrations → Ledger access"
        case .screen: "Open the screen this item comes from"
        }
    }

    private func copy() {
        model.copyAgentBrief(item)
        withAnimation { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }
}

// MARK: - Daily backup, as Backups/ holds it

/// The daily backup as the folder holds it now: the newest file, its day, whether it was read back and decoded, and
/// whether it is the inventory as it is now. Never the run log's word alone.
struct DeskBackupCard: View {
    @Environment(AutomationEngine.self) private var engine
    @Environment(Router.self) private var router

    var body: some View {
        let status = engine.backupFolder
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(status)).foregroundStyle(color(status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(status)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let detail = detail(status) {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Automation…") { router.go(.automation) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.secondary, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ s: BackupFolderStatus?) -> String {
        guard let s else { return "questionmark.circle" }
        if s.listError != nil || s.isEmpty { return "externaldrive.badge.xmark" }
        return s.restores ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    private func color(_ s: BackupFolderStatus?) -> Color {
        guard let s else { return .gray }
        if s.listError != nil || s.isEmpty || !s.restores { return .red }
        return .green
    }

    private func headline(_ s: BackupFolderStatus?) -> String {
        guard let s else { return String(localized: "Daily backup: Backups/ not checked yet") }
        if let error = s.listError { return String(localized: "Daily backup: Backups/ could not be read (\(error))") }
        guard let newest = s.newest else { return String(localized: "Daily backup: Backups/ is empty") }
        let day = newest.day.map { $0.start().formatted(date: .abbreviated, time: .omitted) } ?? newest.name
        switch s.newestCheck {
        case .restores(let products)?:
            return String(localized: "Daily backup: \(day), read back (\(products) products)")
        case .fails?, nil:
            return String(localized: "Daily backup: \(day) does not restore")
        }
    }

    private func detail(_ s: BackupFolderStatus?) -> String? {
        guard let s, s.listError == nil else { return nil }
        guard let newest = s.newest else {
            return String(localized: "The run log alone never counts as a backup. The backup job writes a copy and reads it back.")
        }
        var parts = [String(localized: "\(newest.name), \(s.files) in the folder, checked \(s.checkedAt.formatted(date: .omitted, time: .shortened))")]
        if case .fails(let why)? = s.newestCheck { parts.append(why) }
        // Nothing is promised about the next run: it copies the change only while the job is on and automation runs.
        if s.matchesInventory == false { parts.append(String(localized: "The inventory has changed since this copy.")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Dismiss with a reason

struct DeskDismissSheet: View {
    let item: DeskItem
    let dismissWith: (String) -> Bool
    @Environment(\.dismiss) private var close
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dismiss").font(.title3.weight(.semibold))
            Text(DeskText.text(item.title, of: item)).font(.callout)
            Text("Why? The reason is kept with the mark. The item comes back by itself if its fact changes.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Reason", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Dismiss") { if dismissWith(reason) { close() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 440)
        #endif
    }
}

// MARK: - Text helpers

enum DeskText {
    /// PRIORITIES.md lines are Markdown written by people and agents (**bold**, `code`, ~~struck~~) and are shown as
    /// such. Everything else (NEXT-ACTIONS, which is plain text; Brief lines; file paths) is shown exactly as read, so
    /// an underscore, a tilde or an asterisk stays itself.
    static func text(_ s: String, of item: DeskItem) -> AttributedString {
        guard item.kind == .task, case .ledger = item.origin,
              let text = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(s)
        }
        return webLinksOnly(text)
    }

    /// Keeps only http and https links. A ledger line is written by people and agents; a `file://` or custom-scheme
    /// link in it would open a local file or app with one click, so it is shown as plain text.
    static func webLinksOnly(_ input: AttributedString) -> AttributedString {
        var text = input
        let unsafe = text.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? nil : run.range
        }
        for range in unsafe { text[range].link = nil }
        return text
    }

    static func hiddenReason(_ m: DeskMark, of item: DeskItem) -> String {
        let when = m.at.formatted(date: .abbreviated, time: .shortened)
        switch m.kind {
        case .snoozed:
            return String(localized: "Snoozed until \((m.until ?? m.at).formatted(date: .abbreviated, time: .shortened)).")
        case .waiting:
            return String(localized: "Waiting on others since \(when); back when the fact changes.")
        case .dismissed:
            return String(localized: "Dismissed \(when): \(m.reason ?? "")")
        case .done:
            // Done on a fact only says the owner pressed it; whether it is done is for the next reading to show.
            return item.evidence.readAt == nil
                ? String(localized: "You marked it done \(when); hidden until this fact changes, since its source gives no read time.")
                : String(localized: "Done \(when); back if the next reading still shows it.")
        }
    }
}

// MARK: - Settings: Ledger access

/// The one-time grant of the ledger folders (Mac), and what was read from each ledger.
struct LedgerAccessSettingsSection: View {
    @Environment(DeskModel.self) private var model

    var body: some View {
        Section {
            LabeledContent {
                StatusBadge(text: model.grantedFolders.isEmpty ? "Not granted" : "Read-only access", color: model.grantedFolders.isEmpty ? .orange : .green)
            } label: {
                Label("Ledger access", systemImage: "books.vertical")
                Text("The Desk reads the PRIORITIES.md files and the newest NEXT-ACTIONS in these folders, nothing else, and never writes.")
            }
            #if os(macOS)
            ForEach(LedgerAllowList.folders, id: \.self) { folder in
                let granted = model.grantedFolders.contains { "~/\(folder)" == $0 || "~/\(folder)".hasPrefix($0 + "/") }
                LabeledContent {
                    if granted {
                        StatusBadge(text: "Granted", color: .green)
                    } else {
                        HStack(spacing: 8) {
                            // A stored grant that could not be resolved at the last read: kept, and tried again at the next.
                            if model.unresolvedFolders.contains("~/\(folder)") {
                                StatusBadge(text: "Could not be resolved", color: .orange)
                                    .help("The stored grant could not be resolved at the last read. It is kept and tried again at the next read; grant the folder again if this stays.")
                            }
                            Button("Grant…") { model.chooseFolder(suggested: "~/\(folder)") }
                        }
                    }
                } label: {
                    Text(verbatim: "~/\(folder)").font(.callout.monospaced())
                }
            }
            if let reading = model.reading {
                ForEach(model.desk().sources) { source in
                    LabeledContent {
                        Text(verbatim: sourceState(source.state)).font(.caption).foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: source.displayPath).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Text("Read \(reading.readAt.formatted(date: .abbreviated, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Remove access", role: .destructive) { model.revokeFolders() }
                    .disabled(model.grantedFolders.isEmpty)
                Spacer()
                Button {
                    Task { await model.refreshLedgers() }
                } label: {
                    if model.isReading { ProgressView().controlSize(.small) } else { Text("Read now") }
                }
                .disabled(model.isReading)
            }
            #else
            Text("Ledgers are read on the Mac only.").foregroundStyle(.secondary)
            #endif
        } header: {
            Text("Ledger access")
        } footer: {
            Text("~/Projects/Multiplatform is readable through the app's read-only sandbox exception (granted by the owner on 2026-10-19), so no grant is needed. A bookmark grant here still works if that exception is removed. Files outside the allow-list are never opened. Ledgers are read when the app opens and every 30 minutes.")
        }
    }

    private func sourceState(_ state: DeskSourceStatus.State) -> String {
        switch state {
        case .unsupported: String(localized: "Mac only")
        case .notRead: String(localized: "Not read yet")
        case .notGranted: String(localized: "Not granted")
        case .notFound: String(localized: "Not found")
        case .unreadable(let why): String(localized: "Could not read: \(why)")
        case .read(let open, let ticked, let skipped, let reviewed):
            skipped.isEmpty
                ? String(localized: "\(open) open, \(ticked) ticked, reviewed \(reviewed?.description ?? "?")")
                : String(localized: "\(open) open, \(ticked) ticked, reviewed \(reviewed?.description ?? "?"), \(skipped.count) lines set aside")
        case .report(let today, let week, let skipped, let day):
            skipped.isEmpty
                ? String(localized: "\(today) TODAY + \(week) THIS WEEK, report of \(day?.description ?? "?")")
                : String(localized: "\(today) TODAY + \(week) THIS WEEK, report of \(day?.description ?? "?"), \(skipped.count) lines set aside")
        }
    }
}
