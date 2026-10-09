import LinumicCore
import SwiftUI

// MARK: - Small pieces

/// A WorkTrack `YYYY-MM-DD` in the UI's calendar (the day itself never shifts).
func workTrackDay(_ text: String?) -> String {
    guard let text else { return "" }
    return WorkTrackDates.displayDate(text)?.formatted(date: .abbreviated, time: .omitted) ?? text
}

/// Production in red, so a write to real customers never looks like a test.
struct WorkTrackEnvironmentBadge: View {
    let environment: WorkTrackEnvironment

    var body: some View {
        let (symbol, color): (String, Color) = switch environment {
        case .production: ("exclamationmark.shield.fill", .red)
        case .demo: ("theatermasks", .blue)
        case .localEmulator: ("hammer", .gray)
        }
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: environment.title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("WorkTrack environment: \(environment.title)"))
    }
}

/// Active / In grace / Suspended / Expired / Lapsed / No end date. Icon + text, never colour alone.
struct WorkTrackStandingBadge: View {
    let company: WTCompany

    private var look: (text: String, symbol: String, color: Color) {
        switch company.standing {
        case .perpetual: (String(localized: "No end date"), "infinity", .blue)
        case .active:
            company.isExpiring(within: 30)
                ? (String(localized: "Expiring"), "clock.badge.exclamationmark", .orange)
                : (String(localized: "Active"), "checkmark.seal.fill", .green)
        case .grace: (String(localized: "In grace"), "hourglass", .orange)
        case .lapsed:
            switch company.license.status {
            case .suspended: (String(localized: "Suspended"), "pause.circle.fill", .red)
            case .expired: (String(localized: "Expired"), "exclamationmark.octagon.fill", .red)
            default: (String(localized: "Lapsed"), "exclamationmark.octagon.fill", .red)
            }
        }
    }

