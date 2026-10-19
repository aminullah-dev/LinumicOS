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
                    header(lanes)
                    banners(register)
                    ForEach([ObligationLane.overdue, .week, .month], id: \.self) { lane in
                        laneSection(lane, rows: lanes[lane] ?? [], today: today, hideWhenEmpty: lane == .overdue)
                    }
                    DisclosureGroup(isExpanded: $showLater) {
                        laneRows(lanes[.later] ?? [], lane: .later, today: today).padding(.top, 8)
                    } label: { laneTitle(.later, count: lanes[.later]?.count ?? 0) }
                    laneSection(.dateUnknown, rows: lanes[.dateUnknown] ?? [], today: today, hideWhenEmpty: false)
                    if let done = lanes[.closed], !done.isEmpty {
                        DisclosureGroup(isExpanded: $showDone) {
                            laneRows(done, lane: .closed, today: today).padding(.top, 8)
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
                    if let o = register.obligation(id), !o.isClosed { completing = o } else { reveal(id, register: register, today: today, proxy: proxy) }
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

    private func header(_ lanes: [ObligationLane: [Obligation]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FitRow(spacing: 8) {
                ForEach([ObligationLane.overdue, .week, .month, .dateUnknown], id: \.self) { lane in
                    ReleaseBadge(text: "\(lane.title): \(lanes[lane]?.count ?? 0)", symbol: lane.symbol,
                                 color: (lanes[lane]?.isEmpty ?? true) ? .gray : lane.color)
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
    private func laneSection(_ lane: ObligationLane, rows: [Obligation], today: KeyDay, hideWhenEmpty: Bool) -> some View {
        if !(hideWhenEmpty && rows.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                laneTitle(lane, count: rows.count)
                if rows.isEmpty {
                    Text("Nothing here.").font(.callout).foregroundStyle(.secondary)
                } else {
                    laneRows(rows, lane: lane, today: today)
                }
            }
        }
    }

    private func laneRows(_ rows: [Obligation], lane: ObligationLane, today: KeyDay) -> some View {
        StripeCard(tint: lane.color) {
            ForEach(rows) { o in
                ObligationRowView(obligation: o, today: today, highlighted: highlighted == o.id,
                                  done: { completing = o }, setDate: { dating = o },
                                  open: { router.open(o.destination) }, reopen: { model.reopen(o) })
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
            if o.isClosed {
                Button(action: reopen) { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .help("Take the Done back (pressed by mistake)")
            } else {
                Button(action: done) { Label("Done…", systemImage: "checkmark") }
                    .help("Record it done with what proves it")
                if o.origin.isLive {
                    Button(action: open) { Label("Open", systemImage: "chevron.forward") }
                        .help("Open the screen this date is read from")
                } else {
                    Button(action: setDate) { Label(o.due == nil ? "Set date…" : "Change date…", systemImage: "calendar.badge.plus") }
                        .help("Set the due date, with where it comes from")
                }
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .minTapTarget()
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
            } else {
                Label { Text("Renewal date unknown") } icon: { Image(systemName: "questionmark.circle") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = account.holderSource { Text("Holder from: \(s)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled) }
            if let s = account.renewalSource { Text("Renewal from: \(s)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled) }
            Text("Source: \(account.source)").font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Edit…", action: edit).buttonStyle(.borderless).font(.callout)
                    .help("Record its renewal date or whose name it is in, with the source")
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
    @State private var consequence = ""
    @State private var source = ""

    var body: some View {
        EditorSheet(title: "Add obligation", canSave: !clean(title).isEmpty && !clean(source).isEmpty,
                    onCancel: { dismiss() },
                    onSave: {
                        if model.add(title: title, product: product, area: area, due: due.map { KeyDay($0) },
                                     consequence: consequence, source: source) { dismiss() }
                    }) {
            TextField("What is due", text: $title, axis: .vertical)
            TextField("Product (optional)", text: $product)
            Picker("Area", selection: $area) {
                ForEach(ObligationArea.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            OptionalDatePicker(title: String(localized: "The due date is known"), date: $due)
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
    @State private var source = ""

    var body: some View {
        EditorSheet(title: "Set the due date", canSave: !clean(source).isEmpty,
                    onCancel: { dismiss() },
                    onSave: { if model.setDate(obligation.id, due: KeyDay(date), source: source) { dismiss() } }) {
            Text(verbatim: obligation.displayTitle).font(.callout.weight(.medium))
            DatePicker("Due", selection: $date, displayedComponents: .date)
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
    @State private var renewalSource = ""
    @State private var holder: AccountHolder?
    @State private var holderSource = ""

    private var renewalChanged: Bool { renewal.map { KeyDay($0) } != account.renewal }
    private var holderChanged: Bool { holder != account.holder && holder != nil }
    private var canSave: Bool {
        (renewalChanged || holderChanged)
            && (!renewalChanged || renewal == nil || !clean(renewalSource).isEmpty)
            && (!holderChanged || !clean(holderSource).isEmpty)
    }

    var body: some View {
        EditorSheet(title: "Account facts", canSave: canSave,
                    onCancel: { dismiss() },
                    onSave: {
                        let r = renewalChanged ? renewal.map { KeyDay($0) } : nil
                        if model.editAccount(account.id, renewal: r, renewalSource: r == nil ? nil : renewalSource,
                                             holder: holderChanged ? holder : nil, holderSource: holderChanged ? holderSource : nil) {
                            dismiss()
                        }
                    }) {
            Text(verbatim: account.name).font(.callout.weight(.medium))
            OptionalDatePicker(title: String(localized: "The renewal date is known"), date: $renewal)
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
            Text("Each value needs its source (the account page, an invoice). A value already recorded keeps its own source until you replace it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            renewal = account.renewal?.start()
            holder = account.holder
        }
    }
}
