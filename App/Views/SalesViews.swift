import LinumicCore
import SwiftUI

/// Sales (فروش): who to call today, read-only, from what the WorkTrack, Website messages and Operations models already
/// read. Built on every render; nothing is saved. Every card says where and when it was read; a part that was not read
/// is Unknown with its reason, never empty. Linumic OS never writes to the CRM: dates and stages are changed in the
/// WorkTrack console. A reminder draft is only copied, concealed, and cleared from the clipboard after two minutes.
struct SalesView: View {
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(SiteMessagesModel.self) private var siteMessages
    @Environment(OperationsModel.self) private var operations
    @State private var isReading = false

    var body: some View {
        #if DEBUG
        // Debug-only screenshot aid: `-LCCSalesSample skipped` (with `-LCCScreen sales`) shows made-up data; nothing is
        // read, and the app starts no job (LinumicOSApp).
        if let sample = SalesPreviewData.launchSample {
            SalesPage(report: sample)
        } else {
            page
        }
        #else
        page
        #endif
    }

    private var page: some View {
        let input = SalesInput.collect(worktrack: worktrack, siteMessages: siteMessages, safeBeauty: operations.safeBeauty)
        return SalesPage(report: SalesBuilder.build(input, now: .now), isReading: isReading || worktrack.isRefreshing, readNow: readNow)
    }

    /// WorkTrack (the company list with the CRM accounts, for the TEST marks) and the website messages. Not SafeBeauty:
    /// its counts are billed per query and its own job reads them.
    private func readNow() async {
        isReading = true
        defer { isReading = false }
        async let w: Void = worktrack.refresh()
        async let m: Void = siteMessages.refresh()
        _ = await (w, m)
    }
}

/// The page itself, from a report: no model of its own, so a preview can show it.
struct SalesPage: View {
    let report: SalesReport
    var isReading = false
    var readNow: () async -> Void = {}

