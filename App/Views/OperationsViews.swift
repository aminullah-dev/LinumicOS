import LinumicCore
import SwiftUI

// Operations (عملیات): Talar, SafeBeauty and VELRO admin overviews in one screen with a tab per product.
// Read-only, except Talar's audited hall approve/reject. Every other action opens the product's own admin console.

// MARK: - Small pieces

enum OpsEnvironmentStyle {
    case production, test, local

    var look: (symbol: String, color: Color) {
        switch self {
        case .production: ("exclamationmark.shield.fill", .red)
        case .test: ("theatermasks", .blue)
        case .local: ("hammer", .gray)
        }
    }
}

/// Production in red, so real data never looks like a test. Icon + text, never colour alone.
struct OpsEnvironmentBadge: View {
    let title: String
    let style: OpsEnvironmentStyle

    init(_ talar: TalarEnvironment) {
        title = talar.title
        style = talar == .production ? .production : talar == .demo ? .test : .local
    }

    init(_ safeBeauty: SafeBeautyEnvironment) {
        title = safeBeauty.title
        style = safeBeauty == .production ? .production : safeBeauty == .staging ? .test : .local
    }

    init(_ velro: VelroEnvironment) {
        title = velro.title
        style = velro == .production ? .production : .local
    }

    /// From an `OperationsCount.environment` raw value.
    init(rawEnvironment: String) {
        switch rawEnvironment {
        case "production": title = String(localized: "Production"); style = .production
        case "demo": title = String(localized: "Demo"); style = .test
        case "staging": title = String(localized: "Staging"); style = .test
        case "localBackend": title = String(localized: "Local backend"); style = .local
        default: title = String(localized: "Local emulator"); style = .local
        }
    }

