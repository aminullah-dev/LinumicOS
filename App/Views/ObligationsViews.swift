import LinumicCore
import SwiftUI

// MARK: - Obligations & accounts screen (تعهدات و حساب‌ها)

extension ObligationLane {
    var color: Color {
        switch self {
        case .overdue: .red
        case .week: .orange
        case .month: .yellow
        case .later: .blue
        case .dateUnknown: .gray
        case .closed: .green
        }
    }

    var symbol: String {
        switch self {
        case .overdue: "exclamationmark.octagon"
        case .week: "calendar.badge.exclamationmark"
        case .month: "calendar"
        case .later: "calendar.badge.clock"
        case .dateUnknown: "questionmark.circle"
        case .closed: "checkmark.circle"
        }
    }
}

extension ObligationOrigin {
    /// Where a row comes from, for its pill. Live rows are read by the app and can't be edited here.
    var label: String {
        switch self {
        case .seed: String(localized: "From the records")
        case .owner: String(localized: "Added by you")
        case .domain: String(localized: "Live: RDAP")
        case .certificate: String(localized: "Live: TLS")
        case .licence: String(localized: "Live: licence ledger")
        case .keys: String(localized: "Live: Keys & Backups")
        case .continuity: String(localized: "Live: continuity log")
        case .account: String(localized: "Account renewal")
        }
    }
}