    @Environment(Router.self) private var router
    /// Nil in a preview: then the shape check can't be opened.
    @Environment(WorkTrackModel.self) private var worktrack: WorkTrackModel?
    @State private var highlighted: String?
    @State private var checkingShape = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let wt = report.worktrack.value {
                        followUps(wt)
                        signups(wt)
                    } else {
                        SalesCard(title: "Who to call", symbol: "phone.arrow.up.right", tint: .orange) {
                            SalesUnknownText(reason: report.worktrack.reason ?? "")
                            Button { router.go(.worktrackCustomers) } label: { Label("Open WorkTrack customers", systemImage: "person.2.badge.key") }
                                .buttonStyle(.borderless)
                        }
                    }
                    renewals
                    siteMessages
                    kyc
                    unknown
                    if let wt = report.worktrack.value, !wt.leftOut.isEmpty { leftOut(wt) }
                    Text("Nothing on this page is saved on this device or sent to Linumic's cloud. Nothing is sent to customers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .refreshable { await readNow() }
            #if DEBUG
            .defaultScrollAnchor(SalesPreviewData.launchScrollAnchor)
            #endif
            // From the Desk, the Brief or the Command Palette: one row, scrolled to and highlighted.
            .onChange(of: router.request, initial: true) {
                if case .salesItem(let key) = router.take({ if case .salesItem = $0 { true } else { false } }) {
                    highlighted = key
                    withAnimation { proxy.scrollTo(key, anchor: .center) }
                }
            }
        }
        .navigationTitle(SidebarItem.sales.title)
        .toolbar {
            ToolbarItem {
                Button { Task { await readNow() } } label: { Label("Read now", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(isReading)
                    .help("Read WorkTrack (the company list and the CRM accounts) and the website messages again")
            }
        }
        .sheet(isPresented: $checkingShape) { SalesShapeSheet() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read-only. Linumic OS never writes to the CRM; change dates and stages in the WorkTrack console.")
                .font(.callout).foregroundStyle(.secondary)
            FitRow(spacing: 8) {
                SalesPill(text: String(localized: "Today in Kabul: \(SalesFormat.day(report.kabulToday)) (\(salesIsolated(report.kabulToday)))"),
                          symbol: "calendar", color: .teal)
                if let wt = report.worktrack.value, !wt.isProduction {
                    SalesPill(text: String(localized: "WorkTrack: \(wt.environment), not production"), symbol: "theatermasks", color: .blue)
                }
                if isReading { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if let console = report.worktrack.value?.console {
                    Link(destination: console) { Label("Open WorkTrack console", systemImage: "arrow.up.forward.app") }
                        .help(Text(verbatim: console.absoluteString))
                }
            }
        }
    }

    // MARK: Follow-ups

    @ViewBuilder
    private func followUps(_ wt: SalesWorkTrack) -> some View {
        let source = salesSource("GET /v1/vendor/crm/accounts", environment: wt.environment, at: wt.accountsReadAt)
        // Accounts set aside, or past the 2000 limit, may be due too: every count is then "at least", and an empty list
        // is unknown, never "none".
        let missing = SalesBrief.accountsCaveats(wt)
        let atLeast = !missing.isEmpty
        SalesCard(title: "Call today", symbol: "phone.fill", tint: .green, count: wt.callToday.count, atLeast: atLeast, caption: source) {
            SalesCompleteness(isEmpty: wt.callToday.isEmpty, empty: "No follow-up is due today.", missing: missing)
            ForEach(wt.callToday) { f in row(f.account, due: f.due, wt: wt) }
        }
        SalesCard(title: "This week", symbol: "calendar", tint: .blue, count: wt.thisWeek.count, atLeast: atLeast, caption: source) {
            SalesCompleteness(isEmpty: wt.thisWeek.isEmpty, empty: "No follow-up in the next 7 days.", missing: missing)
            ForEach(wt.thisWeek) { f in row(f.account, due: f.due, wt: wt) }
        }
        if !wt.dateUnknown.isEmpty {
            SalesCard(title: "Date could not be read", symbol: "exclamationmark.triangle", tint: .orange, count: wt.dateUnknown.count,
                      atLeast: atLeast, caption: source) {
                SalesNote(String(localized: "The next-action date is not a real day. WorkTrack's own Today tab may still list it; fix the date in the console."))
                ForEach(wt.dateUnknown) { f in row(f.account, due: f.due, wt: wt) }
            }
        }
        SalesCard(title: "No next step", symbol: "questionmark.circle", tint: .purple, count: wt.noNextStep.count, atLeast: atLeast, caption: source) {
            if !wt.noNextStep.isEmpty {
                SalesNote(String(localized: "Open accounts with no next-action date. WorkTrack's own Today tab does not show them; set the date in the console."))
            }
            SalesCompleteness(isEmpty: wt.noNextStep.isEmpty, empty: "Every open account has a next-action date.", missing: missing)
            ForEach(wt.noNextStep) { a in row(a, due: nil, wt: wt) }
        }
        if !wt.later.isEmpty {
            SalesCard(title: "Later", symbol: "calendar.badge.clock", tint: .secondary, count: wt.later.count, atLeast: atLeast, caption: source) {
                ForEach(wt.later) { f in row(f.account, due: f.due, wt: wt) }
            }
        }
    }

    private func row(_ account: SalesAccount, due: SalesDue?, wt: SalesWorkTrack) -> some View {
        SalesAccountRow(account: account, due: due, today: report.kabulToday, console: wt.console, isHighlighted: highlighted == account.key)
            .id(account.key)
    }

    // MARK: Signups

    private func signups(_ wt: SalesWorkTrack) -> some View {
        let source = salesSource("GET /v1/vendor/companies, /v1/vendor/crm/accounts", environment: wt.environment,
                                 at: max(wt.accountsReadAt, wt.companiesReadAt))
        return SalesCard(title: "New signups without a CRM account", symbol: "person.badge.plus", tint: .mint,
                         count: wt.signups.value?.rows.count, atLeast: wt.signups.value?.isComplete == false, caption: source) {
            switch wt.signups {
            case .unknown(let reason):
                SalesUnknownText(reason: reason)
            case .read(let list):
                if list.rows.isEmpty { SalesEmptyText("No new or self-serve company without a CRM account.") }
                if !list.isComplete {
                    SalesNote(String(localized: "WorkTrack reads at most \(MoneyBuilder.revenueCompanyLimit) companies; signups past that are unknown."),
                              symbol: "exclamationmark.triangle", tint: .orange)
                }
                ForEach(list.rows) { s in
                    SalesSignupRow(signup: s, today: report.kabulToday, console: wt.console, isHighlighted: highlighted == s.key).id(s.key)
                }
            }
            if let without = wt.withoutCRMAccount.value, !without.rows.isEmpty {
                let n = without.rows.count
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(without.rows) { c in Text(verbatim: c.name).font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(without.isComplete ? String(localized: "\(n) other WorkTrack companies have no CRM account")
                                            : String(localized: "At least \(n) other WorkTrack companies have no CRM account"))
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Renewals, website messages, KYC

    /// From the company list alone: its source and read time are the list's, whatever the CRM accounts' state.
    private var renewals: some View {
        let read = report.renewals.value
        return SalesCard(title: "Renewals and trials ending", symbol: "arrow.triangle.2.circlepath", tint: .orange,
                         count: read?.list.rows.count, atLeast: read?.list.isComplete == false,
                         caption: read.map { salesSource("GET /v1/vendor/companies", environment: $0.environment, at: $0.readAt) }) {
            switch report.renewals {
            case .unknown(let reason):
                SalesUnknownText(reason: reason)
            case .read(let r):
                SalesCompleteness(isEmpty: r.list.rows.isEmpty, empty: "No licence ends in the next 30 days, and none has ended.",
                                  missing: r.list.isComplete ? [] : [String(localized: "WorkTrack reads at most \(MoneyBuilder.revenueCompanyLimit) companies; renewals past that are unknown.")])
                if !r.list.rows.isEmpty {
                    SalesNote(String(localized: "Already on the Desk from WorkTrack customers; listed here so the call list is in one place."))
                }
                if r.deletionsLeftOut > 0 {
                    SalesNote(String(localized: "\(r.deletionsLeftOut) companies with a scheduled deletion are left out; WorkTrack customers lists them."))
                }
                ForEach(r.list.rows) { row in SalesRenewalRow(renewal: row, today: report.kabulToday) }
            }
        }
    }

    private var siteMessages: some View {
        SalesCard(title: "Website messages", symbol: "envelope", tint: .indigo, count: report.siteMessages.value?.new.count,
                  caption: report.siteMessages.value.map { String(localized: "\(SiteMessagesSource.sourceText) · read \($0.readAt.formatted(date: .abbreviated, time: .shortened))") }) {
            switch report.siteMessages {
            case .unknown(let reason):
                SalesUnknownText(reason: reason)
            case .read(let m):
                if m.new.isEmpty { SalesEmptyText("No new message.") }
                ForEach(m.new) { SalesMessageRow(message: $0) }
                if m.earlierSeen > 0 { SalesNote(String(localized: "\(m.earlierSeen) earlier messages already marked seen.")) }
                if let console = report.worktrack.value?.console {
                    Link(destination: console) { Label("Add a lead in the WorkTrack console", systemImage: "arrow.up.forward.app") }
                }
            }
        }
    }

    private var kyc: some View {
        SalesCard(title: "SafeBeauty: providers waiting for KYC", symbol: "person.text.rectangle", tint: .pink,
                  caption: report.kyc.value.map { k in
                      String(localized: "SafeBeauty (\(k.environment)) · Firestore users, kycStatus PENDING · read \(k.readAt.formatted(date: .abbreviated, time: .shortened))")
                  }) {
            switch report.kyc {
            case .unknown(let reason):
                SalesUnknownText(reason: reason)
            case .read(let k):
                Text(k.isExact ? String(localized: "\(k.providers) providers waiting, of \(k.pending) people waiting for KYC")
                               : String(localized: "At least \(k.providers) providers among the first \(k.queueRead) of \(k.pending) people waiting for KYC"))
                    .font(.callout)
                SalesNote(String(localized: "A count only; the names are on the Operations screen."))
                Button {
                    router.operationsTab = .safeBeauty
                    router.go(.operations)
                } label: { Label("Open Operations → SafeBeauty", systemImage: "tray.full") }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Unknown and left out

    private var unknownReasons: [String] {
        var reasons: [String] = []
        if let r = report.worktrack.reason { reasons.append(r) }
        if let wt = report.worktrack.value {
            reasons += SalesBrief.caveats(wt)
            if let r = wt.signups.reason, !reasons.contains(r) { reasons.append(r) }
        }
        for r in [report.renewals.reason, report.siteMessages.reason, report.kyc.reason].compactMap({ $0 }) where !reasons.contains(r) {
            reasons.append(r)
        }
        return reasons
    }

    private var unknown: some View {
        SalesCard(title: "Unknown", symbol: "questionmark.diamond", tint: .gray, count: unknownReasons.count) {
            if unknownReasons.isEmpty { SalesEmptyText("Every part of this page was read.") }
            ForEach(Array(unknownReasons.enumerated()), id: \.offset) { _, reason in
                Label { Text(verbatim: reason) } icon: { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                    .font(.callout)
            }
            Button { checkingShape = true } label: { Label("Check the CRM answer (one GET)…", systemImage: "checklist") }
                .buttonStyle(.borderless)
                .disabled(report.worktrack.value == nil || worktrack == nil)
                .help("Reads the CRM accounts once and shows only their keys, types and counts, never a value")
        }
    }

    private func leftOut(_ wt: SalesWorkTrack) -> some View {
        SalesCard(title: "Left out", symbol: "eye.slash", tint: .secondary, count: wt.leftOut.count) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(wt.leftOut) { a in Text(verbatim: a.name).font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("CRM accounts of companies marked TEST or DUPLICATE in WorkTrack. They are not called and not on the Desk.").font(.callout)
            }
        }
    }
}

// MARK: - Rows

/// One CRM account: its stage, when it is due by Kabul's day, the owner's note, the linked company, and the actions:
/// contacts (one GET, on demand), a reminder draft (copied, never sent) and the console.
private struct SalesAccountRow: View {
    let account: SalesAccount
    let due: SalesDue?
    let today: String
    let console: URL?
    let isHighlighted: Bool

    /// Nil in a preview: then nothing can be read or copied.
    @Environment(WorkTrackModel.self) private var worktrack: WorkTrackModel?
    @State private var showContacts = false
    @State private var drafting = false

    private var canRead: Bool { worktrack.map { !$0.isRefreshing && !$0.isSalesReading } ?? false }
    /// The name a draft uses: the WorkTrack company's when it is listed, otherwise the account's.
    private var draftName: (name: String, source: SalesNameSource) {
        if let company = account.company.company { return (company.name, .companies) }
        return (account.name, .accounts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FitRow(spacing: 8) {
                Text(verbatim: account.name).fontWeight(.semibold)
                SalesPill(text: SalesFormat.stage(account.stage), symbol: "flag", color: .secondary)
                if let due { SalesPill(text: dueText(due), symbol: "clock", color: dueColor(due)) }
            }
            if let note = account.nextAction {
                Text(verbatim: note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            companyLine
            FitRow(spacing: 14) {
                Button { showContacts = true } label: { Label("Contacts", systemImage: "person.crop.circle") }
                    .disabled(!canRead)
                    .accessibilityLabel(Text("Contacts for \(account.name)"))
                    .minTapTarget()
                    #if os(macOS)
                    .popover(isPresented: $showContacts) {
                        SalesContactsView(accountID: account.accountID).frame(width: 380).frame(maxHeight: 480)
                    }
                    #else
                    .sheet(isPresented: $showContacts) {
                        NavigationStack { SalesContactsView(accountID: account.accountID) }.presentationDetents([.medium, .large])
                    }
                    #endif
                Button { drafting = true } label: { Label("Copy reminder draft…", systemImage: "doc.on.clipboard") }
                    .disabled(worktrack == nil)
                    .accessibilityLabel(Text("Copy reminder draft for \(account.name)…"))
                    .minTapTarget()
                if let console {
                    Link(destination: console) { Label("Console", systemImage: "arrow.up.forward.app") }
                        .help("Open WorkTrack console")
                        .accessibilityLabel(Text("Open WorkTrack console for \(account.name)"))
                        .minTapTarget()
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $drafting) {
            SalesDraftSheet(name: draftName.name, nameSource: draftName.source,
                            kinds: SalesDraft.kinds(followUp: account.company.company, today: today),
                            license: account.company.company?.license, accountID: account.accountID, today: today)
        }
    }

    @ViewBuilder
    private var companyLine: some View {
        switch account.company {
        case .prospect:
            Text("Not linked to a WorkTrack company (a prospect).").font(.caption).foregroundStyle(.secondary)
        case .listed(let c):
            let end = c.license.expiresAt.map(SalesFormat.day) ?? String(localized: "no end date")
            Text(verbatim: String(localized: "WorkTrack company \(salesIsolated(c.name)): \(salesIsolated(c.license.plan.rawValue)) licence, last day \(end)."))
                .font(.caption).foregroundStyle(.secondary)
        case .notListed:
            Label { Text("The linked company is not in the company list (deleted, or past its limit), so whether it is a TEST company is unknown.") }
                icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dueText(_ due: SalesDue) -> String {
        switch due {
        case .dueNow(0): String(localized: "Today, \(SalesFormat.day(today))")
        case .dueNow(let n): String(localized: "\(SalesFormat.day(SalesAccountRow.raw(account))), \(n) days overdue")
        case .dueSoon(let n), .later(let n): String(localized: "\(SalesFormat.day(SalesAccountRow.raw(account))), in \(n) days")
        case .dateUnknown(let raw): raw.map { String(localized: "Date not readable: \(salesIsolated($0))") } ?? String(localized: "Date not readable")
        }
    }

    private func dueColor(_ due: SalesDue) -> Color {
        switch due {
        case .dueNow(0): .green
        case .dueNow: .red
        case .dueSoon, .later: .blue
        case .dateUnknown: .orange
        }
    }

    static func raw(_ a: SalesAccount) -> String {
        if case .day(let d) = a.nextActionAt { d } else { "" }
    }
}

private struct SalesSignupRow: View {
    let signup: SalesSignup
    let today: String
    let console: URL?
    let isHighlighted: Bool
    @Environment(Router.self) private var router
    /// Nil in a preview: then nothing can be copied.
    @Environment(WorkTrackModel.self) private var worktrack: WorkTrackModel?
    @State private var drafting = false

    var body: some View {
        let name = signup.company.name
        VStack(alignment: .leading, spacing: 6) {
            FitRow(spacing: 8) {
                Text(verbatim: name).fontWeight(.semibold)
                switch signup.reason {
                case .newSignup(let day):
                    SalesPill(text: String(localized: "Signed up \(SalesFormat.day(day))"), symbol: "sparkles", color: .mint)
                case .selfServe:
                    SalesPill(text: String(localized: "Bought a plan itself"), symbol: "cart", color: .green)
                }
                if signup.isOnDeskAsRenewal {
                    SalesPill(text: String(localized: "On the Desk as a trial ending"), symbol: "checklist", color: .secondary)
                }
            }
            Text(verbatim: String(localized: "\(salesIsolated(signup.company.license.plan.rawValue)) licence, last day \(signup.company.license.expiresAt.map(SalesFormat.day) ?? String(localized: "no end date")). No contact on file: the vendor API never shows a company's own people."))
                .font(.caption).foregroundStyle(.secondary)
            FitRow(spacing: 14) {
                Button { drafting = true } label: { Label("Copy reminder draft…", systemImage: "doc.on.clipboard") }
                    .disabled(worktrack == nil)
                    .accessibilityLabel(Text("Copy reminder draft for \(name)…"))
                    .minTapTarget()
                Button { router.go(.worktrackCustomers, request: .worktrackCompany(signup.company.companyId)) } label: {
                    Label("Open in WorkTrack customers", systemImage: "person.2.badge.key")
                }
                .accessibilityLabel(Text("Open \(name) in WorkTrack customers"))
                .minTapTarget()
                if let console {
                    Link(destination: console) { Label("Console", systemImage: "arrow.up.forward.app") }
                        .help("Open WorkTrack console")
                        .accessibilityLabel(Text("Open WorkTrack console for \(name)"))
                        .minTapTarget()
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $drafting) {
            SalesDraftSheet(name: name, nameSource: .companies, kinds: [.welcome], license: nil, accountID: nil, today: today)
        }
    }
}

private struct SalesRenewalRow: View {
    let renewal: SalesRenewal
    let today: String
    @Environment(Router.self) private var router
    /// Nil in a preview: then nothing can be copied.
    @Environment(WorkTrackModel.self) private var worktrack: WorkTrackModel?
    @State private var drafting = false

    var body: some View {
        let c = renewal.company
        VStack(alignment: .leading, spacing: 6) {
            FitRow(spacing: 8) {
                Text(verbatim: c.name).fontWeight(.semibold)
                SalesPill(text: c.isTrial ? String(localized: "Trial") : salesIsolated(c.license.plan.rawValue), symbol: "key.horizontal", color: .secondary)
                // Days are "left" only while the licence is in force: an EXPIRED or SUSPENDED one shows its status and last day.
                switch renewal.timing {
                case .daysLeft(let days):
                    SalesPill(text: String(localized: "\(days) days left"), symbol: "clock", color: days <= 7 ? .orange : .blue)
                case .ended(let days):
                    SalesPill(text: String(localized: "Ended \(days) days ago"), symbol: "clock", color: .red)
                case .notInForce, .dayUnknown:
                    EmptyView()
                }
                if c.license.status != .active { SalesPill(text: salesIsolated(c.license.status.rawValue), symbol: "pause.circle", color: .orange) }
            }
            if let last = c.license.expiresAt {
                switch renewal.timing {
                case .daysLeft, .ended:
                    Text(verbatim: String(localized: "Last day \(SalesFormat.day(last)); days counted from today in Kabul.")).font(.caption).foregroundStyle(.secondary)
                case .notInForce, .dayUnknown:
                    Text(verbatim: String(localized: "Last day \(SalesFormat.day(last)).")).font(.caption).foregroundStyle(.secondary)
                }
            }
            FitRow(spacing: 14) {
                Button { drafting = true } label: { Label("Copy reminder draft…", systemImage: "doc.on.clipboard") }
                    .disabled(worktrack == nil)
                    .accessibilityLabel(Text("Copy reminder draft for \(c.name)…"))
                    .minTapTarget()
                Button { router.go(.worktrackCustomers, request: .worktrackCompany(c.companyId)) } label: {
                    Label("Open in WorkTrack customers", systemImage: "person.2.badge.key")
                }
                .accessibilityLabel(Text("Open \(c.name) in WorkTrack customers"))
                .minTapTarget()
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $drafting) {
            SalesDraftSheet(name: c.name, nameSource: .companies, kinds: SalesDraft.kinds(renewal: c, today: today), license: c.license,
                            accountID: nil, today: today)
        }
    }
}

private struct SalesMessageRow: View {
    let message: SiteMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: message.sender).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(verbatim: message.createdAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? message.createdAtText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.excerpt.isEmpty { Text(verbatim: message.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            FitRow(spacing: 14) {
                Link(destination: message.adminURL()) { Label("Open in wp-admin", systemImage: "safari") }.minTapTarget()
                if let reply = message.replyURL {
                    Link(destination: reply) { Label("Reply by email", systemImage: "arrowshape.turn.up.left") }.minTapTarget()
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Contacts (one GET, on demand)

/// One account's contacts, read when this opens and dropped when it closes. A number is copied only through the
/// concealed clipboard, never selectable text: a normal copy would reach clipboard managers and other devices.
private struct SalesContactsView: View {
    let accountID: String
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(\.dismiss) private var close
    @State private var contacts: WorkTrackModel.SalesContacts?
    @State private var error: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            Text("Contacts").font(.headline)
            #endif
            if let contacts {
                Text(verbatim: String(localized: "WorkTrack: GET /v1/vendor/crm/contacts · read \(contacts.readAt.formatted(date: .omitted, time: .shortened))"))
                    .font(.caption2).foregroundStyle(.tertiary)
                // Scrolls only when the contacts don't fit, so the confirmation below stays in view.
                ViewThatFits(in: .vertical) {
                    rows(contacts)
                    ScrollView { rows(contacts) }
                }
            } else if let error {
                SalesUnknownText(reason: error)
            } else {
                ProgressView().controlSize(.small)
            }
            if let copied { SalesNote(copied, symbol: "checkmark.circle", tint: .green) }
        }
        .padding(16)
        #if os(macOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
        #endif
        .task {
            do { contacts = try await worktrack.contacts(forAccount: accountID) } catch { self.error = error.localizedDescription }
        }
        .onDisappear { contacts = nil }
    }

    private func rows(_ contacts: WorkTrackModel.SalesContacts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if contacts.rows.isEmpty { SalesEmptyText("No contact on file") }
            ForEach(contacts.rows) { c in contactRow(c) }
            if contacts.skipped > 0 {
                SalesNote(String(localized: "\(contacts.skipped) contacts could not be read."), symbol: "exclamationmark.triangle", tint: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contactRow(_ c: WTSalesContact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FitRow(spacing: 8) {
                Text(verbatim: c.name).fontWeight(.semibold)
                if let role = c.role, !role.isEmpty { Text(verbatim: role).font(.caption).foregroundStyle(.secondary) }
                if c.primary { SalesPill(text: String(localized: "Primary"), symbol: "star.fill", color: .yellow) }
            }
            if let phone = c.phone?.trimmingCharacters(in: .whitespaces), !phone.isEmpty {
                FitRow(spacing: 10) {
                    Text(verbatim: phone).monospacedDigit().environment(\.layoutDirection, .leftToRight)
                    Button {
                        worktrack.copyConcealed(phone)
                        copied = String(localized: "Copied. The clipboard is cleared in 2 minutes.")
                    } label: { Label("Copy number", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy the number of \(c.name)"))
                        .minTapTarget()
                }
            } else {
                Text("No number on file").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Reminder draft (copied, never sent)

/// Where a draft's name was read.
enum SalesNameSource {
    /// A listed WorkTrack company's name.
    case companies
    /// The CRM account's own name (a prospect, or a company not in the list).
    case accounts

    var text: LocalizedStringKey {
        switch self {
        case .companies: "WorkTrack: GET /v1/vendor/companies"
        case .accounts: "WorkTrack: GET /v1/vendor/crm/accounts"
        }
    }
}

private struct SalesDraftSheet: View {
    let name: String
    let nameSource: SalesNameSource
    let kinds: [SalesDraftKind]
    let license: WTLicense?
    /// The CRM account whose contacts can be read for the greeting; nil when there is none.
    let accountID: String?
    let today: String

    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(\.dismiss) private var close
    @State private var kind: SalesDraftKind?
    @State private var language: SalesDraftLanguage = .dari
    @State private var contact = ""
    @State private var contacts: WorkTrackModel.SalesContacts?
    @State private var contactsError: String?
    @State private var copied = false

    private var chosen: SalesDraftKind { kind ?? kinds.first ?? .followUp }
    private var facts: SalesDraftFacts {
        SalesDraftFacts(name: name, contact: contact.isEmpty ? nil : contact, license: license, today: today)
    }
    private var text: String? { SalesDraft.text(chosen, language: language, facts: facts) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: Binding(get: { chosen }, set: { kind = $0; copied = false })) {
                        ForEach(kinds) { Text(verbatim: $0.title).tag($0) }
                    }
                    Picker("Language", selection: Binding(get: { language }, set: { language = $0; copied = false })) {
                        ForEach(SalesDraftLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    contactPicker
                }
                Section("Preview") {
                    if let text {
                        Text(verbatim: text)
                            .environment(\.layoutDirection, .rightToLeft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        SalesUnknownText(reason: String(localized: "This draft needs a fact that was not read, or the licence no longer allows it today."))
                    }
                }
                Section("Facts used") {
                    // Only what this draft states: a request for a call names no one.
                    if chosen.usesName {
                        LabeledContent("Name") { Text(verbatim: name) }
                        Text(nameSource.text).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !contact.isEmpty {
                        LabeledContent("Contact") { Text(verbatim: contact) }
                        Text("WorkTrack: GET /v1/vendor/crm/contacts").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if chosen.isDated, let last = license?.expiresAt {
                        LabeledContent("Last day of the licence") {
                            Text(verbatim: "\(SalesDraft.day(last, language: language) ?? last) (\(salesIsolated(last)))")
                        }
                        Text("WorkTrack: license.expiresAt, counted from today in Kabul").font(.caption2).foregroundStyle(.tertiary)
                    }
                    LabeledContent("Today in Kabul") { Text(verbatim: "\(SalesFormat.day(today)) (\(salesIsolated(today)))") }
                }
                Section {
                    if copied {
                        SalesNote(String(localized: "Copied. Nothing was sent; paste it yourself. The clipboard is cleared in 2 minutes."),
                                  symbol: "checkmark.circle", tint: .green)
                    } else {
                        Text("Nothing is sent from here. Copy, then paste it into your own message.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reminder draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        guard let text else { return }
                        worktrack.copyConcealed(text)
                        copied = true
                    }
                    .disabled(text == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private var contactPicker: some View {
        if let contacts {
            Picker("Contact", selection: Binding(get: { contact }, set: { contact = $0; copied = false })) {
                Text("No name").tag("")
                ForEach(contacts.rows) { Text(verbatim: $0.name).tag($0.name) }
            }
        } else if let accountID {
            Button { Task { await readContacts(accountID) } } label: { Label("Read contacts for the greeting (one GET)", systemImage: "person.crop.circle") }
                .disabled(worktrack.isRefreshing || worktrack.isSalesReading)
            if let contactsError { SalesUnknownText(reason: contactsError) }
        } else {
            Text("No contact on file: the greeting has no name.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func readContacts(_ id: String) async {
        do { contacts = try await worktrack.contacts(forAccount: id) } catch { contactsError = error.localizedDescription }
    }
}

// MARK: - The CRM answer's shape (the owner's one check)

/// One `GET /v1/vendor/crm/accounts`, shown as key names, JSON types and counts. No value is kept or shown.
struct SalesShapeSheet: View {
    @Environment(WorkTrackModel.self) private var worktrack
    @Environment(\.dismiss) private var close
    @State private var report: WTShapeReport?
    @State private var error: String?
    @State private var isReading = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Reads WorkTrack's CRM accounts once and keeps only key names, JSON types and counts, never a value. Run it once on production after this change; record the counts in docs/sales.md.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let env = worktrack.environment { LabeledContent("Environment") { WorkTrackEnvironmentBadge(environment: env) } }
                    Button { Task { await check() } } label: { Label("Check the CRM answer (one GET)", systemImage: "checklist") }
                        .disabled(isReading || worktrack.isRefreshing || worktrack.isSalesReading || !worktrack.isSignedIn)
                    if isReading { ProgressView().controlSize(.small) }
                    if let error { SalesUnknownText(reason: error) }
                }
                if let report {
                    Section {
                        LabeledContent("Rows") { Text(report.rows, format: .number) }
                        LabeledContent("Read") { Text(report.readAt.formatted(date: .abbreviated, time: .shortened)) }
                        if report.differences.isEmpty {
                            Label("The answer is what Sales expects.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                        ForEach(Array(report.differences.enumerated()), id: \.offset) { _, d in
                            Label { Text(verbatim: d) } icon: { Image(systemName: "xmark.octagon.fill") }.foregroundStyle(.red)
                        }
                    }
                    Section("Fields") {
                        ForEach(report.fields) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(verbatim: f.name).font(.callout.monospaced()).environment(\.layoutDirection, .leftToRight)
                                    Spacer()
                                    if f.differing > 0 {
                                        Text(verbatim: String(localized: "\(f.differing) differ")).foregroundStyle(.red).font(.caption)
                                    }
                                }
                                Text(verbatim: String(localized: "Expected: \(f.expected.text). Present in \(f.present), null in \(f.null); \(typesText(f.types))"))
                                    .font(.caption).foregroundStyle(f.differing > 0 ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("CRM answer")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    private func typesText(_ types: [String: Int]) -> String {
        types.isEmpty ? String(localized: "no values")
            : types.keys.sorted().map { "\($0) \(types[$0]!)" }.joined(separator: ", ")
    }

    private func check() async {
        isReading = true
        defer { isReading = false }
        error = nil
        do { report = try await worktrack.checkCRMShape() } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Parts

/// A code or a Latin name set apart for the bidi algorithm, so a Dari line that holds one still reads right to left. The
/// same isolation the drafts use.
func salesIsolated(_ text: String) -> String { SalesDraft.isolated(text) }

/// "WorkTrack (production) · GET … · read …".
private func salesSource(_ reference: String, environment: String, at: Date) -> String {
    String(localized: "WorkTrack (\(environment)) · \(reference) · read \(at.formatted(date: .abbreviated, time: .shortened))")
}

/// A soft frosted card with a title, an optional count pill and its source line.
private struct SalesCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = .accentColor
    var count: Int?
    /// The count is a floor: rows past a limit, or set aside, were not read.
    var atLeast = false
    var caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title and count are one header for VoiceOver ("Call today, 3 items").
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                    .font(.headline)
                if let count {
                    Text(verbatim: atLeast ? String(localized: "At least \(count.formatted())") : count.formatted())
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(tint.opacity(0.15), in: Capsule())
                        .accessibilityLabel(atLeast ? Text("at least \(count) items") : Text("\(count) items"))
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if let caption {
                Text(verbatim: caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
    }
}

/// A soft pill: icon and text on a tinted capsule, so colour never carries meaning alone. One line at ordinary text
/// sizes; at the accessibility sizes it wraps instead of running off an iPhone's screen.
private struct SalesPill: View {
    let text: String
    let symbol: String
    let color: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: typeSize.isAccessibilitySize ? 10 : 20, style: .continuous))
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct SalesNote: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    init(_ text: String, symbol: String = "info.circle", tint: Color = .secondary) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Unknown, with its reason: never shown as empty or zero. The reason can be selected (and copied) on the Mac; on iOS a
/// selectable Text inside the page drew nothing at all (seen on the iOS 27.2 Simulator), so there it is plain text.
private struct SalesUnknownText: View {
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SalesPill(text: String(localized: "Unknown"), symbol: "questionmark.circle", color: .gray)
            #if os(macOS)
            Text(verbatim: reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            #else
            Text(verbatim: reason).font(.callout).foregroundStyle(.secondary)
            #endif
        }
    }
}

private struct SalesEmptyText: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }

    var body: some View {
        Text(key).font(.callout).foregroundStyle(.secondary)
    }
}

/// A list's empty sentence when every row was read. When some may be missing (`missing` says why): an empty list is
/// Unknown with the reason, and a list with rows says why it may hold more.
private struct SalesCompleteness: View {
    let isEmpty: Bool
    let empty: LocalizedStringKey
    let missing: [String]

    var body: some View {
        if missing.isEmpty {
            if isEmpty { SalesEmptyText(empty) }
        } else if isEmpty {
            SalesUnknownText(reason: missing.joined(separator: " "))
        } else {
            ForEach(missing, id: \.self) { SalesNote($0, symbol: "exclamationmark.triangle", tint: .orange) }
        }
    }
}

// MARK: - Previews and the debug screenshot aid

#if DEBUG
/// Made-up data (SAMPLE, نمونه) for the previews and the debug-only `-LCCSalesSample <read|skipped|unknown|demo>` launch
/// argument (with `-LCCScreen sales`, and `-LCCSalesScroll` to scroll). Nothing is read: no model, no request, and the
/// app starts no job.
enum SalesPreviewData {
    /// 2026-10-20 12:30 in Kabul.
    static let now = ISO8601DateFormatter().date(from: "2026-10-20T08:00:00Z")!

    /// The sample named by `-LCCSalesSample`, if any.
    static var launchSample: SalesReport? {
        UserDefaults.standard.string(forKey: "LCCSalesSample").flatMap(report)
    }

    /// `-LCCSalesScroll 0.5` opens the page scrolled halfway (0 top, 1 bottom), so a screenshot can show any card.
    static var launchScrollAnchor: UnitPoint? {
        let d = UserDefaults.standard
        return d.object(forKey: "LCCSalesScroll") == nil ? nil : UnitPoint(x: 0.5, y: d.double(forKey: "LCCSalesScroll"))
    }

    static func report(_ sample: String) -> SalesReport? {
        input(sample).map { SalesBuilder.build($0, now: now) }
    }

    @MainActor
    static func preview(_ sample: String) -> some View {
        NavigationStack { SalesPage(report: report(sample)!) }
            .environment(Router())
    }

    private static func company(_ id: String, _ name: String, tier: String = "SILVER", status: String = "ACTIVE", expiresAt: String?,
                                createdAt: String = "2026-01-10T05:00:00.000Z", source: String = "VENDOR") -> String {
        let end = expiresAt.map { "\"\($0)\"" } ?? "null"
        // As the server counts it, from Kabul's today.
        let days = expiresAt.flatMap { WorkTrackDates.daysBetween("2026-10-20", $0) }.map(String.init) ?? "null"
        return #"{"companyId":"\#(id)","name":"\#(name)","status":"ACTIVE","license":{"plan":"\#(tier)","deviceLimit":20,"status":"\#(status)","expiresAt":\#(end),"enforceDevices":false,"enforcePlan":false,"employeeLimit":null,"extraFeatures":[],"source":"\#(source)"},"devicesInUse":0,"employeeCount":0,"employeesCounted":0,"employeeCap":20,"daysUntilExpiry":\#(days),"createdAt":"\#(createdAt)","lastActivityAt":null,"deletion":null,"flags":null,"duplicates":[],"attention":[]}"#
    }

    static let companies: [WTCompany] = {
        let rows = [
            company("c_kabul", "Kabul Tailors (SAMPLE)", expiresAt: "2026-11-04"),
            company("c_herat", "خیاطی هرات (نمونه)", tier: "TRIAL", expiresAt: "2026-10-27", createdAt: "2026-10-13T06:00:00.000Z"),
            company("c_mazar", "Mazar Stitch (SAMPLE)", tier: "GOLD", status: "EXPIRED", expiresAt: "2026-11-15"),
            company("c_bamyan", "Bamyan Workshop (SAMPLE)", tier: "BRONZE", expiresAt: "2026-10-12"),
            company("c_kandahar", "Kandahar Cuts (SAMPLE)", expiresAt: "2027-04-01", createdAt: "2026-04-01T06:00:00.000Z", source: "SELF_SERVE"),
            company("c_old", "Old Shop (SAMPLE)", expiresAt: "2027-02-01"),
        ]
        return (try? JSONDecoder().decode([WTCompany].self, from: Data("[\(rows.joined(separator: ","))]".utf8))) ?? []
    }()

    static let accounts: [WTCrmAccount] = [
        WTCrmAccount(id: "a_kabul", name: "Kabul Tailors (SAMPLE)", companyId: "c_kabul", stage: .lead, nextActionAt: .day("2026-10-20"),
                     nextAction: "Call about the renewal (SAMPLE)"),
        WTCrmAccount(id: "a_jalalabad", name: "Jalalabad Fabrics (SAMPLE)", stage: .contacted, nextActionAt: .day("2026-10-15"),
                     nextAction: "Send the price list (SAMPLE)"),
        WTCrmAccount(id: "a_parwan", name: "خیاطی پروان (نمونه)", stage: .demo, nextActionAt: .day("2026-10-23")),
        WTCrmAccount(id: "a_bamyan", name: "Bamyan Workshop (SAMPLE)", companyId: "c_bamyan", stage: .won, nextActionAt: .day("2026-11-10")),
        WTCrmAccount(id: "a_mazar", name: "Mazar Stitch (SAMPLE)", companyId: "c_mazar", stage: .quoted),
        WTCrmAccount(id: "a_ghazni", name: "Ghazni Tailors (SAMPLE)", stage: .lead, nextActionAt: .notADay("2026-02-31")),
    ]

    static func input(_ sample: String) -> SalesInput? {
        let kyc = SalesKYCInput(isSignedIn: true, environment: "production", pendingCount: 7,
                                queueRoles: ["PROVIDER", "CUSTOMER", "PROVIDER", "CUSTOMER", "PROVIDER", "CUSTOMER", "CUSTOMER"], readAt: now)
        func worktrack(_ environment: String, skipped: Int = 0) -> MoneyWorkTrackInput {
            let unused = "not used by Sales"
            let money = WorkTrackMoneyRead(revenue: .failed(unused, at: now, needsSignIn: false),
                                           accounts: .read(WTLossyList(rows: accounts, skipped: skipped), at: now),
                                           invoices: .failed(unused, at: now, needsSignIn: false))
            return MoneyWorkTrackInput(isSignedIn: true, environment: environment, companies: companies, companiesReadAt: now, money: money)
        }
        switch sample {
        case "read": return SalesInput(worktrack: worktrack("production"), kyc: kyc)
        case "skipped": return SalesInput(worktrack: worktrack("production", skipped: 2), kyc: kyc)
        case "demo": return SalesInput(worktrack: worktrack("demo"), kyc: kyc)
        case "unknown":
            return SalesInput(worktrack: MoneyWorkTrackInput(isSignedIn: false, environment: nil),
                              kyc: SalesKYCInput(isSignedIn: false, environment: nil))
        default: return nil
        }
    }
}

#Preview("Sales, read") { SalesPreviewData.preview("read") }

#Preview("Sales, accounts set aside") { SalesPreviewData.preview("skipped") }

#Preview("Sales, Unknown") { SalesPreviewData.preview("unknown") }

#Preview("Sales, not production") { SalesPreviewData.preview("demo") }

#Preview("Sales, Dari (right to left)") {
    SalesPreviewData.preview("read")
        .environment(\.locale, Locale(identifier: "fa_AF"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Sales, iPhone width", traits: .fixedLayout(width: 393, height: 852)) {
    SalesPreviewData.preview("skipped")
        .environment(\.locale, Locale(identifier: "fa_AF"))
        .environment(\.layoutDirection, .rightToLeft)
}
#endif
