import LinumicCore
import SwiftUI
import UniformTypeIdentifiers

/// Wraps left-to-right content (licence ids, machine codes, keys) so it keeps its order inside Dari text.
func ltr(_ s: String) -> String { "\u{2066}\(s)\u{2069}" }

// MARK: - Badges

/// What the ledger says now, derived for display: Active / Expiring / Expired / Superseded / Void.
/// Icon + text, never colour alone.
struct LicenceStateBadge: View {
    let record: LicenceRecord

    private var look: (text: String, symbol: String, color: Color) {
        switch record.status {
        case .void: (String(localized: "Void"), "xmark.circle", .gray)
        case .superseded: (String(localized: "Superseded"), "arrow.triangle.2.circlepath", .indigo)
        case .active:
            if record.isExpired() { (String(localized: "Expired"), "exclamationmark.octagon.fill", .red) }
            else if record.isExpiring(within: 30) { (String(localized: "Expiring"), "clock.badge.exclamationmark", .orange) }
            else { (String(localized: "Active"), "checkmark.seal.fill", .green) }
        }
    }

    var body: some View {
        let l = look
        HStack(spacing: 4) {
            Image(systemName: l.symbol).foregroundStyle(l.color)
            Text(verbatim: l.text).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(l.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(l.color.opacity(0.5), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Licence status: \(l.text)"))
    }
}

/// "Perpetual", "Ends in 12 days", "Ended 3 days ago", or the date.
struct LicenceExpiryText: View {
    let record: LicenceRecord

    var body: some View {
        if record.expires == nil {
            Text("Perpetual")
        } else if let days = record.daysUntilExpiry(), record.status == .active {
            if days > 30 { Text(verbatim: formatted(record.expires)) }
            else if days > 1 { Text("Ends in \(days) days") }
            else if days == 1 { Text("Ends tomorrow") }
            else if days == 0 { Text("Last day today") }
            else { Text("Ended \(-days) days ago") }
        } else {
            Text(verbatim: formatted(record.expires))
        }
    }
}

/// A licence date (`YYYY-MM-DD`, Gregorian) in the UI's calendar.
func formatted(_ licenceDate: String?) -> String {
    guard let s = licenceDate else { return "" }
    return LicenceDate.date(from: s)?.formatted(date: .abbreviated, time: .omitted) ?? s
}

// MARK: - List

struct LicencesView: View {
    @Environment(LicenceModel.self) private var licences
    @State private var product: LicenceProduct?
    @State private var status: LicenceStatus?
    @State private var expiringOnly = false
    @State private var search = ""
    @State private var path: [String] = []
    @State private var isIssuing = false
    @State private var importSummary: String?
    #if os(iOS)
    @State private var isImporting = false
    @State private var isExporting = false
    #endif

    private var filtered: [LicenceRecord] {
        licences.records.filter { r in
            (product == nil || r.product == product)
                && (status == nil || r.status == status)
                && (!expiringOnly || r.isExpiring(within: 30))
                && (search.isEmpty || r.customer.localizedStandardContains(search) || r.licenceID.localizedStandardContains(search)
                    || r.machine.localizedStandardContains(search) || r.notes.localizedStandardContains(search))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { overview }
                #if os(macOS)
                Section {
                    ForEach(LicenceProduct.allCases) { SigningKeyRow(product: $0) }
                } header: {
                    Text("Signing keys")
                } footer: {
                    Text("Kept only in this Mac's Keychain (this device, not synced). Never uploaded to Supabase or written to the ledger.")
                }
                #else
                Section {
                    Label("Issuing new licences is available in Linumic OS on the Mac, where the signing keys are kept. Here you can see the ledger.", systemImage: "laptopcomputer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                #endif
                Section {
                    filters
                    if licences.records.isEmpty {
                        ContentUnavailableView {
                            Label("No licences yet", systemImage: "key.horizontal")
                        } description: {
                            Text(LicenceModel.canIssue
                                 ? "Issue a licence, or import issued.csv from the terminal tool."
                                 : "Licences issued on the Mac appear here after they sync.")
                        }
                    } else if filtered.isEmpty {
                        Text("No licences match these filters.").foregroundStyle(.secondary)
                    } else {
                        ForEach(filtered) { r in
                            NavigationLink(value: r.licenceID) { LicenceRow(record: r) }
                        }
                    }
                } header: {
                    Text("Ledger")
                }
            }
            .navigationTitle("Licences")
            .navigationDestination(for: String.self) { LicenceDetailView(licenceID: $0, path: $path) }
            .searchable(text: $search, prompt: Text("Customer, licence id or machine code"))
            .toolbar { toolbar }
            .refreshable { await licences.sync() }
        }
        .sheet(isPresented: $isIssuing) {
            IssueLicenceSheet(renewing: nil) { issued in path = [issued.licenceID] }
        }
        .alert("Import", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(verbatim: importSummary ?? "")
        }
        .alert("Licences", isPresented: Binding(get: { licences.errorMessage != nil }, set: { if !$0 { licences.errorMessage = nil } })) {
            Button("OK") { licences.errorMessage = nil }
        } message: {
            Text(verbatim: licences.errorMessage ?? "")
        }
        #if os(iOS)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, LicenceFiles.lnmlicType, .plainText], allowsMultipleSelection: true) { result in
            do {
                let files = try result.get().map { ($0.lastPathComponent, try LicenceFiles.read($0)) }
                importSummary = licences.importFiles(files)
            } catch {
                importSummary = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $isExporting, document: LicenceTextDocument(text: licences.exportCSV()),
                      contentType: .commaSeparatedText, defaultFilename: "linumic-licences.csv") { _ in }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if LicenceModel.canIssue {
            ToolbarItem(placement: .primaryAction) {
                Button { isIssuing = true } label: { Label("Issue Licence", systemImage: "plus") }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .help("Sign a new licence for a customer's machine code")
            }
        }
        ToolbarItem {
            Menu {
                Button { importLedger() } label: { Label("Import issued.csv…", systemImage: "square.and.arrow.down") }
                Button { exportLedger() } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }
                    .disabled(licences.records.isEmpty)
                Divider()
                Button { Task { await licences.sync() } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(licences.isSyncing)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func importLedger() {
        #if os(macOS)
        do {
            let files = try LicenceFiles.chooseLedgerFiles()
            if !files.isEmpty { importSummary = licences.importFiles(files) }
        } catch {
            importSummary = error.localizedDescription
        }
        #else
        isImporting = true
        #endif
    }

    private func exportLedger() {
        #if os(macOS)
        do { try LicenceFiles.save(licences.exportCSV(), suggestedName: "linumic-licences.csv", type: .commaSeparatedText) } catch {
            licences.errorMessage = error.localizedDescription
        }
        #else
        isExporting = true
        #endif
    }

    // MARK: Overview

    private var overview: some View {
        let s = licences.summary
        return VStack(alignment: .leading, spacing: 10) {
            FitRow(spacing: 16) {
                ForEach(LicenceProduct.allCases) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: p.displayName).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(s.activeByProduct[p, default: 0]) active").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expiring in 30 days").font(.subheadline).foregroundStyle(.secondary)
                    Text(s.expiringSoon.count, format: .number).font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(s.expiringSoon.isEmpty ? Color.primary : .orange)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            syncLine
            if !licences.conflicts.isEmpty {
                Label("These licence ids exist on the server with different contents, so the server copy was kept: \(licences.conflicts.joined(separator: ", ")).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var syncLine: some View {
        Group {
            if licences.isSyncing {
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
            } else {
                switch licences.syncState {
                case .localOnly:
                    Label("This device only. Sign in under Settings › Account to share the ledger with your other devices.", systemImage: "internaldrive")
                case .synced(let at):
                    Label("Synced \(at.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.icloud")
                case .offline(let why):
                    Label("Offline, showing this device's copy: \(why)", systemImage: "icloud.slash")
                case .pendingUpload(let why):
                    Label("Changes waiting to upload: \(why)", systemImage: "arrow.clockwise.icloud")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var filters: some View {
        FitRow(spacing: 12) {
            Picker("Product", selection: $product) {
                Text("All products").tag(LicenceProduct?.none)
                ForEach(LicenceProduct.allCases) { Text(verbatim: $0.displayName).tag(Optional($0)) }
            }
            .fixedSize()
            Picker("Status", selection: $status) {
                Text("Any status").tag(LicenceStatus?.none)
                ForEach(LicenceStatus.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .fixedSize()
            Toggle("Expiring in 30 days", isOn: $expiringOnly)
                .fixedSize()
        }
    }
}

private struct LicenceRow: View {
    let record: LicenceRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: record.customer).fontWeight(.medium)
                Text(verbatim: "\(record.product.displayName) · \(ltr(record.licenceID)) · \(ltr(record.machine))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                LicenceStateBadge(record: record)
                LicenceExpiryText(record: record).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
/// One product's signing key: present or missing, the public-key fingerprint, import / remove.
private struct SigningKeyRow: View {
    let product: LicenceProduct
    @Environment(LicenceModel.self) private var licences
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        let present = licences.hasKey(product)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(verbatim: product.displayName).fontWeight(.medium)
                StatusBadge(text: present ? String(localized: "Key present") : String(localized: "Key missing"), color: present ? .green : .orange)
                Spacer()
                if present {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                } else {
                    Button("Import Signing Key…") { importKey() }
                }
            }
            Text("Public key fingerprint (SHA-256): \(ltr(KeyFingerprint.short(product.productionPublicKey)))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(KeyFingerprint.sha256Hex(product.productionPublicKey))
            if let message {
                Text(verbatim: message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove the \(product.displayName) signing key from this Mac?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) {
                do { try licences.removeKey(for: product); message = nil } catch { message = error.localizedDescription }
            }
        } message: {
            Text("Issued licences keep working. You need the key file (or its encrypted backup) to issue again.")
        }
    }

    private func importKey() {
        do {
            guard let pem = try LicenceFiles.chooseSigningKey(for: product.displayName) else { return }
            try licences.importKey(pem: pem, for: product)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
#endif

// MARK: - Detail

struct LicenceDetailView: View {
    let licenceID: String
    @Binding var path: [String]
    @Environment(LicenceModel.self) private var licences
    @State private var notes = ""
    @State private var isRenewing = false
    @State private var isVoiding = false
    @State private var voidReason = ""

    var body: some View {
        if let r = licences.record(licenceID: licenceID) {
            Form {
                Section {
                    LabeledContent("Status") { LicenceStateBadge(record: r) }
                    LabeledContent("Customer") { Text(verbatim: r.customer).textSelection(.enabled) }
                    LabeledContent("Product") { Text(verbatim: r.product.displayName) }
                    LabeledContent("Machine code") {
                        Text(verbatim: r.machine == "*" ? String(localized: "Any machine (*)") : ltr(r.machine))
                            .font(.body.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Issued") { Text(verbatim: "\(formatted(r.issued))  (\(ltr(r.issued)))") }
                    LabeledContent("Last valid day") {
                        if let e = r.expires {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(verbatim: "\(formatted(e))  (\(ltr(e)))")
                                LicenceExpiryText(record: r).font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Perpetual")
                        }
                    }
                    LabeledContent("Edition") { Text(verbatim: r.edition) }
                    LabeledContent("Features") {
                        if let f = r.features { Text(verbatim: f == ["*"] ? String(localized: "All (*)") : f.joined(separator: ", ")) } else { UnknownLabel() }
                    }
                    if let from = r.renewedFrom {
                        LabeledContent("Renews") {
                            Button(ltr(from)) { path.append(from) }.buttonStyle(.borderless).disabled(licences.record(licenceID: from) == nil)
                        }
                    }
                    ForEach(licences.successors(of: r)) { s in
                        LabeledContent("Replaced by") {
                            Button(ltr(s.licenceID)) { path.append(s.licenceID) }.buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text(verbatim: ltr(r.licenceID)).font(.headline.monospaced())
                }

                Section {
                    if let key = r.keyText {
                        keyVerification(key, product: r.product)
                        Text(verbatim: key)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                            .lineLimit(6)
                        KeyActions(key: key, licenceID: r.licenceID)
                    } else {
                        UnknownLabel()
                        Text("The key wasn't recorded (issued.csv doesn't contain it). Import the matching .lnmlic file from ~/.linumic/licenses to attach it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Licence key")
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                    Button("Save Notes") { licences.updateNotes(r, notes: notes) }
                        .disabled(notes == r.notes)
                }

                Section {
                    LabeledContent("Recorded by") { Text(verbatim: r.createdBy) }
                    LabeledContent("Recorded") { Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                    LabeledContent("Last changed") { Text(r.updatedAt.formatted(date: .abbreviated, time: .shortened)) }
                } header: {
                    Text("Record")
                }

                Section {
                    if r.status == .active {
                        if LicenceModel.canIssue {
                            Button { isRenewing = true } label: { Label("Renew or Re-issue…", systemImage: "arrow.clockwise") }
                        } else {
                            Text("Renewing is available on the Mac.").foregroundStyle(.secondary)
                        }
                    }
                    if r.status != .void {
                        Button(role: .destructive) { voidReason = ""; isVoiding = true } label: { Label("Void in Ledger…", systemImage: "xmark.circle") }
                    }
                } footer: {
                    Text("Offline keys can't be recalled. Voiding only marks the licence in your ledger; the customer's app keeps accepting a valid key until it expires.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: r.customer))
            .onAppear { notes = r.notes }
            .onChange(of: r.notes) { notes = r.notes }
            .sheet(isPresented: $isRenewing) {
                IssueLicenceSheet(renewing: r) { issued in path.append(issued.licenceID) }
            }
            .alert("Void \(r.licenceID)?", isPresented: $isVoiding) {
                TextField("Reason (optional)", text: $voidReason)
                Button("Void", role: .destructive) { licences.void(r, reason: voidReason) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only changes your ledger. The key can't be recalled: the customer's app keeps working until the licence expires.")
            }
        } else {
            ContentUnavailableView("Licence not found", systemImage: "questionmark.circle")
        }
    }

    @ViewBuilder private func keyVerification(_ key: String, product: LicenceProduct) -> some View {
        if (try? LicenceKey.verify(key, product: product)) != nil {
            Label("Signature verified with the \(product.displayName) public key built into the app.", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("This key doesn't verify with the built-in \(product.displayName) public key.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

/// Copy, Save as .lnmlic, Share.
private struct KeyActions: View {
    let key: String
    let licenceID: String
    @State private var copied = false
    #if os(iOS)
    @State private var isExporting = false
    #endif
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FitRow(spacing: 10) {
                Button { LicenceFiles.copy(key); copied = true } label: {
                    Label(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button { save() } label: { Label("Save .lnmlic…", systemImage: "square.and.arrow.down") }
                ShareLink(item: key, subject: Text(verbatim: licenceID), message: Text(verbatim: licenceID)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
        }
        #if os(iOS)
        .fileExporter(isPresented: $isExporting, document: LicenceTextDocument(text: key + "\n"),
                      contentType: LicenceFiles.lnmlicType, defaultFilename: "\(licenceID).lnmlic") { _ in }
        #endif
    }

    private func save() {
        #if os(macOS)
        do { try LicenceFiles.save(key + "\n", suggestedName: "\(licenceID).lnmlic", type: LicenceFiles.lnmlicType) } catch {
            self.error = error.localizedDescription
        }
        #else
        isExporting = true
        #endif
    }
}

// MARK: - Issue / Renew

/// Issue a new licence, or renew / re-issue an existing one (`renewing`). After signing it shows the key.
struct IssueLicenceSheet: View {
    let renewing: LicenceRecord?
    var onDone: (LicenceRecord) -> Void = { _ in }
    @Environment(LicenceModel.self) private var licences
    @Environment(\.dismiss) private var dismiss

    @State private var product: LicenceProduct = .mediflow
    @State private var customer = ""
    @State private var machine = ""
    @State private var perpetual = false
    @State private var expiry = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    @State private var edition = "standard"
    @State private var notes = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var issued: LicenceRecord?

    private var machineCheck: MachineCode.Check { MachineCode.check(machine) }
    private var canSign: Bool {
        licences.hasKey(product) && machineCheck.normalized != nil
            && !customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
            && (perpetual || LicenceDate.string(from: expiry) >= LicenceDate.string(from: .now))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(issued != nil ? "Licence issued" : renewing == nil ? "Issue Licence" : "Renew or Re-issue")
                .font(.headline).padding()
            if let issued {
                IssuedKeyView(record: issued)
                HStack {
                    Spacer()
                    Button("Done") { dismiss(); onDone(issued) }.keyboardShortcut(.defaultAction)
                }
                .padding()
            } else {
                form
                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(renewing == nil ? "Sign and Issue" : "Sign Renewal") { Task { await sign() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSign)
                }
                .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear(perform: prefill)
    }

    private var form: some View {
        Form {
            if let old = renewing {
                Section {
                    LabeledContent("Renews") { Text(verbatim: "\(ltr(old.licenceID)) · \(old.customer)") }
                    Text("\(ltr(old.licenceID)) will be marked superseded. Its key keeps working in the customer's app until it expires.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker("Product", selection: $product) {
                        ForEach(LicenceProduct.allCases) { Text(verbatim: $0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Customer (clinic or workshop)", text: $customer)
                }
            }
            if !licences.hasKey(product) {
                Section {
                    Label("No \(product.displayName) signing key on this Mac. Import it under Licences › Signing keys first.", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                TextField("Machine code", text: $machine, prompt: Text(verbatim: "K7Q2-9XMB-4T1D-WP3C"))
                    .font(.body.monospaced())
                    .environment(\.layoutDirection, .leftToRight)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                machineFeedback
            } header: {
                Text("Machine")
            } footer: {
                Text(renewing == nil
                     ? "The code the customer reads from the licence screen of the app. KhayatYar: from the main device of the workshop. * means any machine."
                     : "Keep the code to renew. Enter the new code if the customer changed computer or phone.")
            }
            Section {
                Picker("Validity", selection: $perpetual) {
                    Text("Until a date").tag(false)
                    Text("Perpetual").tag(true)
                }
                .pickerStyle(.segmented)
                if !perpetual {
                    HStack {
                        DatePicker("Last valid day", selection: $expiry, in: Date.now..., displayedComponents: .date)
                        Button("+1 Year") { expiry = Calendar.current.date(byAdding: .year, value: 1, to: expiry) ?? expiry }
                    }
                    Text("Recorded as \(ltr(LicenceDate.string(from: expiry))) (the customer's app counts down from it, with 30 days of grace after).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Expiry")
            }
            Section {
                if renewing == nil {
                    TextField("Edition", text: $edition)
                }
                TextField("Notes (ledger only, not in the key)", text: $notes, axis: .vertical).lineLimit(2...4)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var machineFeedback: some View {
        switch machineCheck {
        case .valid(let code):
            if code == "*" {
                Label("Any machine (*): the key works on every device. Use only when you mean it.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Valid: \(ltr(code))", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
        case .empty:
            EmptyView()
        case .incomplete(let n):
            Label("\(n) of 16 characters", systemImage: "ellipsis.circle").font(.caption).foregroundStyle(.secondary)
        case .tooLong(let n):
            Label("\(n) characters; a machine code has 16", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        case .invalidCharacter(let c):
            Label("“\(String(c))” can't appear in a machine code", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    private func prefill() {
        guard let old = renewing else { return }
        product = old.product
        customer = old.customer
        machine = old.machine
        edition = old.edition
        if let e = old.expires, let next = LicenceDate.adding(years: 1, to: e), let d = LicenceDate.date(from: next), d > .now {
            expiry = d
        }
        perpetual = old.expires == nil
    }

    private func sign() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        let expires = perpetual ? nil : LicenceDate.string(from: expiry)
        do {
            if let old = renewing {
                issued = try await licences.renew(old, expires: expires, machine: machine, notes: notes)
            } else {
                let request = LicenceRequest(product: product, customer: customer, machine: machine, expires: expires,
                                             edition: edition, notes: notes)
                issued = try await licences.issue(request)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The freshly signed key with Copy / Save / Share.
private struct IssuedKeyView: View {
    let record: LicenceRecord

    var body: some View {
        Form {
            Section {
                LabeledContent("Licence") { Text(verbatim: ltr(record.licenceID)).font(.body.monospaced()) }
                LabeledContent("Customer") { Text(verbatim: record.customer) }
                LabeledContent("Machine code") { Text(verbatim: ltr(record.machine)).font(.body.monospaced()) }
                LabeledContent("Last valid day") {
                    if let e = record.expires { Text(verbatim: formatted(e)) } else { Text("Perpetual") }
                }
            }
            if let key = record.keyText {
                Section {
                    Label("Signed and verified with the built-in public key. Send this key (or the .lnmlic file) to the customer.", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                    Text(verbatim: key)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                    KeyActions(key: key, licenceID: record.licenceID)
                } header: {
                    Text("Licence key")
                }
            }
        }
        .formStyle(.grouped)
    }
}