/// Every dated obligation (and every one whose date is unknown) with what happens if it is missed and where the fact
/// comes from, plus the accounts the company depends on and whose name each is in. Only the owner's entries are saved
/// (obligations.json); a date, a holder or a Done is refused without its source or evidence.
struct ObligationsView: View {
    @Environment(ObligationsModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(MonitorModel.self) private var monitor
    @AppStorage(ObligationsModel.notifyKey) private var notify = true
    @State private var adding = false
    @State private var addingAccount = false
    @State private var completing: Obligation?
    @State private var dating: Obligation?
    @State private var editingAccount: VendorAccount?
    @State private var showLater = true
    @State private var showDone = false
    @State private var highlighted: String?

    var body: some View {
        let now = max(.now, monitor.now)
        let register = model.register(now: now)
        let today = KeyDay(now)
        let lanes = register.lanes(today: today)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(lanes, unread: register.unread, fileUnread: model.loadError != nil)
                    banners(register)
                    ForEach([ObligationLane.overdue, .week, .month], id: \.self) { lane in
                        laneSection(lane, rows: lanes[lane] ?? [], today: today, hideWhenEmpty: lane == .overdue, accounts: register.accounts)
                    }
                    DisclosureGroup(isExpanded: $showLater) {
                        laneRows(lanes[.later] ?? [], lane: .later, today: today, accounts: register.accounts).padding(.top, 8)
                    } label: { laneTitle(.later, count: lanes[.later]?.count ?? 0) }
                    laneSection(.dateUnknown, rows: lanes[.dateUnknown] ?? [], today: today, hideWhenEmpty: false, accounts: register.accounts)
                    if let done = lanes[.closed], !done.isEmpty {
                        DisclosureGroup(isExpanded: $showDone) {
                            laneRows(done, lane: .closed, today: today, accounts: register.accounts).padding(.top, 8)
                        } label: { laneTitle(.closed, count: done.count) }
                    }
                    accountsSection(register.accounts)
                    Text("Seed rows come only from facts recorded with a source (the repository docs, the PRIORITIES files, the newest NEXT-ACTIONS and the memory notes); live rows from what the app reads itself. Nothing here is guessed: an unknown date is its own lane. Your dates, Done marks and accounts are saved in obligations.json on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .onChange(of: router.request, initial: true) {
                switch router.take({ if case .obligation = $0 { true } else if case .completeObligation = $0 { true } else { false } }) {
                case .obligation(let id)?:
                    reveal(id, register: register, today: today, proxy: proxy)
                case .completeObligation(let id)?:
                    // A live row closes only through its source; its Done goes there.
                    if let o = register.obligation(id), !o.isClosed, o.origin.takesDoneHere {
                        completing = o
                    } else if let o = register.obligation(id), !o.origin.takesDoneHere {
                        router.closeAtSource(o.id, destination: o.destination)
                    } else {
                        reveal(id, register: register, today: today, proxy: proxy)
                    }
                default: break
                }
            }
        }
        .navigationTitle(SidebarItem.obligations.title)
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Label("Add obligation", systemImage: "plus") }
                    .help("Add an obligation with its source")
            }
        }
        .sheet(isPresented: $adding) { ObligationAddSheet() }
        .sheet(isPresented: $addingAccount) { AccountAddSheet() }
        .sheet(item: $completing) { ObligationDoneSheet(obligation: $0) }
        .sheet(item: $dating) { ObligationDateSheet(obligation: $0) }
        .sheet(item: $editingAccount) { AccountEditSheet(account: $0) }
        .alert("Not saved", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    // MARK: Parts

    /// The counts by lane. While a live source is unread its rows are missing, and while obligations.json can't be read
    /// your own rows, dates and Done marks are: the counts are then marked partial, so a zero means "none among what
    /// was read", not none.
    private func header(_ lanes: [ObligationLane: [Obligation]], unread: [ObligationLiveSource], fileUnread: Bool) -> some View {
        let partial = !unread.isEmpty || fileUnread
        return VStack(alignment: .leading, spacing: 10) {
            FitRow(spacing: 8) {
                ForEach([ObligationLane.overdue, .week, .month, .dateUnknown], id: \.self) { lane in
                    let count = lanes[lane]?.count ?? 0
                    ReleaseBadge(text: partial ? String(localized: "\(lane.title): \(count) (partial)") : "\(lane.title): \(count)",
                                 symbol: lane.symbol, color: count == 0 ? .gray : lane.color)
                }
                if fileUnread {
                    ReleaseBadge(text: String(localized: "Partial: obligations.json could not be read"), symbol: "exclamationmark.triangle", color: .orange)
                        .help("Your own rows, dates and Done marks are in obligations.json, which could not be read, so they are not counted here.")
                }
                if !unread.isEmpty {
                    ReleaseBadge(text: String(localized: "Partial: some live dates are not read yet"), symbol: "questionmark.circle", color: .orange)
                        .help("The counts leave out the rows of the sources listed below, which have not been read.")
                }
            }
            HStack(spacing: 12) {
                Button { adding = true } label: { Label("Add obligation…", systemImage: "plus.circle") }
                    .buttonStyle(.borderedProminent)
                Button { addingAccount = true } label: { Label("Add account…", systemImage: "person.crop.rectangle.badge.plus") }
                Spacer(minLength: 8)
                Toggle("Notify at 30, 14, 7 and 1 days", isOn: $notify)
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
            }
        }
    }

    @ViewBuilder
    private func banners(_ register: ObligationsRegister) -> some View {
        if let error = model.loadError {
            Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .font(.callout)
        }
        if !register.issues.isEmpty {
            StripeCard(tint: .red) {
                Label("Refused by the register's check", systemImage: "xmark.shield").font(.headline)
                ForEach(register.issues) { issue in
                    Text(verbatim: issue.text).font(.callout)
                }
                Text("A row without a source, or a Done without evidence, is not counted as known or done until it is corrected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !register.unread.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(register.unread, id: \.self) { part in
                    Label { Text(verbatim: part.notReadText) } icon: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func laneTitle(_ lane: ObligationLane, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: lane.symbol).foregroundStyle(lane.color).accessibilityHidden(true)
            Text(verbatim: lane.title).font(.title3.weight(.semibold))
            Text(count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func laneSection(_ lane: ObligationLane, rows: [Obligation], today: KeyDay, hideWhenEmpty: Bool,
                             accounts: [VendorAccount]) -> some View {
        if !(hideWhenEmpty && rows.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                laneTitle(lane, count: rows.count)
                if rows.isEmpty {
                    Text("Nothing here.").font(.callout).foregroundStyle(.secondary)
                } else {
                    laneRows(rows, lane: lane, today: today, accounts: accounts)
                }
            }
        }
    }

    private func laneRows(_ rows: [Obligation], lane: ObligationLane, today: KeyDay, accounts: [VendorAccount]) -> some View {
        StripeCard(tint: lane.color) {
            ForEach(rows) { o in
                ObligationRowView(obligation: o, today: today, highlighted: highlighted == o.id,
                                  done: { completing = o },
                                  setDate: {
                                      // An account's renewal day is recorded on the account, its one place.
                                      if o.origin == .account {
                                          editingAccount = accounts.first { $0.id == o.subject }
                                      } else {
                                          dating = o
                                      }
                                  },
                                  open: { router.open(o.destination) },
                                  closeAtSource: { router.closeAtSource(o.id, destination: o.destination) },
                                  reopen: { model.reopen(o) })
                    .id(o.id)
                if o.id != rows.last?.id { Divider() }
            }
        }
    }

    private func accountsSection(_ accounts: [VendorAccount]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.crop.square.stack").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Accounts").font(.title3.weight(.semibold))
                Text(accounts.count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                let personal = accounts.count { $0.holder == .personal }
                let unknown = accounts.count { $0.holder == nil }
                Text("\(personal) personal, \(unknown) not recorded").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityAddTraits(.isHeader)
            Text("Whose name each account is in. After the company is registered, this is the list of what to move to it.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(accounts) { a in
                    AccountCard(account: a) { editingAccount = a }
                }
            }
        }
    }

    private func reveal(_ id: String, register: ObligationsRegister, today: KeyDay, proxy: ScrollViewProxy) {
        guard let o = register.obligation(id) else { return }
        switch ObligationRules.lane(o, today: today) {
        case .later: showLater = true
        case .closed: showDone = true
        default: break
        }
        highlighted = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            try? await Task.sleep(for: .seconds(3))
            if highlighted == id { highlighted = nil }
        }
    }
}

// MARK: - One obligation

struct ObligationRowView: View {
    let obligation: Obligation
    let today: KeyDay
    let highlighted: Bool
    let done: () -> Void
    let setDate: () -> Void
    let open: () -> Void
    let closeAtSource: () -> Void
    let reopen: () -> Void

    private var o: Obligation { obligation }

    var body: some View {
        let severity = ObligationsBriefRules.severity(o, today: today)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: o.isClosed ? "checkmark.circle.fill" : severity.symbol)
                .foregroundStyle(o.isClosed ? .green : severity.color)
                .accessibilityLabel(Text(verbatim: o.isClosed ? ObligationLane.closed.title : severity.title))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: o.displayTitle).fixedSize(horizontal: false, vertical: true)
                FitRow(spacing: 6) {
                    if let product = o.product {
                        ReleaseBadge(text: product, symbol: "shippingbox", color: .accentColor)
                    }
                    ReleaseBadge(text: o.area.title, symbol: "tag", color: .gray)
                    timingBadge
                    ReleaseBadge(text: o.origin.label, symbol: o.origin.isLive ? "dot.radiowaves.left.and.right" : "doc.text",
                                 color: o.origin.isLive ? .teal : .gray)
                }
                if let consequence = o.displayConsequence {
                    Text("If missed: \(consequence)").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let c = o.completion {
                    Label { Text("Done \(c.on.start().formatted(date: .abbreviated, time: .omitted)): \(c.evidence)") } icon: {
                        Image(systemName: "checkmark.seal").foregroundStyle(.green)
                    }
                    .font(.caption)
                }
                if let dueSource = o.dueSource {
                    Text("Date from: \(dueSource)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                Text(sourceText).font(.caption2).foregroundStyle(.tertiary).lineLimit(4).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(4)
        .background(highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var sourceText: String {
        let recorded = o.recordedOn.map { $0.start().formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "unknown")
        if let read = o.readAt {
            return String(localized: "Source: \(o.source), read \(read.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "Source: \(o.source), recorded \(recorded)")
    }

    @ViewBuilder
    private var timingBadge: some View {
        switch ObligationRules.timing(o, today: today) {
        case .dateUnknown where o.origin == .continuity:
            // No copy off this Mac yet: undated, but due now (P0), not unknown.
            ReleaseBadge(text: String(localized: "To do now"), symbol: "exclamationmark.circle", color: .orange)
        case .dateUnknown:
            ReleaseBadge(text: String(localized: "Date unknown"), symbol: "questionmark.circle", color: .gray)
        case .overdue(let days):
            ReleaseBadge(text: String(localized: "\(dateText) · overdue by \(days) days"), symbol: "exclamationmark.octagon", color: .red)
        case .due(0, _):
            ReleaseBadge(text: String(localized: "\(dateText) · today"), symbol: "calendar.badge.exclamationmark", color: .red)
        case .due(let days, _):
            ReleaseBadge(text: String(localized: "\(dateText) · in \(days) days"), symbol: "calendar",
                         color: days <= 7 ? .orange : (days <= 30 ? .yellow : .blue))
        case .closed:
            ReleaseBadge(text: dateText, symbol: "calendar", color: .green)
        }
    }

    private var dateText: String { o.due.map { $0.start().formatted(date: .abbreviated, time: .omitted) } ?? "" }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if !o.origin.takesDoneHere {
                // A live row closes only when its source records it (an export, a restore test, a renewal the next
                // reading shows): its action is there, never a typed Done.
                sourceAction
            } else if o.isClosed {
                Button(action: reopen) { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .help("Take the Done back (pressed by mistake)")
            } else {
                Button(action: done) { Label("Done…", systemImage: "checkmark") }
                    .help("Record it done with what proves it")
                // An account's renewal opens the account's card: its one place for the day.
                Button(action: setDate) { Label(o.due == nil ? "Set date…" : "Change date…", systemImage: "calendar.badge.plus") }
                    .help(o.origin == .account ? Text("Record the renewal date on the account, with where it comes from")
                                               : Text("Set the due date, with where it comes from"))
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .minTapTarget()
    }

    /// Where a live row is closed: the action of its source.
    @ViewBuilder
    private var sourceAction: some View {
        switch o.origin {
        case .continuity:
            Button(action: closeAtSource) { Label("Export…", systemImage: "lock.doc") }
                .help("It closes when a verified export off this Mac is recorded: this opens Continuity")
        case .keys where o.id.hasPrefix("keys.restore."):
            Button(action: closeAtSource) { Label("Record restore test…", systemImage: "checkmark.shield") }
                .help("It closes when a restore test is recorded in Keys & Backups: this opens it")
        case .keys:
            Button(action: open) { Label("Open", systemImage: "chevron.forward") }
                .help("It closes when Keys & Backups records it: this opens it")
        case .licence:
            Button(action: open) { Label("Open", systemImage: "chevron.forward") }
                .help("It moves when the licence ledger records a renewal: this opens the licence")
        default:
            Button(action: open) { Label("Open", systemImage: "chevron.forward") }
                .help("It moves when the Monitor's next reading shows the new end date: this opens the Monitor")
        }
    }
}

// MARK: - One account

struct AccountCard: View {
    let account: VendorAccount
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: account.name).font(.headline)
                Spacer(minLength: 6)
                holderBadge
            }
            if !account.displayPurpose.isEmpty {
                Text(verbatim: account.displayPurpose).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let renewal = account.renewal {
                Label { Text("Renews \(renewal.start().formatted(date: .abbreviated, time: .omitted))") } icon: { Image(systemName: "arrow.clockwise.circle") }
                    .font(.caption)
            } else if account.hasRecordedTerm {
                // A bill says it renews; the day is not recorded yet (an obligation, "date unknown").
                Label { Text("Renewal date unknown") } icon: { Image(systemName: "questionmark.circle") }
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // No source says it renews at all (a free plan, an ad account): nothing is presumed.
                Label { Text("Renewal: not recorded") } icon: { Image(systemName: "minus.circle") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let cost = account.cost {
                Label { Text(verbatim: cost.text) } icon: { Image(systemName: "banknote") }
                    .font(.caption)
            } else {
                Label { Text("Cost unknown") } icon: { Image(systemName: "questionmark.circle") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = account.holderSource { Text("Holder from: \(s)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled) }
            if let s = account.cost?.source { Text("Cost from: \(s)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled) }
            if let s = account.renewalSource { Text("Renewal from: \(s)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled) }
            Text("Source: \(account.source)").font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Edit…", action: edit).buttonStyle(.borderless).font(.callout)
                    .help("Record its renewal date, whose name it is in or what it costs, with the source")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var holderBadge: some View {
        switch account.holder {
        case .personal?: ReleaseBadge(text: AccountHolder.personal.title, symbol: "person", color: .orange)
        case .company?: ReleaseBadge(text: AccountHolder.company.title, symbol: "building.2", color: .green)
        case nil: ReleaseBadge(text: String(localized: "Holder not recorded"), symbol: "questionmark.circle", color: .gray)
        }
    }
}

// MARK: - Sheets (nothing is saved until Save; each needs its source or evidence)

private func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

struct ObligationAddSheet: View {
    @Environment(ObligationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var product = ""
    @State private var area = ObligationArea.other
    @State private var due: Date?
    /// A day was picked: switching "The due date is known" on starts at today, which is never saved as the due day.
    @State private var duePicked = false
    @State private var consequence = ""
    @State private var source = ""

    private var canSave: Bool { !clean(title).isEmpty && !clean(source).isEmpty && (due == nil || duePicked) }

    var body: some View {
        EditorSheet(title: "Add obligation", canSave: canSave,
                    onCancel: { dismiss() },
                    onSave: {
                        if model.add(title: title, product: product, area: area, due: duePicked ? due.map { KeyDay($0) } : nil,
                                     consequence: consequence, source: source) { dismiss() }
                    }) {
            TextField("What is due", text: $title, axis: .vertical)
            TextField("Product (optional)", text: $product)
            Picker("Area", selection: $area) {
                ForEach(ObligationArea.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            OptionalDatePicker(title: String(localized: "The due date is known"), date: Binding(get: { due }, set: { new in
                // Switched on (nil to today) is not a pick; a change of the day is.
                if due != nil, new != nil { duePicked = true }
                if new == nil { duePicked = false }
                due = new
            }))
            if due != nil, !duePicked {
                Text("Pick the day the source states.").font(.caption).foregroundStyle(.orange)
            }
            TextField("If it is missed (optional)", text: $consequence, axis: .vertical)
            TextField("Source", text: $source, axis: .vertical)
            Text("Required: where this comes from (a file and line, a page, an email, a receipt). Nothing is saved without a source. Leave the date off when it is not known: it then has its own lane.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ObligationDoneSheet: View {
    let obligation: Obligation
    @Environment(ObligationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var evidence = ""

    var body: some View {
        EditorSheet(title: "Done, with evidence", canSave: !clean(evidence).isEmpty,
                    onCancel: { dismiss() },
                    onSave: { if model.complete(obligation, on: KeyDay(date), evidence: evidence) { dismiss() } }) {
            Text(verbatim: obligation.displayTitle).font(.callout.weight(.medium))
            if let due = obligation.due {
                LabeledContent("Due") { Text(due.start().formatted(date: .abbreviated, time: .omitted)) }
            }
            DatePicker("Done on", selection: $date, in: ...Date(), displayedComponents: .date)
            TextField("Evidence", text: $evidence, axis: .vertical)
            Text("Required: what proves it is done (a receipt number, a confirmation email, the store page, a screenshot's name). Done is not saved without it. It holds for this due date only; the next period opens again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ObligationDateSheet: View {
    let obligation: Obligation
    @Environment(ObligationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    /// The picker was used: its first value (today, or the recorded date) is never saved as the day a source states.
    @State private var picked = false
    @State private var source = ""

    private var canSave: Bool { picked && KeyDay(date) != obligation.due && !clean(source).isEmpty }

    var body: some View {
        EditorSheet(title: "Set the due date", canSave: canSave,
                    onCancel: { dismiss() },
                    onSave: { if model.setDate(obligation.id, due: KeyDay(date), source: source) { dismiss() } }) {
            Text(verbatim: obligation.displayTitle).font(.callout.weight(.medium))
            DatePicker("Due", selection: Binding(get: { date }, set: { date = $0; picked = true }), displayedComponents: .date)
            if !picked {
                Text(obligation.due == nil ? "Pick the day the source states." : "Pick the new day the source states.")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField("Source of the date", text: $source, axis: .vertical)
            Text("Required: where the date comes from (the renewal email, the account page). It replaces the recorded date; the record's own source stays shown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if let due = obligation.due { date = due.start() } }
    }
}

struct AccountAddSheet: View {
    @Environment(ObligationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var purpose = ""
    @State private var holder: AccountHolder?
    @State private var source = ""

    var body: some View {
        EditorSheet(title: "Add account", canSave: !clean(name).isEmpty && !clean(source).isEmpty,
                    onCancel: { dismiss() },
                    onSave: { if model.addAccount(name: name, purpose: purpose, holder: holder, source: source) { dismiss() } }) {
            TextField("Name", text: $name)
            TextField("What it is used for", text: $purpose, axis: .vertical)
            Picker("In whose name", selection: $holder) {
                Text("Not recorded").tag(AccountHolder?.none)
                ForEach(AccountHolder.allCases) { Text(verbatim: $0.title).tag(Optional($0)) }
            }
            TextField("Source", text: $source, axis: .vertical)
            Text("Never a password or a card number: the Vault holds sign-ins. Required: where the account is recorded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AccountEditSheet: View {
    let account: VendorAccount
    @Environment(ObligationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renewal: Date?
    /// A day was picked: switching "The renewal date is known" on starts at today, which is never saved as the day.
    @State private var renewalPicked = false
    @State private var renewalSource = ""
    @State private var holder: AccountHolder?
    @State private var holderSource = ""
    @State private var amount = ""
    @State private var currency = ""
    @State private var cycle = BillingCycle.yearly
    @State private var costSource = ""

    /// A new value only: clearing a recorded one is not a change this sheet makes (it would need its own source).
    private var renewalChanged: Bool { renewalPicked && (renewal.map { KeyDay($0) != account.renewal } ?? false) }
    private var holderChanged: Bool { holder != account.holder && holder != nil }
    /// A recorded value was switched off or set back to "Not recorded" in the sheet.
    private var clearing: Bool { (renewal == nil && account.renewal != nil) || (holder == nil && account.holder != nil) }
    /// The amount as typed, in Latin or Persian digits, with "." or "٫" as the decimal mark.
    private var parsedAmount: Decimal? {
        let latin = PaletteText.normalize(clean(amount)).replacingOccurrences(of: "٫", with: ".")
            .replacingOccurrences(of: "٬", with: "").replacingOccurrences(of: ",", with: "")
        // Digits with at most one decimal mark, nothing else: "12abc" is not read as 12.
        guard latin.wholeMatch(of: #/[0-9]+(\.[0-9]+)?/#) != nil else { return nil }
        return Decimal(string: latin, locale: Locale(identifier: "en_US_POSIX"))
    }
    private var cost: AccountCost? {
        guard let value = parsedAmount else { return nil }
        return AccountCost(amount: value, currency: clean(currency), cycle: cycle, source: costSource)
    }
    private var costEntered: Bool { !clean(amount).isEmpty }
    private var canSave: Bool {
        (renewalChanged || holderChanged || costEntered)
            && (!renewalChanged || !clean(renewalSource).isEmpty)
            && (!holderChanged || !clean(holderSource).isEmpty)
            && (!costEntered || (parsedAmount != nil && clean(currency).count == 3 && !clean(costSource).isEmpty))
    }

    var body: some View {
        EditorSheet(title: "Account facts", canSave: canSave,
                    onCancel: { dismiss() },
                    onSave: {
                        let r = renewalChanged ? renewal.map { KeyDay($0) } : nil
                        if model.editAccount(account.id, renewal: r, renewalSource: r == nil ? nil : renewalSource,
                                             holder: holderChanged ? holder : nil, holderSource: holderChanged ? holderSource : nil,
                                             cost: costEntered ? cost : nil) {
                            dismiss()
                        }
                    }) {
            Text(verbatim: account.name).font(.callout.weight(.medium))
            OptionalDatePicker(title: String(localized: "The renewal date is known"), date: Binding(get: { renewal }, set: { new in
                // Switched on (nil to today) is not a pick; a change of the day is.
                if renewal != nil, new != nil { renewalPicked = true }
                if new == nil { renewalPicked = false }
                renewal = new
            }))
            if renewal != nil, !renewalPicked, account.renewal == nil {
                Text("Pick the day the source states.").font(.caption).foregroundStyle(.orange)
            }
            if renewalChanged, renewal != nil {
                TextField("Source of the renewal date", text: $renewalSource, axis: .vertical)
            }
            Picker("In whose name", selection: $holder) {
                Text("Not recorded").tag(AccountHolder?.none)
                ForEach(AccountHolder.allCases) { Text(verbatim: $0.title).tag(Optional($0)) }
            }
            if holderChanged {
                TextField("Source of the holder", text: $holderSource, axis: .vertical)
            }
            Section("Cost, as a bill says it") {
                TextField("Amount", text: $amount)
                TextField("Currency (USD, CAD, AFN)", text: $currency)
                Picker("How often", selection: $cycle) {
                    ForEach(BillingCycle.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                TextField("Source of the cost", text: $costSource, axis: .vertical)
                Text("Leave it empty when no bill says it: an unknown cost stays unknown, never estimated. Amounts in different currencies are never added together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if clearing {
                Text("A recorded value is not removed here: it stays, with its source, until you record a new one.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Each value needs its source (the account page, an invoice). A value already recorded keeps its own source until you replace it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            renewal = account.renewal?.start()
            holder = account.holder
        }
    }
}
