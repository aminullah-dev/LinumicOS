import LinumicCore
import SwiftUI

// MARK: - Continuity screen (تداوم)

/// One encrypted copy of the company's records in a folder off this Mac, read back and checked before it counts.
/// The passphrase is typed for each export and never stored.
struct ContinuityView: View {
    @Environment(ContinuityModel.self) private var model
    @Environment(InventoryModel.self) private var inventory
    @Environment(ObligationsModel.self) private var obligations
    @Environment(LicenceModel.self) private var licences
    @Environment(KeysModel.self) private var keys
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var suggestion: String?
    @State private var checking: ContinuityExportRecord?
    @State private var recordingOutside: ContinuityExportRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusCard
                if let error = model.loadError {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.callout)
                }
                if model.isAvailable {
                    folderCard
                    exportCard
                } else {
                    Label("Exports are made on the Mac, where the folder is chosen and kept. The log below is this device's.",
                          systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                }
                contentsCard
                logSection
                recipeCard
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(SidebarItem.continuity.title)
        .sheet(item: $checking) { record in
            ContinuityCheckSheet(record: record) { phrase in Task { await model.reverify(record, passphrase: phrase) } }
        }
        .sheet(item: $recordingOutside) { ContinuityOutsideSheet(record: $0) }
        .alert("Continuity", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let last = model.log.lastVerified
        let offMac = model.log.lastVerifiedOffMac
        let tint: Color = offMac != nil ? .green : (last != nil ? .orange : .red)
        return StripeCard(tint: tint) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: offMac != nil ? "lock.doc.fill" : "lock.doc").font(.title2).foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if let last {
                        Text("Last verified export: \(last.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.title3.weight(.semibold))
                        Text(verbatim: "\(last.fileName) · \(last.folder) · \(last.folderKind.title)")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if offMac == nil {
                            Text("That folder is not off this Mac. Export to a USB stick or a Google Drive folder.")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        let next = Calendar.current.date(byAdding: .day, value: ObligationsBuilder.exportEveryDays, to: last.createdAt) ?? last.createdAt
                        Text("Next export due \(next.formatted(date: .abbreviated, time: .omitted)) (every \(ObligationsBuilder.exportEveryDays) days).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No encrypted copy off this Mac yet").font(.title3.weight(.semibold))
                        Text("Until there is one, the inventory, obligations, licence ledger and keys registry live only on this Mac and in Supabase, which keeps no point-in-time backup on the free plan.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Folder

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Folder").font(.headline).accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                if let path = model.folderPath {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(verbatim: path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                    if let kind = model.folderKind {
                        ReleaseBadge(text: kind.title, symbol: kind.isOffThisMac ? "checkmark.circle" : "exclamationmark.triangle",
                                     color: kind.isOffThisMac ? .green : .orange)
                    }
                } else {
                    Text("No folder chosen.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                #if os(macOS)
                Button(model.folderPath == nil ? "Choose folder…" : "Change…") { model.chooseFolder() }
                #endif
            }
            if model.folderKind == .thisMac {
                Text("This folder is on this Mac's own disk, so a copy there is not off this Mac. Choose a USB stick or a Google Drive for desktop folder.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Linumic OS writes only its export files into this folder, never over an existing file, and reads each one back to check it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Export

    private var problem: String? { ContinuityPassphrase.problem(passphrase, confirmation: confirmation) }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Passphrase").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Typed for each export and never stored, not even in the Keychain. Write it on paper and keep it apart from the folder. Without it the export can't be opened, by anyone.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("Passphrase again", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            if !passphrase.isEmpty || !confirmation.isEmpty, let problem {
                Label { Text(verbatim: problem) } icon: { Image(systemName: "info.circle").foregroundStyle(.orange) }
                    .font(.caption)
            }
            HStack(spacing: 10) {
                Button("Suggest a passphrase") { suggestion = ContinuityPassphrase.suggestion() }
                    .buttonStyle(.borderless)
                if let suggestion {
                    Text(verbatim: suggestion).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Use it") {
                        passphrase = suggestion
                        confirmation = suggestion
                    }
                    .buttonStyle(.borderless)
                }
            }
            if suggestion != nil {
                Text("Shown here only; write it on paper before you export. It is not kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 10) {
                Button {
                    let b = model.bundle(inventory: inventory, obligations: obligations, licences: licences, keys: keys)
                    let phrase = passphrase
                    Task {
                        await model.export(b, passphrase: phrase)
                        if model.lastResult != nil {
                            passphrase = ""
                            confirmation = ""
                            suggestion = nil
                        }
                    }
                } label: {
                    if model.isWorking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Encrypting and checking…") }
                    } else {
                        Label("Export and verify", systemImage: "lock.doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || problem != nil || model.folderPath == nil)
                if model.folderPath == nil { Text("Choose a folder first.").font(.caption).foregroundStyle(.secondary) }
            }
            if let r = model.lastResult, r.isVerified {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Written and read back: \(r.fileName) decrypted and matched what was written.")
                        Text("SHA-256 of the decrypted file: \(r.plaintextSHA256)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Contents

    private var contentsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the export holds").font(.headline).accessibilityAddTraits(.isHeader)
            Label("The inventory (products, records and their evidence)", systemImage: "shippingbox")
            Label("Obligations and accounts, each with its source", systemImage: "calendar.badge.exclamationmark")
            Label("The licence ledger, without licence key text", systemImage: "key.horizontal")
            Label("The keys registry: which keys and backups exist, where, since when", systemImage: "externaldrive.badge.checkmark")
            Divider()
            Text("Never in it").font(.subheadline.weight(.semibold))
            Label("Passwords, tokens, API keys and sessions (they stay in the Keychain)", systemImage: "xmark.circle")
            Label("Signing keys, keystores, .p8 and .pem files", systemImage: "xmark.circle")
            Text("Before anything is written, the export is checked for key and token patterns; if one is found, nothing is written and you are told which kind.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exports").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if model.log.exports.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(model.log.exports) { r in
                StripeCard(tint: r.isVerified ? (r.folderKind.isOffThisMac ? .green : .orange) : .red) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: r.fileName).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 6)
                        ReleaseBadge(text: r.folderKind.title, symbol: "folder", color: r.folderKind.isOffThisMac ? .green : .orange)
                    }
                    Text("\(r.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(r.folder) · \(ByteCountFormatter.string(fromByteCount: Int64(r.fileBytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let at = r.lastVerifiedAt {
                        Label { Text("Read back and matched, \(at.formatted(date: .abbreviated, time: .shortened))") } icon: {
                            Image(systemName: "checkmark.seal").foregroundStyle(.green)
                        }
                        .font(.caption)
                    }
                    Text("SHA-256 (decrypted): \(r.plaintextSHA256)").font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    ForEach(Array(r.outsideChecks.enumerated()), id: \.offset) { _, c in
                        Label { Text("Opened outside this Mac \(c.on.start().formatted(date: .abbreviated, time: .omitted)): \(c.evidence)") } icon: {
                            Image(systemName: "laptopcomputer").foregroundStyle(.blue)
                        }
                        .font(.caption)
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        if model.isAvailable {
                            Button("Check again…") { checking = r }.disabled(model.isWorking)
                        }
                        Button("Opened outside this Mac…") { recordingOutside = r }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Recipe

    private var recipeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Opening an export without Linumic OS").font(.headline).accessibilityAddTraits(.isHeader)
            Text("The file is a standard age file. On any computer with age installed (age-encryption.org; on a Mac `brew install age`):")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "age -d -o linumic-os-continuity.json linumic-os-continuity-….json.age\nshasum -a 256 linumic-os-continuity.json")
                .font(.caption.monospaced()).textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .environment(\.layoutDirection, .leftToRight)
            Text("age asks for the passphrase. The SHA-256 it prints must equal the one recorded here. The JSON opens in any text editor; docs/continuity.md describes every field.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Sheets

/// Reads an export back from the folder and checks it again with the passphrase (typed, not stored).
struct ContinuityCheckSheet: View {
    let record: ContinuityExportRecord
    let check: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""

    var body: some View {
        EditorSheet(title: "Check an export again", canSave: !passphrase.isEmpty,
                    onCancel: { dismiss() },
                    onSave: {
                        check(passphrase)
                        dismiss()
                    }) {
            Text(verbatim: record.fileName).font(.callout.monospaced())
            SecureField("Passphrase", text: $passphrase)
            Text("The file is read back from the folder, decrypted and compared with what was written. The passphrase is not kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Records that the owner opened an export on another computer, with what proves it.
struct ContinuityOutsideSheet: View {
    let record: ContinuityExportRecord
    @Environment(ContinuityModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var evidence = ""

    var body: some View {
        EditorSheet(title: "Opened outside this Mac", canSave: !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    onCancel: { dismiss() },
                    onSave: { if model.recordOutsideCheck(record, on: KeyDay(date), evidence: evidence) { dismiss() } }) {
            Text(verbatim: record.fileName).font(.callout.monospaced())
            DatePicker("Opened on", selection: $date, in: ...Date(), displayedComponents: .date)
            TextField("Evidence", text: $evidence, axis: .vertical)
            Text("Required: where and how it was opened, and that the SHA-256 matched (for example: \"age -d on the office PC; SHA-256 matched\"). Record only what was really done.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