    var body: some View {
        let l = look
        HStack(spacing: 4) {
            Image(systemName: l.symbol).foregroundStyle(l.color)
            Text(verbatim: l.text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(l.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(l.color.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Licence: \(l.text)"))
    }
}

/// "Ends in 12 days", "Ended 3 days ago", "No end date", or the date. Days are the server's (Kabul's today).
struct WorkTrackExpiryText: View {
    let company: WTCompany

    var body: some View {
        if let days = company.daysUntilExpiry {
            if days > 30 { Text(verbatim: workTrackDay(company.license.expiresAt)) }
            else if days > 1 { Text("Ends in \(days) days") }
            else if days == 1 { Text("Ends tomorrow") }
            else if days == 0 { Text("Last day today") }
            else { Text("Ended \(-days) days ago") }
        } else {
            Text("No end date")
        }
    }
}

/// TEST / DUPLICATE marks and a scheduled closure.
struct WorkTrackMarks: View {
    let company: WTCompany

    var body: some View {
        if let f = company.flags {
            StatusBadge(text: f.isTest ? String(localized: "TEST") : String(localized: "DUPLICATE"), color: .purple)
        }
        if company.deletion != nil {
            StatusBadge(text: String(localized: "Closure scheduled"), color: .red)
        }
    }
}

// MARK: - List

struct WorkTrackCustomersView: View {
    @Environment(WorkTrackModel.self) private var worktrack
    @State private var filter: WTCompanyFilter = .all
    @State private var search = ""
    @State private var path: [String] = []
    @State private var isSigningIn = false
    @State private var confirmSignOut = false

    private var filtered: [WTCompany] {
        worktrack.companies.filter { c in
            filter.matches(c) && (search.isEmpty || c.name.localizedStandardContains(search) || c.companyId.localizedStandardContains(search))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if worktrack.isSignedIn {
                    list
                } else {
                    signedOut
                }
            }
            .navigationTitle("WorkTrack customers")
            .navigationDestination(for: String.self) { WorkTrackCompanyView(companyID: $0) }
            .toolbar { toolbar }
        }
        .sheet(isPresented: $isSigningIn) { WorkTrackSignInSheet() }
        .confirmationDialog("Sign out of WorkTrack?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { worktrack.signOut() }
        } message: {
            Text("The refresh token is removed from this device's Keychain. WorkTrack itself is not changed.")
        }
        .alert("WorkTrack", isPresented: Binding(get: { worktrack.errorMessage != nil }, set: { if !$0 { worktrack.errorMessage = nil } })) {
            Button("OK") { worktrack.errorMessage = nil }
        } message: {
            Text(verbatim: worktrack.errorMessage ?? "")
        }
    }

    private var signedOut: some View {
        ContentUnavailableView {
            Label("Not signed in to WorkTrack", systemImage: "person.badge.key")
        } description: {
            Text("Sign in with your WorkTrack vendor account to see every customer company, its licence and payments, and to renew licences. The password is sent once to Firebase and never stored; only a refresh token is kept in this device's Keychain.")
        } actions: {
            Button("Sign In…") { isSigningIn = true }
                .buttonStyle(.borderedProminent)
            if let error = worktrack.loadError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var list: some View {
        List {
            Section { overview }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(WTCompanyFilter.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if worktrack.isRefreshing && worktrack.companies.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Reading companies…").foregroundStyle(.secondary) }
                } else if let error = worktrack.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if worktrack.companies.isEmpty {
                    Text("No companies in this environment.").foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("No companies match.").foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { c in
                        NavigationLink(value: c.companyId) { WorkTrackCompanyRow(company: c) }
                    }
                }
            } header: {
                Text("Companies")
            } footer: {
                Text("Sorted by days left, as WorkTrack returns them. Days are counted from today's date in Kabul. TEST and DUPLICATE companies are listed but left out of the counts.")
            }
            if let revenue = worktrack.revenue { WorkTrackRevenueSection(revenue: revenue) }
            if !worktrack.actions.isEmpty { WorkTrackActionsSection(records: Array(worktrack.actions.prefix(10))) }
            if !worktrack.audit.isEmpty { WorkTrackAuditSection(entries: Array(worktrack.audit.prefix(15))) }
        }
        .searchable(text: $search, prompt: Text("Company name or id"))
        .refreshable { await worktrack.refresh() }
    }

    private var overview: some View {
        let s = worktrack.summary
        return VStack(alignment: .leading, spacing: 10) {
            if let env = worktrack.environment, let session = worktrack.session {
                FitRow(spacing: 8) {
                    WorkTrackEnvironmentBadge(environment: env)
                    Text("Signed in as \(session.email)").font(.callout).foregroundStyle(.secondary)
                }
            }
            FitRow(spacing: 18) {
                metric("Companies", "\(s.total)")
                metric("Expiring in 30 days", "\(s.expiringSoon.count)", tint: s.expiringSoon.isEmpty ? .primary : .orange)
                metric("Expired", "\(s.expired.count)", tint: s.expired.isEmpty ? .primary : .red)
                metric("Trials", "\(s.trials)")
                metric("TEST / DUPLICATE", "\(s.flagged)")
                Spacer(minLength: 0)
            }
            Group {
                if worktrack.isRefreshing {
                    Label("Reading from WorkTrack…", systemImage: "arrow.triangle.2.circlepath")
                } else if let at = worktrack.lastRead, let env = worktrack.environment {
                    Label("Read from \(env.apiBase.absoluteString)/vendor/companies at \(at.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: LocalizedStringKey, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if worktrack.isSignedIn {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await worktrack.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(worktrack.isRefreshing)
                    .help("Read every company from WorkTrack again (read-only)")
            }
            ToolbarItem {
                Menu {
                    Button { isSigningIn = true } label: { Label("Switch Account or Environment…", systemImage: "arrow.left.arrow.right") }
                    Button(role: .destructive) { confirmSignOut = true } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
                }
            }
        }
    }
}

private struct WorkTrackCompanyRow: View {
    let company: WTCompany

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: company.name).fontWeight(.medium)
                    WorkTrackMarks(company: company)
                }
                Text("\(company.license.plan.rawValue) · \(company.devicesInUse)/\(company.license.deviceLimit) devices · \(company.employeesCounted)/\(company.employeeCap) employees")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Group {
                    if let last = WorkTrackDates.instant(company.lastActivityAt) {
                        Text("Last activity \(last.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("No activity recorded")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                WorkTrackStandingBadge(company: company)
                WorkTrackExpiryText(company: company).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkTrackRevenueSection: View {
    let revenue: WTRevenue

    private func afn(_ v: Double) -> String { "\(v.formatted(.number.precision(.fractionLength(0)))) AFN" }

    var body: some View {
        Section {
            LabeledContent("Earned (HesabPay, paid)") {
                Text(verbatim: "\(afn(revenue.earned.totalAfn)) · \(revenue.earned.orderCount)").monospacedDigit()
            }
            ForEach(Array(revenue.earned.byMonth.prefix(6).enumerated()), id: \.offset) { _, m in
                LabeledContent {
                    Text(verbatim: "\(afn(m.totalAfn)) · \(m.orderCount)").monospacedDigit()
                } label: {
                    Text(verbatim: "\(m.year)/\(String(format: "%02d", m.month))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            LabeledContent("Expected renewals, next \(revenue.expected.windowDays) days") {
                Text(verbatim: "\(afn(revenue.expected.totalAfn)) · \(revenue.expected.renewals.count)").monospacedDigit()
            }
            if revenue.excluded.companyCount > 0 {
                Text("Left out: \(revenue.excluded.companyCount) TEST or DUPLICATE companies (\(revenue.excluded.orderCount) orders, \(afn(revenue.excluded.amountAfn))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Revenue")
        } footer: {
            Text("From WorkTrack /vendor/revenue. Earned counts only orders HesabPay marked PAID, by Solar Hijri month in Kabul (year/month). Expected is WorkTrack's forecast at today's prices, not money received.")
        }
    }
}

private struct WorkTrackActionsSection: View {
    let records: [WorkTrackActionRecord]

    var body: some View {
        Section {
            ForEach(records) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        outcome(r.outcome)
                        Text(verbatim: r.companyName).fontWeight(.medium)
                        WorkTrackEnvironmentBadge(environment: r.environment)
                    }
                    Text("Last day \(r.before.expiresAt ?? String(localized: "none")) → \(r.sent.expiresAt ?? String(localized: "none")), plan \(r.before.plan.rawValue) → \(r.sent.plan.rawValue) · \(r.actorEmail) · \(r.at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let m = r.message { Text(verbatim: m).font(.caption).foregroundStyle(r.outcome == .verified ? Color.secondary : .red) }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Sent from Linumic OS")
        } footer: {
            Text("This device's own log of licence changes sent to WorkTrack (worktrack-actions.json, never deleted). WorkTrack keeps its own audit trail as well.")
        }
    }

    @ViewBuilder private func outcome(_ o: WorkTrackActionRecord.Outcome) -> some View {
        switch o {
        case .verified: Label("Verified", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green).help(Text("Verified"))
        case .unverified: Label("Not verified", systemImage: "questionmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.orange).help(Text("Not verified"))
        case .failed: Label("Failed", systemImage: "xmark.octagon.fill").labelStyle(.iconOnly).foregroundStyle(.red).help(Text("Failed"))
        }
    }
}

private struct WorkTrackAuditSection: View {
    let entries: [WTAuditEntry]
    @Environment(WorkTrackModel.self) private var worktrack

    var body: some View {
        Section {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(e.action) · \(worktrack.company(e.companyId ?? "")?.name ?? e.companyId ?? "")").font(.callout)
                    if e.action == "license.update", let b = e.before?.asLicense, let a = e.after?.asLicense {
                        Text("Last day \(b.expiresAt ?? String(localized: "none")) → \(a.expiresAt ?? String(localized: "none")), plan \(b.plan.rawValue) → \(a.plan.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(verbatim: "\(e.actorEmail ?? "—") · \(WorkTrackDates.instant(e.at)?.formatted(date: .abbreviated, time: .shortened) ?? (e.at ?? ""))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("WorkTrack audit trail")
        } footer: {
            Text("The newest entries of WorkTrack's vendorAuditLogs (/vendor/audit): what any vendor account did, from any console.")
        }
    }
}

// MARK: - Sign in

struct WorkTrackSignInSheet: View {
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(VaultModel.self) private var vault
    @State private var saveOffer: VaultSaveOffer?
    @Environment(\.dismiss) private var dismiss
    @State private var environment: WorkTrackEnvironment = .production
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("Sign In to WorkTrack").font(.headline).padding()
            Form {
                Section {
                    Picker("Environment", selection: $environment) {
                        ForEach(WorkTrackModel.offeredEnvironments) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(verbatim: environment.apiBase.absoluteString)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                    if environment.isProduction {
                        Label("Production holds real customers. Renewals you send here change their licences.", systemImage: "exclamationmark.shield.fill")
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
                    Text("Your WorkTrack vendor account (Firebase email and password, with the vendor claim and a verified email). The password goes to Firebase once and is not stored; only the refresh token is kept, in this device's Keychain.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            HStack {
                VaultFillMenu(form: .worktrack(environment)) { login, password in
                    if let login { email = login }
                    if let password { self.password = password }
                }
                .disabled(isWorking)
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
        .onAppear {
            if let s = worktrack.session { environment = s.environment; email = s.email }
        }
        .vaultSaveOffer($saveOffer) { dismiss() }
    }

    private func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await worktrack.signIn(environment: environment, email: email, password: password)
            let offer = vault.saveOffer(form: .worktrack(environment), login: email, password: password)
            password = ""
            if let offer { saveOffer = offer } else { dismiss() }
        } catch {
            password = ""
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Company detail

struct WorkTrackCompanyView: View {
    let companyID: String
    @Environment(WorkTrackModel.self) private var worktrack
    @State private var record: WorkTrackModel.CompanyRecord?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isRenewing = false

    var body: some View {
        Form {
            if let c = record?.detail.company ?? worktrack.company(companyID) {
                licenceSection(c)
                Section {
                    Button { isRenewing = true } label: { Label("Renew or Change Licence…", systemImage: "arrow.clockwise.circle") }
                        .disabled(!worktrack.isSignedIn)
                } footer: {
                    Text("Shows every licence field before and after, asks for confirmation, sends one PUT, then reads the company again to check what WorkTrack stored.")
                }
                companySection(c)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if let r = record {
                ordersSection(r.orders)
                timelineSection(r.detail.timeline)
                if !r.detail.contacts.isEmpty || !r.detail.crmAccounts.isEmpty { crmSection(r.detail) }
                Section {
                    if let env = worktrack.environment {
                        Text("Read from \(env.apiBase.absoluteString)/vendor/companies/\(companyID)/detail and /orders at \(r.readAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else if isLoading {
                Section { HStack { ProgressView().controlSize(.small); Text("Reading from WorkTrack…").foregroundStyle(.secondary) } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: record?.detail.company.name ?? worktrack.company(companyID)?.name ?? companyID))
        .task(id: companyID) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $isRenewing, onDismiss: { Task { await load() } }) {
            WorkTrackRenewSheet(companyID: companyID)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            record = try await worktrack.record(companyID)
            error = nil
        } catch {
            record = nil
            self.error = error.localizedDescription
        }
    }

    private func yesNo(_ b: Bool) -> String { b ? String(localized: "Yes") : String(localized: "No") }

    @ViewBuilder private func licenceSection(_ c: WTCompany) -> some View {
        Section {
            LabeledContent("Licence") { WorkTrackStandingBadge(company: c) }
            LabeledContent("Plan") { Text(verbatim: c.license.plan.rawValue) }
            LabeledContent("Last day") {
                if let e = c.license.expiresAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: "\(workTrackDay(e))  (\(ltr(e)))")
                        WorkTrackExpiryText(company: c).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No end date (perpetual)")
                }
            }
            LabeledContent("Licence status") { Text(verbatim: c.license.status.rawValue) }
            LabeledContent("Device seats") { Text("\(c.devicesInUse) in use of \(c.license.deviceLimit)").monospacedDigit() }
            LabeledContent("Enforce device seats") { Text(verbatim: yesNo(c.license.enforceDevices)) }
            LabeledContent("Employees") { Text("\(c.employeesCounted) counted (\(c.employeeCount) active) of \(c.employeeCap)").monospacedDigit() }
            LabeledContent("Employee cap") {
                Text(verbatim: c.license.employeeLimit.map { String($0) } ?? String(localized: "Plan's cap"))
            }
            LabeledContent("Enforce plan") { Text(verbatim: yesNo(c.license.enforcePlan)) }
            LabeledContent("Extra features") {
                Text(verbatim: c.license.extraFeatures.isEmpty ? String(localized: "None") : c.license.extraFeatures.joined(separator: ", "))
            }
            LabeledContent("Last written by") { Text(verbatim: c.license.source) }
        } header: {
            HStack(spacing: 6) {
                Text(verbatim: c.name)
                WorkTrackMarks(company: c)
            }
        } footer: {
            Text("A licence keeps working for \(WorkTrackDates.graceDays) days after its last day (grace), then lapses.")
        }
    }

    @ViewBuilder private func companySection(_ c: WTCompany) -> some View {
        Section("Company") {
            LabeledContent("Company id") { Text(verbatim: ltr(c.companyId)).font(.body.monospaced()).textSelection(.enabled) }
            LabeledContent("Account status") { Text(verbatim: c.status) }
            LabeledContent("Signed up") {
                if let d = WorkTrackDates.instant(c.createdAt) { Text(d.formatted(date: .abbreviated, time: .omitted)) } else { UnknownLabel() }
            }
            LabeledContent("Last activity") {
                if let d = WorkTrackDates.instant(c.lastActivityAt) { Text(d.formatted(date: .abbreviated, time: .shortened)) } else { Text("Never") }
            }
            if let f = c.flags {
                LabeledContent("Vendor mark") {
                    Text(verbatim: [f.kind, f.duplicateOf.map { "→ \($0)" }, f.note].compactMap { $0 }.joined(separator: " "))
                }
            }
            if let d = c.deletion {
                LabeledContent("Closure") { Text("Scheduled, purge after \(workTrackDay(d.purgeAfter))").foregroundStyle(.red) }
            }
            ForEach(c.duplicates, id: \.companyId) { m in
                LabeledContent("Possible duplicate") { Text(verbatim: "\(m.name) (\(m.reasons.joined(separator: ", ")))") }
            }
            if !c.attention.isEmpty {
                LabeledContent("Attention") {
                    Text(verbatim: c.attention.map { "\($0.code) (\($0.severity))" }.joined(separator: ", ")).multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder private func ordersSection(_ orders: [WTOrder]) -> some View {
        Section {
            if orders.isEmpty {
                Text("No orders.").foregroundStyle(.secondary)
            } else {
                ForEach(orders) { o in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(o.plan) · \(o.term) · \(o.months)").font(.callout)
                            Text(verbatim: [WorkTrackDates.instant(o.paidAt ?? o.createdAt)?.formatted(date: .abbreviated, time: .omitted), o.transactionId.map(ltr)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: "\(o.amountAfn.formatted(.number.precision(.fractionLength(0)))) AFN").monospacedDigit()
                        StatusBadge(text: o.status, color: o.status == "PAID" ? .green : o.status == "FAILED" ? .red : .orange)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Orders")
        } footer: {
            Text("HesabPay checkout orders from /vendor/companies/:id/orders, newest first (up to 100).")
        }
    }

    @ViewBuilder private func timelineSection(_ events: [WTTimelineEvent]) -> some View {
        Section("History") {
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    timelineText(e).font(.callout)
                    Text(verbatim: WorkTrackDates.instant(e.at)?.formatted(date: .abbreviated, time: .shortened) ?? workTrackDay(e.at))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func timelineText(_ e: WTTimelineEvent) -> Text {
        switch e {
        case .signup: Text("Signed up")
        case .licence(_, let by, let before, let after):
            Text("Licence changed by \(by ?? String(localized: "unknown")): last day \(before?.expiresAt ?? String(localized: "none")) → \(after?.expiresAt ?? String(localized: "none")), plan \(before?.plan.rawValue ?? "—") → \(after?.plan.rawValue ?? "—"), seats \(before.map { String($0.deviceLimit) } ?? "—") → \(after.map { String($0.deviceLimit) } ?? "—")")
        case .flags(_, let by, let after):
            Text("Vendor mark set to \(after?.kind ?? String(localized: "none")) by \(by ?? String(localized: "unknown"))")
        case .order(_, _, let status, let plan, let term, _, let amount, _):
            Text("Order \(plan) \(term), \(amount.formatted(.number.precision(.fractionLength(0)))) AFN: \(status)")
        case .ticket(_, _, let subject, let status, let priority, _):
            Text("Ticket “\(subject)” (\(priority)): \(status)")
        case .other(let kind, _):
            Text(verbatim: kind)
        }
    }

    @ViewBuilder private func crmSection(_ d: WTCompanyDetail) -> some View {
        Section {
            ForEach(d.crmAccounts) { a in
                LabeledContent(a.name) { Text(verbatim: a.stage) }
            }
            ForEach(d.contacts) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: c.name + (c.primary ? " ★" : "")).font(.callout)
                    Text(verbatim: [c.role, c.phone, c.email].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Vendor CRM")
        }
    }
}

// MARK: - Renew

/// Renew or change one company's licence. Built from the licence read when the sheet opens; shows every field
/// before and after; production needs the company name typed; sends one PUT; re-reads and shows what was stored.
struct WorkTrackRenewSheet: View {
    let companyID: String
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(\.dismiss) private var dismiss

    enum ExpiryMode: String, CaseIterable, Identifiable {
        case oneMonth, oneYear, custom, perpetual
        var id: String { rawValue }
    }

    @State private var company: WTCompany?
    @State private var readAt: Date?
    @State private var plan: WTPlan = .bronze
    @State private var deviceLimit = 1
    @State private var status: WTLicenseStatus = .active
    @State private var mode: ExpiryMode = .oneMonth
    @State private var customDate = Date.now
    @State private var perpetualConfirmed = false
    @State private var typedName = ""
    @State private var checked = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: WorkTrackModel.RenewalResult?

    private var today: String { WorkTrackDates.kabulToday() }

    private func expiryChoice(for license: WTLicense) -> WTExpiryChoice? {
        switch mode {
        case .oneMonth: WorkTrackRenewal.extended(license, months: 1, today: today).map(WTExpiryChoice.date)
        case .oneYear: WorkTrackRenewal.extended(license, months: 12, today: today).map(WTExpiryChoice.date)
        case .custom: .date(WorkTrackDates.string(fromPicked: customDate))
        case .perpetual: .perpetual(confirmed: perpetualConfirmed)
        }
    }

    /// The PUT body, or why it can't be built yet.
    private var built: Result<WTLicenseWrite, Error>? {
        guard let company, let choice = expiryChoice(for: company.license) else { return nil }
        return Result {
            try WorkTrackRenewal.makeWrite(current: company.license,
                                           input: WTRenewalInput(plan: plan, deviceLimit: deviceLimit, status: status, expiry: choice), today: today)
        }
    }

    private var confirmed: Bool {
        guard let company, let env = worktrack.environment else { return false }
        return env.isProduction ? WorkTrackRenewal.confirmationMatches(typedName, companyName: company.name) : checked
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(result == nil ? "Renew or Change Licence" : "Licence updated").font(.headline).padding()
            if let result, let company {
                resultView(result, company: company)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
            } else {
                Group {
                    if let company { form(company) } else if let error {
                        Form { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }.formStyle(.grouped)
                    } else {
                        ProgressView("Reading the current licence…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                    Button("Send to WorkTrack") { Task { await send() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !confirmed || (try? built?.get()) == nil)
                }
                .padding()
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
        .task { await loadCurrent() }
    }

    private func loadCurrent() async {
        do {
            let c = try await worktrack.fetchCurrent(companyID)
            company = c
            readAt = .now
            plan = c.license.plan.isKnown ? c.license.plan : .bronze
            deviceLimit = c.license.deviceLimit
            status = WorkTrackRenewal.suggestedStatus(for: c.license)
            if let next = WorkTrackRenewal.extended(c.license, months: 1, today: today), let d = WorkTrackDates.displayDate(next) { customDate = d }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder private func form(_ c: WTCompany) -> some View {
        Form {
            Section {
                LabeledContent("Company") { Text(verbatim: c.name) }
                LabeledContent("Environment") { if let env = worktrack.environment { WorkTrackEnvironmentBadge(environment: env) } }
                if worktrack.environment?.isProduction == true {
                    Label("This changes a real customer's licence in production.", systemImage: "exclamationmark.shield.fill")
                        .font(.callout).foregroundStyle(.red)
                }
                if let readAt {
                    Text("Current licence read at \(readAt.formatted(date: .omitted, time: .shortened)). If it changes in WorkTrack before you send, nothing is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Plan", selection: $plan) {
                    ForEach(WTPlan.all, id: \.self) { p in
                        if let def = worktrack.plan(p) {
                            Text(verbatim: "\(p.rawValue) · \(def.priceAfn.formatted(.number.precision(.fractionLength(0)))) AFN · \(def.deviceLimit)").tag(p)
                        } else {
                            Text(verbatim: p.rawValue).tag(p)
                        }
                    }
                }
                HStack {
                    Stepper(value: $deviceLimit, in: 1...100_000) {
                        Text("Device seats: \(deviceLimit)").monospacedDigit()
                    }
                    if let def = worktrack.plan(plan), def.deviceLimit != deviceLimit {
                        Button("Use the plan's \(def.deviceLimit)") { deviceLimit = def.deviceLimit }
                    }
                }
                Picker("Status", selection: $status) {
                    ForEach(WTLicenseStatus.writable, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                }
                if c.license.status == .suspended && status == .suspended {
                    Text("This licence is SUSPENDED and stays suspended unless you choose ACTIVE.").font(.caption).foregroundStyle(.orange)
                }
                if c.license.status == .expired {
                    Text("Status was EXPIRED; a renewal sets it to ACTIVE. Change it here if you don't mean that.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Licence")
            }
            Section {
                Picker("New last day", selection: $mode) {
                    Text("+1 month").tag(ExpiryMode.oneMonth)
                    Text("+1 year").tag(ExpiryMode.oneYear)
                    Text("Custom").tag(ExpiryMode.custom)
                    Text("No end date").tag(ExpiryMode.perpetual)
                }
                .pickerStyle(.segmented)
                switch mode {
                case .oneMonth, .oneYear:
                    Text("Counted from \(ltr(WorkTrackRenewal.base(for: c.license, today: today))): the current last day if it is still ahead, otherwise today in Kabul.")
                        .font(.caption).foregroundStyle(.secondary)
                case .custom:
                    DatePicker("Last day", selection: $customDate, in: (WorkTrackDates.displayDate(today) ?? .now)..., displayedComponents: .date)
                case .perpetual:
                    Toggle(isOn: $perpetualConfirmed) {
                        Text("I understand this licence will never expire")
                        Text("WorkTrack stores no end date: the customer keeps the plan with no renewal. Use only when that's the agreement.")
                    }
                    .tint(.red)
                }
            } header: {
                Text("Expiry")
            }
            Section {
                switch built {
                case .success(let write)?:
                    WorkTrackDiffTable(rows: WorkTrackRenewal.diff(current: c.license, write: write))
                case .failure(let e)?:
                    Label(e.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Before and after")
            } footer: {
                Text("Every field is sent, including the ones you didn't change (copied from the current licence), so WorkTrack keeps them exactly as they are.")
            }
            Section {
                if worktrack.environment?.isProduction == true {
                    TextField("Type the company name to confirm", text: $typedName)
                        .autocorrectionDisabled()
                    Text("Type: \(c.name)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Toggle("I've checked the changes above", isOn: $checked)
                }
            } header: {
                Text("Confirm")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private func send() async {
        guard let company, case .success(let write)? = built, confirmed, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            result = try await worktrack.renew(company: company, basedOn: company.license, write: write)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder private func resultView(_ r: WorkTrackModel.RenewalResult, company: WTCompany) -> some View {
        Form {
            Section {
                if r.refetched == nil {
                    Label("WorkTrack accepted the change, but reading it back failed, so it isn't verified. Check the company again.", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if r.mismatches.isEmpty {
                    Label("Read back from WorkTrack: every field is as sent.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("Read back from WorkTrack: some fields differ from what was sent.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    WorkTrackDiffTable(rows: r.mismatches, beforeTitle: "Sent", afterTitle: "Stored")
                }
                Text("Recorded in this device's action log; WorkTrack wrote its own audit entries too.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                WorkTrackDiffTable(rows: WorkTrackRenewal.diff(before: company.license, after: r.refetched ?? r.stored))
            } header: {
                Text("Before and now")
            } footer: {
                if let env = worktrack.environment {
                    Text("Now = /vendor/companies/\(company.companyId)/detail on \(env.title), read at \(r.readAt.formatted(date: .abbreviated, time: .shortened)).")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Field / before / after, the changed rows marked with an icon and weight (not colour alone).
struct WorkTrackDiffTable: View {
    let rows: [WTFieldChange]
    var beforeTitle: LocalizedStringKey = "Before"
    var afterTitle: LocalizedStringKey = "After"

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Field")
                Text(beforeTitle)
                Text(afterTitle)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    HStack(spacing: 4) {
                        Image(systemName: row.changed ? "arrow.right.circle.fill" : "equal.circle")
                            .foregroundStyle(row.changed ? Color.orange : Color.secondary)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(verbatim: row.field)
                    }
                    Text(verbatim: row.before).foregroundStyle(row.changed ? .secondary : .primary)
                    Text(verbatim: row.after).fontWeight(row.changed ? .semibold : .regular)
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.changed
                                    ? Text("\(row.field): changes from \(row.before) to \(row.after)")
                                    : Text("\(row.field): stays \(row.before)"))
            }
        }
    }
}