    var body: some View {
        let l = style.look
        HStack(spacing: 4) {
            Image(systemName: l.symbol).foregroundStyle(l.color)
            Text(verbatim: title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(l.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(l.color.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Environment: \(title)"))
    }
}

/// A number with its label; the label and value are read together by VoiceOver.
struct OpsMetric: View {
    let title: LocalizedStringKey
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Read from <source> at <time>" under every block of numbers.
struct OpsReadLine: View {
    let source: String
    let at: Date?
    var isRefreshing = false

    var body: some View {
        Group {
            if isRefreshing {
                Label("Reading…", systemImage: "arrow.triangle.2.circlepath")
            } else if let at {
                Label("Read from \(source) at \(at.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}

/// Opens the product's own admin console for any action.
struct OpsPanelLink: View {
    let url: URL?
    let product: String

    var body: some View {
        if let url {
            Link(destination: url) {
                Label("Open \(product) admin panel", systemImage: "arrow.up.forward.app")
            }
            .help(Text(verbatim: url.absoluteString))
        } else {
            Label("No admin panel link for this environment", systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
        }
    }
}

enum OpsRoute: Hashable {
    case talarHall(String)
    case safeBeautyPerson(id: String, kyc: Bool)
    case velroDriver(String)
    case velroStations
    case velroRoutes
}

// MARK: - Screen

struct OperationsView: View {
    @Environment(Router.self) private var router
    @State private var path: [OpsRoute] = []

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $path) {
            Group {
                switch router.operationsTab {
                case .talar: TalarPane()
                case .safeBeauty: SafeBeautyPane()
                case .velro: VelroPane()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Product", selection: $router.operationsTab) {
                    ForEach(OperationsProduct.allCases) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Operations")
            .navigationDestination(for: OpsRoute.self) { route in
                switch route {
                case .talarHall(let id): TalarHallView(hallID: id)
                case .safeBeautyPerson(let id, let kyc): SafeBeautyPersonView(personID: id, kyc: kyc)
                case .velroDriver(let id): VelroDriverView(driverID: id)
                case .velroStations: VelroStationsView()
                case .velroRoutes: VelroRoutesView()
                }
            }
        }
        .onChange(of: router.operationsTab) { path = [] }
    }
}

/// Shared signed-out state.
private struct OpsSignedOut: View {
    let product: String
    let detail: LocalizedStringKey
    let error: String?
    let signIn: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Not signed in to \(product)", systemImage: "person.badge.key")
        } description: {
            Text(detail)
        } actions: {
            Button("Sign In…", action: signIn).buttonStyle(.borderedProminent)
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// Refresh + account menu, shared by the three panes.
private struct OpsToolbar: ToolbarContent {
    let isRefreshing: Bool
    let refresh: () -> Void
    let switchAccount: () -> Void
    let signOut: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(isRefreshing)
                .help("Read again (read-only)")
        }
        ToolbarItem {
            Menu {
                Button(action: switchAccount) { Label("Switch Account or Environment…", systemImage: "arrow.left.arrow.right") }
                Button(role: .destructive, action: signOut) { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
            } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
    }
}

private func shortDate(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .omitted) ?? "—" }

// MARK: - Talar

struct TalarPane: View {
    @Environment(OperationsModel.self) private var ops
    @State private var isSigningIn = false
    @State private var confirmSignOut = false

    private var talar: TalarModel { ops.talar }

    var body: some View {
        Group {
            if talar.isSignedIn { content } else {
                OpsSignedOut(product: "Talar",
                             detail: "Sign in with a dedicated Talar platform admin account (role \"admin\") to see the hall approval queue, reviews awaiting moderation and settlement status. The password goes to Firebase once and is not stored; only a refresh token is kept in this device's Keychain.",
                             error: talar.loadError) { isSigningIn = true }
            }
        }
        .toolbar {
            if talar.isSignedIn {
                OpsToolbar(isRefreshing: talar.isRefreshing, refresh: { Task { await talar.refresh() } },
                           switchAccount: { isSigningIn = true }, signOut: { confirmSignOut = true })
            }
        }
        .sheet(isPresented: $isSigningIn) { TalarSignInSheet() }
        .confirmationDialog("Sign out of Talar?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { talar.signOut() }
        } message: {
            Text("The refresh token is removed from this device's Keychain. Talar itself is not changed.")
        }
    }

    private var content: some View {
        List {
            Section { overview }
            if let error = talar.loadError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section {
                if talar.halls.isEmpty {
                    Text(talar.lastRead == nil ? "Not read yet." : "No hall is waiting for approval.").foregroundStyle(.secondary)
                } else {
                    ForEach(talar.halls) { h in
                        NavigationLink(value: OpsRoute.talarHall(h.id)) { TalarHallRow(hall: h, organization: talar.organizationName(h.orgId)) }
                    }
                }
            } header: {
                Text("Halls awaiting approval")
            } footer: {
                Text("GET /admin/halls/pending: status pending_review, up to 50, as Talar returns them.")
            }
            Section {
                if talar.reviews.isEmpty {
                    Text(talar.lastRead == nil ? "Not read yet." : "No review is waiting for moderation.").foregroundStyle(.secondary)
                } else {
                    ForEach(talar.reviews) { r in TalarReviewRow(review: r) }
                }
            } header: {
                Text("Reviews awaiting moderation")
            } footer: {
                Text("Read-only here. Publish or reject reviews in the Talar admin panel.")
            }
            settlements
            if !talar.actions.isEmpty {
                OpsActionsSection(records: Array(talar.actions.prefix(10)))
            }
            Section { OpsPanelLink(url: talar.environment?.adminPanel, product: "Talar") }
        }
        .refreshable { await talar.refresh() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let env = talar.environment, let s = talar.session {
                FitRow(spacing: 8) {
                    OpsEnvironmentBadge(env)
                    Text("Signed in as \(s.email)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let d = talar.dashboard {
                FitRow(spacing: 18) {
                    OpsMetric(title: "Halls to approve", value: "\(d.hallsAwaitingReview)", tint: d.hallsAwaitingReview > 0 ? .orange : .primary)
                    OpsMetric(title: "Reviews to moderate", value: "\(talar.reviews.count)", tint: talar.reviews.isEmpty ? .primary : .orange)
                    OpsMetric(title: "Published halls", value: "\(d.publishedHalls)")
                    OpsMetric(title: "Confirmed bookings", value: "\(d.confirmedBookings)")
                    OpsMetric(title: "Open tickets", value: "\(d.openTickets)")
                    Spacer(minLength: 0)
                }
            }
            if let env = talar.environment {
                OpsReadLine(source: env.apiBase.absoluteString + "/admin", at: talar.lastRead, isRefreshing: talar.isRefreshing)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var settlements: some View {
        Section {
            if let error = talar.payoutError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let s = talar.payoutSummary {
                LabeledContent("Pending settlements") {
                    Text(verbatim: "\(s.pendingCount) · \(TalarMoney.format(s.pendingNetMinor, currency: "AFN"))").monospacedDigit()
                }
                LabeledContent("Organisations read") {
                    Text(verbatim: s.organizationsFailed > 0 ? "\(s.organizationsRead) (+\(s.organizationsFailed) ✕)" : "\(s.organizationsRead)").monospacedDigit()
                }
                if s.truncated {
                    Text("Only the first \(TalarAdminClient.organizationLimit) active organisations were read.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(talar.payouts.filter { !$0.pending.isEmpty || $0.error != nil }) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.organization.name).fontWeight(.medium)
                        if let e = row.error {
                            Text(verbatim: e).font(.caption).foregroundStyle(.red)
                        } else {
                            ForEach(row.pending) { p in
                                Text("Pending to \(p.periodTo ?? "—"): net \(TalarMoney.format(p.netMinor, currency: p.currency)) (gross \(TalarMoney.format(p.grossMinor, currency: p.currency)), commission \(TalarMoney.format(p.commissionMinor, currency: p.currency)), \(p.paymentCount) payments)")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text("Not read yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Settlements")
        } footer: {
            Text("Per organisation from GET /orgs/:id/payments/payouts. Running a settlement and marking a payout paid move money and are not idempotent in Talar, so they stay in the web panel.")
        }
    }
}

private struct TalarHallRow: View {
    let hall: TalarHall
    let organization: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: hall.name.best()).fontWeight(.medium)
            Text(verbatim: [hall.cityId, hall.hallType, hall.capacity.map { String(localized: "\($0.total) guests") }, organization]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let at = hall.createdAt?.date {
                Text("Submitted \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct TalarReviewRow: View {
    let review: TalarReview

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: String(repeating: "★", count: max(0, min(review.rating, 5))) + String(repeating: "☆", count: max(0, 5 - review.rating)))
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Rating \(review.rating) of 5"))
                Text(verbatim: review.hallId ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let t = review.text, !t.isEmpty { Text(verbatim: t).font(.callout).lineLimit(3) }
            Text(verbatim: shortDate(review.createdAt?.date)).font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TalarHallView: View {
    let hallID: String
    @Environment(OperationsModel.self) private var ops
    @State private var decision: TalarHallDecision?

    var body: some View {
        Form {
            if let h = ops.talar.hall(hallID) {
                Section {
                    LabeledContent("Name (Dari)") { Text(verbatim: h.name.values["fa"] ?? "—") }
                    LabeledContent("Name (Pashto)") { Text(verbatim: h.name.values["ps"] ?? "—") }
                    LabeledContent("Name (English)") { Text(verbatim: h.name.values["en"] ?? "—") }
                    LabeledContent("Organisation") { Text(verbatim: ops.talar.organizationName(h.orgId) ?? h.orgId ?? "—") }
                    LabeledContent("City") { Text(verbatim: [h.cityId, h.district].compactMap { $0 }.joined(separator: " · ")) }
                    LabeledContent("Type") { Text(verbatim: h.hallType ?? "—") }
                    if let c = h.capacity {
                        LabeledContent("Capacity") { Text("\(c.total) total · \(c.mens ?? 0) men · \(c.womens ?? 0) women").monospacedDigit() }
                    }
                    LabeledContent("Shifts") { Text(verbatim: h.shifts.joined(separator: ", ")) }
                    if let fee = h.hallFeeMinor { LabeledContent("Hall fee") { Text(verbatim: TalarMoney.format(fee, currency: h.currency ?? "AFN")).monospacedDigit() } }
                    if let dep = h.depositPct { LabeledContent("Deposit") { Text(verbatim: "\(dep)%") } }
                    if let instant = h.instantBooking { LabeledContent("Instant booking") { Text(instant ? "Yes" : "No") } }
                    if !h.amenities.isEmpty { LabeledContent("Amenities") { Text(verbatim: h.amenities.joined(separator: ", ")).multilineTextAlignment(.trailing) } }
                    ForEach(Array(h.refundRules.enumerated()), id: \.offset) { _, r in
                        LabeledContent("Refund rule") { Text("\(r.refundPct)% if cancelled \(r.minDaysBefore)+ days before") }
                    }
                    LabeledContent("Submitted") { Text(verbatim: h.createdAt?.date.formatted(date: .abbreviated, time: .shortened) ?? "—") }
                    LabeledContent("Hall id") { Text(verbatim: ltr(h.id)).font(.body.monospaced()).textSelection(.enabled) }
                } header: {
                    Text("Awaiting review")
                } footer: {
                    Text("Photos, menus and packages are in the Talar admin panel.")
                }
                Section {
                    HStack {
                        Button { decision = .approve } label: { Label("Approve…", systemImage: "checkmark.circle") }
                        Button(role: .destructive) { decision = .reject } label: { Label("Reject…", systemImage: "xmark.circle") }
                    }
                } footer: {
                    Text("Approve publishes the hall; reject returns it to draft. Talar records the decision in its audit log. It does not notify the owner, so tell them yourself.")
                }
                Section { OpsPanelLink(url: ops.talar.environment?.adminPanel, product: "Talar") }
            } else {
                Section { Text("This hall is no longer in the queue.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: ops.talar.hall(hallID)?.name.best() ?? hallID))
        .sheet(item: $decision) { d in
            if let h = ops.talar.hall(hallID) { TalarReviewSheet(hall: h, decision: d) }
        }
    }
}

/// Confirms one hall decision. Production needs the hall's name typed; the request is sent once.
struct TalarReviewSheet: View {
    let hall: TalarHall
    let decision: TalarHallDecision
    @Environment(OperationsModel.self) private var ops
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var typed = ""
    @State private var checked = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: OperationsActionRecord?

    private var isProduction: Bool { ops.talar.environment?.isProduction == true }
    private var name: String { hall.name.best() }
    private var confirmed: Bool {
        isProduction ? typed.trimmingCharacters(in: .whitespacesAndNewlines) == name.trimmingCharacters(in: .whitespacesAndNewlines) : checked
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(decision == .approve ? "Approve hall" : "Reject hall").font(.headline).padding()
            Form {
                if let result {
                    Section {
                        switch result.outcome {
                        case .verified: Label("Done. Read back from Talar: the hall has left the queue.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        case .unverified: Label(result.message ?? String(localized: "Sent, not verified."), systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
                        case .failed: Label(result.message ?? "", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        Text("Recorded in this device's action log; Talar wrote its own audit entry.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        LabeledContent("Hall") { Text(verbatim: name) }
                        LabeledContent("Environment") { if let env = ops.talar.environment { OpsEnvironmentBadge(env) } }
                        LabeledContent("Status") { Text(verbatim: "pending_review → \(decision == .approve ? "published" : "draft")") }
                        if isProduction {
                            Label("This changes a real hall in production.", systemImage: "exclamationmark.shield.fill").font(.callout).foregroundStyle(.red)
                        }
                    }
                    Section {
                        TextField(decision == .approve ? "Note (optional)" : "Reason (optional, shown to nobody automatically)", text: $reason, axis: .vertical)
                            .lineLimit(2...5)
                        Text("\(reason.count) / \(TalarHallReviewWrite.maxReason)").font(.caption).foregroundStyle(reason.count > TalarHallReviewWrite.maxReason ? .red : .secondary).monospacedDigit()
                    } footer: {
                        Text("Stored on the hall as reviewNote. Talar's audit entry doesn't include it.")
                    }
                    Section {
                        if isProduction {
                            TextField("Type the hall name to confirm", text: $typed).autocorrectionDisabled()
                            Text("Type: \(name)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Toggle("I've checked the hall above", isOn: $checked)
                        }
                    } header: {
                        Text("Confirm")
                    }
                    if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
                }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                if result != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                    Button(decision == .approve ? "Approve" : "Reject", role: decision == .reject ? .destructive : nil) { Task { await send() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !confirmed || reason.count > TalarHallReviewWrite.maxReason)
                }
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    private func send() async {
        guard !isWorking, confirmed else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            let write = try TalarHallReviewWrite.make(decision: decision, reason: reason)
            result = try await ops.talar.review(hall, write: write)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct OpsActionsSection: View {
    let records: [OperationsActionRecord]

    var body: some View {
        Section {
            ForEach(records) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        switch r.outcome {
                        case .verified: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(Text("Verified"))
                        case .unverified: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).accessibilityLabel(Text("Not verified"))
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel(Text("Failed"))
                        }
                        Text(verbatim: r.targetName).fontWeight(.medium)
                        OpsEnvironmentBadge(rawEnvironment: r.environment)
                    }
                    Text(verbatim: "\(r.action) · \(r.actor) · \(r.at.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if let m = r.message { Text(verbatim: m).font(.caption).foregroundStyle(r.outcome == .verified ? Color.secondary : .red) }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Sent from Linumic OS")
        } footer: {
            Text("This device's own log of decisions sent (operations-actions.json, never deleted).")
        }
    }
}

struct TalarSignInSheet: View {
    @Environment(OperationsModel.self) private var ops
    @Environment(\.dismiss) private var dismiss
    @State private var environment: TalarEnvironment = .production
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Sign In to Talar").font(.headline).padding()
            Form {
                Section {
                    Picker("Environment", selection: $environment) {
                        ForEach(TalarModel.offeredEnvironments) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(verbatim: environment.apiBase.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                    if environment.isProduction {
                        Label("Production holds real halls. Approving or rejecting a hall here changes it.", systemImage: "exclamationmark.shield.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("A Talar platform admin account (Firebase email and password with the role \"admin\" claim). Use one that owns no organisation: creating or joining one replaces the claim. The password goes to Firebase once and is not stored.")
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") { Task { await signIn() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
        .onAppear { if let s = ops.talar.session { environment = s.environment; email = s.email } }
    }

    private func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await ops.talar.signIn(environment: environment, email: email, password: password)
            password = ""
            dismiss()
        } catch {
            password = ""
            self.error = error.localizedDescription
        }
    }
}

// MARK: - SafeBeauty

struct SafeBeautyPane: View {
    @Environment(OperationsModel.self) private var ops
    @State private var isSigningIn = false
    @State private var confirmSignOut = false

    private var sb: SafeBeautyModel { ops.safeBeauty }

    var body: some View {
        Group {
            if sb.isSignedIn { content } else {
                OpsSignedOut(product: "SafeBeauty",
                             detail: "Sign in with your SafeBeauty admin phone number and password to see the identity (KYC) queue, salon owners awaiting approval, bookings, payouts owed and the commission. Identity documents are never downloaded. Neither the phone number nor the password is stored; only a refresh token is kept in this device's Keychain.",
                             error: sb.loadError) { isSigningIn = true }
            }
        }
        .toolbar {
            if sb.isSignedIn {
                OpsToolbar(isRefreshing: sb.isRefreshing, refresh: { Task { await sb.refresh() } },
                           switchAccount: { isSigningIn = true }, signOut: { confirmSignOut = true })
            }
        }
        .sheet(isPresented: $isSigningIn) { SafeBeautySignInSheet() }
        .confirmationDialog("Sign out of SafeBeauty?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { sb.signOut() }
        } message: {
            Text("The refresh token is removed from this device's Keychain. SafeBeauty itself is not changed.")
        }
    }

    private var content: some View {
        List {
            Section { overview }
            if let error = sb.loadError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if let s = sb.snapshot {
                queue(title: "Identity checks (KYC) to review", people: s.kycQueue, total: s.kycPendingCount, kyc: true,
                      footer: "users where kycStatus is PENDING. Name, role and status only: tazkira numbers, photos and selfies are reviewed only in the SafeBeauty admin console.")
                queue(title: "Salon owners awaiting approval", people: s.approvalQueue, total: s.approvalPendingCount, kyc: false,
                      footer: "users where status is PENDING (the console's Approvals tab).")
                Section {
                    LabeledContent("Today") { Text(verbatim: "\(s.bookingsToday)").monospacedDigit() }
                    LabeledContent("This week") { Text(verbatim: "\(s.bookingsThisWeek)").monospacedDigit() }
                } header: {
                    Text("Bookings")
                } footer: {
                    Text("Appointments scheduled in Kabul's day and in the week from Saturday \(s.week.start.formatted(date: .abbreviated, time: .omitted)), any status (appointmentDate).")
                }
                Section {
                    LabeledContent("Salons") { Text("\(s.salonCount) (\(s.verifiedSalonCount) verified)").monospacedDigit() }
                    LabeledContent("Payouts owed to salons") { Text(verbatim: "\(s.payoutsOwed.count) · \(s.payoutsOwedTotal.formatted()) AFN").monospacedDigit() }
                    ForEach(s.payoutsOwed.prefix(20)) { b in
                        LabeledContent {
                            Text(verbatim: "\(b.owedAmount.formatted()) AFN").monospacedDigit()
                        } label: {
                            Text(verbatim: b.name ?? b.providerID).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Refund requests pending") { Text(verbatim: "\(s.refundRequestsPending)").monospacedDigit() }
                } header: {
                    Text("Salons and money")
                } footer: {
                    Text("provider_balances above zero (the platform owes the salon) and refund_requests PENDING. Mark payouts paid only in the admin console: SafeBeauty doesn't audit that action.")
                }
                Section {
                    LabeledContent("Commission applied") { Text(verbatim: "\(s.commission.effectivePercent.formatted())%").monospacedDigit() }
                    LabeledContent("Stored value") {
                        Text(verbatim: s.commission.storedPercent.map { "\($0.formatted())%" } ?? String(localized: "not set (default 10%)"))
                    }
                    if s.commission.storedIsIgnored {
                        Label("The stored value is outside 0–100, so SafeBeauty uses its default of 10%.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    LabeledContent("Largest discount allowed") { Text(verbatim: "\(Int((s.commission.effectiveMaxDiscountFraction * 100).rounded()))%").monospacedDigit() }
                } header: {
                    Text("Commission (read only)")
                } footer: {
                    Text("platform_config/general, interpreted the way the server does (payments.js getCommissionPercent). Change it only in the admin console.")
                }
            }
            Section { OpsPanelLink(url: sb.environment?.adminPanel, product: "SafeBeauty") }
        }
        .refreshable { await sb.refresh() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let env = sb.environment, let s = sb.session {
                FitRow(spacing: 8) {
                    OpsEnvironmentBadge(env)
                    Text("Signed in as \(s.name.isEmpty ? s.appUID : s.name)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let s = sb.snapshot {
                FitRow(spacing: 18) {
                    OpsMetric(title: "KYC to review", value: "\(s.kycPendingCount)", tint: s.kycPendingCount > 0 ? .orange : .primary)
                    OpsMetric(title: "Approvals", value: "\(s.approvalPendingCount)", tint: s.approvalPendingCount > 0 ? .orange : .primary)
                    OpsMetric(title: "Bookings today", value: "\(s.bookingsToday)")
                    OpsMetric(title: "This week", value: "\(s.bookingsThisWeek)")
                    OpsMetric(title: "Commission", value: "\(s.commission.effectivePercent.formatted())%")
                    Spacer(minLength: 0)
                }
            }
            if let env = sb.environment {
                OpsReadLine(source: env.firestore.documents.host ?? "Firestore", at: sb.lastRead, isRefreshing: sb.isRefreshing)
            }
        }
        .padding(.vertical, 4)
    }

    private func queue(title: LocalizedStringKey, people: [SafeBeautyPerson], total: Int, kyc: Bool, footer: LocalizedStringKey) -> some View {
        Section {
            if people.isEmpty {
                Text("Nobody is waiting.").foregroundStyle(.secondary)
            } else {
                ForEach(people) { p in
                    NavigationLink(value: OpsRoute.safeBeautyPerson(id: p.id, kyc: kyc)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: p.name.isEmpty ? String(localized: "(no name)") : p.name).fontWeight(.medium)
                                Text(verbatim: "\(p.role) · \(kyc ? p.kycStatus : p.status)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(verbatim: shortDate(p.joined)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if total > people.count {
                    Text("Showing \(people.count) of \(total).").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

struct SafeBeautyPersonView: View {
    let personID: String
    let kyc: Bool
    @Environment(OperationsModel.self) private var ops

    private var person: SafeBeautyPerson? {
        guard let s = ops.safeBeauty.snapshot else { return nil }
        return (kyc ? s.kycQueue : s.approvalQueue).first { $0.id == personID }
    }

    var body: some View {
        Form {
            if let p = person {
                Section {
                    LabeledContent("Name") { Text(verbatim: p.name.isEmpty ? "—" : p.name) }
                    LabeledContent("Role") { Text(verbatim: p.role) }
                    LabeledContent("Account status") { Text(verbatim: p.status) }
                    LabeledContent("Identity check (KYC)") { Text(verbatim: p.kycStatus) }
                    LabeledContent("Joined") { Text(verbatim: p.joined?.formatted(date: .abbreviated, time: .omitted) ?? "—") }
                    LabeledContent("Account id") { Text(verbatim: ltr(p.id)).font(.body.monospaced()).textSelection(.enabled) }
                } footer: {
                    Text(kyc ? "The tazkira and selfie are not downloaded to this device. Review them, and approve or reject, in the SafeBeauty admin console (KYC tab)."
                             : "Approve or reject in the SafeBeauty admin console (Approvals tab). SafeBeauty doesn't audit that change, so it isn't offered here.")
                }
                Section { OpsPanelLink(url: ops.safeBeauty.environment?.adminPanel, product: "SafeBeauty") }
            } else {
                Section { Text("No longer in the queue.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: person?.name ?? personID))
    }
}

struct SafeBeautySignInSheet: View {
    @Environment(OperationsModel.self) private var ops
    @Environment(\.dismiss) private var dismiss
    @State private var environment: SafeBeautyEnvironment = .production
    @State private var phone = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Sign In to SafeBeauty").font(.headline).padding()
            Form {
                Section {
                    Picker("Environment", selection: $environment) {
                        ForEach(SafeBeautyModel.offeredEnvironments) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(verbatim: environment.functionsBase.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                    if environment == .staging {
                        Text("Staging needs its own admin account, and whether its functions are deployed is unverified.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Phone number", text: $phone)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        #endif
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("The same phone and password as the SafeBeauty admin console. 0700…, 700… and +93700… all work; an international number needs its +. SafeBeauty allows 10 attempts per number every 15 minutes. Nothing typed here is stored.")
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") { Task { await signIn() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || phone.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
        .onAppear { if let s = ops.safeBeauty.session { environment = s.environment } }
    }

    private func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await ops.safeBeauty.signIn(environment: environment, phone: phone, password: password)
            phone = ""
            password = ""
            dismiss()
        } catch {
            password = ""
            self.error = error.localizedDescription
        }
    }
}

// MARK: - VELRO

struct VelroPane: View {
    @Environment(OperationsModel.self) private var ops
    @State private var isSigningIn = false
    @State private var confirmSignOut = false

    private var velro: VelroModel { ops.velro }

    var body: some View {
        Group {
            if velro.isSignedIn { content } else {
                OpsSignedOut(product: "VELRO",
                             detail: "Sign in with your VELRO staff phone number: VELRO sends a code, you type it here. See drivers awaiting approval, trips, stations, routes and the commission. Read-only: VELRO has no staging, so every action stays in the web console. The phone number is not stored.",
                             error: velro.loadError) { isSigningIn = true }
            }
        }
        .toolbar {
            if velro.isSignedIn {
                OpsToolbar(isRefreshing: velro.isRefreshing, refresh: { Task { await velro.refresh() } },
                           switchAccount: { isSigningIn = true }, signOut: { confirmSignOut = true })
            }
        }
        .sheet(isPresented: $isSigningIn) { VelroSignInSheet() }
        .confirmationDialog("Sign out of VELRO?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { velro.signOut() }
        } message: {
            Text("The session is removed from this device's Keychain. Your other VELRO sessions (the web console) are not affected.")
        }
    }

    private var content: some View {
        List {
            Section { overview }
            if let error = velro.loadError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section {
                if let d = velro.drivers {
                    if d.items.isEmpty { Text("No driver is waiting for approval.").foregroundStyle(.secondary) }
                    ForEach(d.items) { driver in
                        NavigationLink(value: OpsRoute.velroDriver(driver.id)) { VelroDriverRow(driver: driver) }
                    }
                    if d.total > d.items.count { Text("Showing \(d.items.count) of \(d.total).").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Not read yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Drivers awaiting approval")
            } footer: {
                if let a = velro.dashboard?.attention {
                    Text("Documents waiting for review: \(a.pendingDocuments) · vehicles: \(a.pendingVehicles) · documents expiring soon: \(a.expiringDocuments). Review and approve in the VELRO web console.")
                }
            }
            tripsSection(title: "Trips under way", page: velro.activeTrips, empty: "No trip is under way.")
            tripsSection(title: "Departing in the next 24 hours", page: velro.upcomingTrips, empty: "No departure in the next 24 hours.")
            Section {
                NavigationLink(value: OpsRoute.velroStations) {
                    LabeledContent("Stations") { Text(verbatim: velro.stations.map { "\($0.total)" } ?? "—").monospacedDigit() }
                }
                NavigationLink(value: OpsRoute.velroRoutes) {
                    LabeledContent("Routes (corridors)") { Text(verbatim: velro.routes.map { "\($0.total)" } ?? "—").monospacedDigit() }
                }
                if let n = velro.dashboard?.network, n.stationsWithoutRoutes > 0 {
                    LabeledContent("Stations no active route leaves from") { Text(verbatim: "\(n.stationsWithoutRoutes)").monospacedDigit() }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("VELRO has no separate corridor entity; routes (station to destination, generated from route templates) are the corridors.")
            }
            Section {
                if let c = velro.commission {
                    LabeledContent("Commission") {
                        Text(verbatim: c.basisPoints.map { "\((Double($0) / 100).formatted())% (\($0) basis points)" } ?? String(localized: "not set (default 10%)")).monospacedDigit()
                    }
                    if c.isOutOfRange {
                        Label("Outside 0–10000: VELRO refuses every trip completion with this value.", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                } else if let e = velro.commissionError {
                    Text(verbatim: e).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Commission (read only)")
            } footer: {
                Text("commission.rate_basis_points from GET /admin/settings, read at each trip completion. Change it only in the VELRO web console.")
            }
            Section { OpsPanelLink(url: velro.environment?.adminPanel, product: "VELRO") }
        }
        .refreshable { await velro.refresh() }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let env = velro.environment, let s = velro.session {
                FitRow(spacing: 8) {
                    OpsEnvironmentBadge(env)
                    Text(verbatim: s.roles.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let d = velro.dashboard {
                FitRow(spacing: 18) {
                    OpsMetric(title: "Drivers to approve", value: "\(d.attention.pendingDrivers)", tint: d.attention.pendingDrivers > 0 ? .orange : .primary)
                    OpsMetric(title: "Trips under way", value: "\(d.activeTrips)")
                    OpsMetric(title: "Trips today", value: "\(d.today.trips)")
                    OpsMetric(title: "Completed today", value: "\(d.today.completedTrips)")
                    OpsMetric(title: "Bookings today", value: "\(d.today.bookings)")
                    Spacer(minLength: 0)
                }
                Text("Today's commission \(VelroMoney.format(d.finance.commissionTodayMinor, currency: d.finance.currency)) of \(VelroMoney.format(d.finance.revenueTodayMinor, currency: d.finance.currency)) in fares · drivers online \(d.drivers.online) of \(d.drivers.total)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let env = velro.environment {
                OpsReadLine(source: env.apiBase.absoluteString + "/admin", at: velro.lastRead, isRefreshing: velro.isRefreshing)
            }
        }
        .padding(.vertical, 4)
    }

    private func tripsSection(title: LocalizedStringKey, page: VelroPage<VelroTrip>?, empty: LocalizedStringKey) -> some View {
        Section {
            if let page {
                if page.items.isEmpty { Text(empty).foregroundStyle(.secondary) }
                ForEach(page.items) { t in VelroTripRow(trip: t) }
                if page.total > page.items.count { Text("Showing \(page.items.count) of \(page.total).").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Not read yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        }
    }
}

private struct VelroDriverRow: View {
    let driver: VelroDriver

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: driver.fullName ?? String(localized: "(no name yet)")).fontWeight(.medium)
            Text(verbatim: [driver.approvalStatus, driver.plateNumber.map { ltr($0) }, driver.vehicleStatus].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VelroTripRow: View {
    let trip: VelroTrip

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(trip.originStationName) → \(trip.destinationName)").font(.callout)
                Text(verbatim: [ltr(trip.number), trip.status, trip.driverName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: trip.departure?.formatted(date: .omitted, time: .shortened) ?? "—").monospacedDigit()
                Text("\(trip.bookedSeats)/\(trip.seatCapacity) seats").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct VelroDriverView: View {
    let driverID: String
    @Environment(OperationsModel.self) private var ops
    @State private var checklist: VelroDocumentChecklist?
    @State private var error: String?

    private var driver: VelroDriver? { ops.velro.drivers?.items.first { $0.id == driverID } }

    private func vehicle(_ d: VelroDriver) -> String {
        let parts = [d.plateNumber.map { ltr($0) }, d.vehicleStatus].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var body: some View {
        Form {
            if let d = driver {
                Section {
                    LabeledContent("Name") { Text(verbatim: d.fullName ?? "—") }
                    LabeledContent("Approval") { Text(verbatim: d.approvalStatus) }
                    LabeledContent("Availability") { Text(verbatim: d.availability ?? "—") }
                    LabeledContent("Vehicle") { Text(verbatim: vehicle(d)) }
                    LabeledContent("Completed trips") { Text(verbatim: "\(d.completedTrips ?? 0)").monospacedDigit() }
                    LabeledContent("Driver id") { Text(verbatim: ltr(d.id)).font(.body.monospaced()).textSelection(.enabled) }
                }
            }
            Section {
                if let c = checklist {
                    LabeledContent("Required") { Text(verbatim: c.required.joined(separator: ", ")) }
                    LabeledContent("Missing") { Text(verbatim: c.missing.isEmpty ? String(localized: "None") : c.missing.joined(separator: ", ")).foregroundStyle(c.missing.isEmpty ? Color.primary : .orange) }
                    ForEach(c.documents.filter { $0.isCurrent != false }) { doc in
                        LabeledContent(doc.documentTypeCode) {
                            Text(verbatim: [doc.status, doc.expiresOn.map { String(localized: "expires \($0)") }, doc.rejectionReason].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                    LabeledContent("Can work") { Text(c.canWork ? "Yes" : "No") }
                } else if let error {
                    Text(verbatim: error).foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Reading…").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Documents")
            } footer: {
                Text("Statuses only (GET /admin/drivers/:id/documents). The document images are not downloaded; review them and approve the driver in the VELRO web console.")
            }
            Section { OpsPanelLink(url: ops.velro.environment?.adminPanel, product: "VELRO") }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: driver?.fullName ?? String(localized: "Driver")))
        .task(id: driverID) {
            guard ops.velro.session?.canReadDocuments == true else {
                error = String(localized: "Your staff role can't read driver documents (needs an operations role).")
                return
            }
            do { checklist = try await ops.velro.documents(driverID: driverID) } catch { self.error = error.localizedDescription }
        }
    }
}

struct VelroStationsView: View {
    @Environment(OperationsModel.self) private var ops
    @State private var search = ""

    var body: some View {
        let items = (ops.velro.stations?.items ?? []).filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.code.localizedStandardContains(search) }
        List {
            Section {
                ForEach(items) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: s.name).fontWeight(s.isPrimary == true ? .medium : .regular)
                        Text(verbatim: [ltr(s.code), s.villageName, s.districtName, s.status].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if let p = ops.velro.stations, p.total > p.items.count { Text("Showing the first \(p.items.count) of \(p.total), by code.") }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Stations")
    }
}

struct VelroRoutesView: View {
    @Environment(OperationsModel.self) private var ops
    @State private var search = ""

    var body: some View {
        let items = (ops.velro.routes?.items ?? []).filter { search.isEmpty || $0.originStationName.localizedStandardContains(search) || $0.destinationName.localizedStandardContains(search) }
        List {
            Section {
                ForEach(items) { r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(r.originStationName) → \(r.destinationName)")
                            Text(verbatim: [r.routeType, r.distanceM.map { "\(($0 / 1000).formatted()) km" }, r.durationMinutes.map { String(localized: "\($0) min") }, r.status]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let fare = r.fareMinor { Text(verbatim: VelroMoney.format(fare, currency: r.fareCurrency ?? "AFN")).monospacedDigit() }
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if let p = ops.velro.routes, p.total > p.items.count { Text("Showing the first \(p.items.count) of \(p.total).") }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Routes (corridors)")
    }
}

/// Two steps: the phone number (VELRO sends a code), then the code. Nothing typed is stored.
struct VelroSignInSheet: View {
    @Environment(OperationsModel.self) private var ops
    @Environment(\.dismiss) private var dismiss
    @State private var environment: VelroEnvironment = .production
    @State private var phone = ""
    @State private var code = ""
    @State private var sent: VelroOtpSent?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Sign In to VELRO").font(.headline).padding()
            Form {
                Section {
                    Picker("Environment", selection: $environment) {
                        ForEach(VelroModel.offeredEnvironments) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(sent != nil)
                    Text(verbatim: environment.apiBase.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                    if environment.isProduction {
                        Text("VELRO has no staging: this is the live system. Linumic OS only reads from it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Staff phone number", text: $phone)
                        .textContentType(.telephoneNumber)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .disabled(sent != nil)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        #endif
                    if sent == nil {
                        Button("Send Code") { Task { await requestCode() } }
                            .disabled(isWorking || phone.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                } footer: {
                    Text("VELRO sends a code only to a number that already holds a staff role, and at most 3 codes a minute. A code costs VELRO an SMS.")
                }
                if let sent {
                    Section {
                        TextField("Code", text: $code)
                            .textContentType(.oneTimeCode)
                            .environment(\.layoutDirection, .leftToRight)
                            .onSubmit { Task { await verify() } }
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        if let debug = sent.debugCode, environment == .localBackend {
                            Text("Local backend echoed the code: \(debug)").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Use Another Number") { self.sent = nil; code = "" }
                    } footer: {
                        Text("Sent by \(sent.channel ?? "sms"). It works for \(sent.expiresInSeconds / 60) minutes and 5 tries.")
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") { Task { await verify() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || sent == nil || code.trimmingCharacters(in: .whitespaces).count < 4)
            }
            .padding()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
        .onAppear { if let s = ops.velro.session { environment = s.environment } }
        .onDisappear { phone = ""; code = "" }
    }

    private func requestCode() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            sent = try await ops.velro.requestCode(environment: environment, phone: phone)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        guard !isWorking, sent != nil else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await ops.velro.verify(environment: environment, phone: phone, code: code)
            phone = ""
            code = ""
            dismiss()
        } catch {
            code = ""
            self.error = error.localizedDescription
        }
    }
}
