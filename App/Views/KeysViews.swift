import LinumicCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Keys & Backups screen (کلیدها و پشتیبان‌ها)

extension KeyCheckStatus {
    var color: Color {
        switch self {
        case .present: .green
        case .missing: .red
        case .notGranted: .gray
        }
    }

    var symbol: String {
        switch self {
        case .present: "checkmark.circle.fill"
        case .missing: "xmark.octagon.fill"
        case .notGranted: "lock.circle"
        }
    }

    var title: String {
        switch self {
        case .present: String(localized: "On this Mac")
        case .missing: String(localized: "Missing")
        case .notGranted: String(localized: "Not granted")
        }
    }
}

extension KeyBackupState {
    var color: Color {
        switch self {
        case .covered: .green
        case .changedAfterBackup: .red
        case .notBackedUp: .orange
        case .notApplicable: .gray
        }
    }

    var symbol: String {
        switch self {
        case .covered: "externaldrive.badge.checkmark"
        case .changedAfterBackup: "exclamationmark.arrow.triangle.2.circlepath"
        case .notBackedUp: "externaldrive.badge.xmark"
        case .notApplicable: "minus.circle"
        }
    }

    var title: String {
        switch self {
        case .covered: String(localized: "Backed up")
        case .changedAfterBackup: String(localized: "Changed after backup")
        case .notBackedUp: String(localized: "Not backed up")
        case .notApplicable: String(localized: "No backup needed")
        }
    }
}

enum KeysClipboard {
    /// Copies a restore command (never a secret: the commands hold no passphrase).
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

struct KeysView: View {
    @Environment(KeysModel.self) private var keys
    @Environment(Router.self) private var router

    @State private var restoreSheet: RestoreSheetRequest?
    @State private var editingKey: KeyDraft?
    @State private var editingBackup: BackupRecord?
    @State private var closingGap: KeyGap?
    @State private var removingKey: TrackedKey?

    struct RestoreSheetRequest: Identifiable {
        let backupID: String?
        let id = UUID()
    }

    struct KeyDraft: Identifiable {
        var key: TrackedKey
        var isNew: Bool
        var id: String { key.id }
    }

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)]

    var body: some View {
        let reminders = keys.reminders
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = keys.loadError {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        .font(.callout)
                }
                remindersSection(reminders)
                sectionTitle("Backups off this Mac", symbol: "externaldrive.badge.icloud")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(keys.registry.backups) { backup in
                        BackupCard(backup: backup,
                                   passphrase: backup.passphraseKeychainService.flatMap { keys.passphrase[$0] },
                                   markRestore: { restoreSheet = RestoreSheetRequest(backupID: backup.id) },
                                   edit: { editingBackup = backup })
                    }
                }
                keysSection
                if !uncovered.isEmpty { uncoveredSection }
                gapsSection
                #if os(macOS)
                locationsSection
                #endif
                RestoreGuidePanel(backups: keys.registry.backups)
                Text("Linumic OS never opens, copies, hashes or uploads a key, keystore, .p8, .pem, password file or the backup passphrase. On this Mac it reads only whether each file exists, its size and its modification date, in folders you granted. For the passphrase it only asks the Keychain whether the item exists.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle(SidebarItem.keys.title)
        .toolbar {
            if KeysModel.supportsLocalChecks {
                ToolbarItem {
                    Button {
                        Task { await keys.check() }
                    } label: {
                        Label("Check files", systemImage: "arrow.clockwise")
                    }
                    .disabled(keys.isChecking)
                    .keyboardShortcut("r")
                    .help("Check each key file's existence, size and date now")
                }
            }
        }
        .onChange(of: router.request, initial: true) {
            if router.take({ $0 == .markRestoreTest }) != nil { restoreSheet = RestoreSheetRequest(backupID: nil) }
        }
        .sheet(item: $restoreSheet) { req in
            RestoreTestSheet(backups: keys.registry.backups, backupID: req.backupID ?? keys.registry.backups.first?.id ?? "") { id, day, by, note in
                if !keys.recordRestoreTest(backupID: id, on: day, by: by, note: note), keys.errorMessage == nil {
                    keys.errorMessage = String(localized: "The restore test was not saved. The date can't be in the future.")
                }
            }
        }
        .sheet(item: $editingKey) { draft in
            KeyEditorSheet(draft: draft.key, isNew: draft.isNew, backups: keys.registry.backups,
                           existingIDs: Set(keys.registry.keys.map(\.id))) { keys.upsert($0) }
        }
        .sheet(item: $editingBackup) { backup in
            BackupEditorSheet(draft: backup) { keys.upsert($0) }
        }
        .sheet(item: $closingGap) { gap in
            GapCloseSheet(gap: gap) { day, note in
                if !keys.closeGap(gap.id, on: day, note: note), keys.errorMessage == nil {
                    keys.errorMessage = String(localized: "Not saved. The date can't be in the future.")
                }
            }
        }
        .confirmationDialog(String(localized: "Remove this key from the registry?"),
                            isPresented: Binding(get: { removingKey != nil }, set: { if !$0 { removingKey = nil } }),
                            titleVisibility: .visible, presenting: removingKey) { key in
            Button("Remove from the registry", role: .destructive) { keys.removeKey(key.id) }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text("\(L(key.title)) is only removed from this list. The key file itself is not touched.")
        }
        .alert("Error", isPresented: Binding(get: { keys.errorMessage != nil }, set: { if !$0 { keys.errorMessage = nil } })) {
            Button("OK") { keys.errorMessage = nil }
        } message: {
            Text(verbatim: keys.errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !KeysModel.supportsLocalChecks {
                    Label("Files can only be checked on the Mac. The registry is shown here.", systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                } else if keys.isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking key files…").foregroundStyle(.secondary)
                } else if let at = keys.checkedAt {
                    Text("Files checked \(at.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                } else {
                    Text("Files not checked yet.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if KeysModel.supportsLocalChecks {
                    Button {
                        Task { await keys.check() }
                    } label: {
                        Label("Check files", systemImage: "arrow.clockwise")
                    }
                    .disabled(keys.isChecking)
                }
                Button {
                    restoreSheet = RestoreSheetRequest(backupID: nil)
                } label: {
                    Label("Mark restore test done…", systemImage: "checkmark.circle")
                }
            }
            .font(.callout)
            if let last = keys.registry.lastRestoreTest {
                let age = KeysRules.restoreTestAge(last.backup, now: .now) ?? 0
                Text("Last restore test: \(last.test.on.description), \(L(last.backup.title)), by \(last.test.by) (\(age) days ago).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let updated = keys.registry.updatedAt {
                Text("Registry last changed \(updated.formatted(date: .abbreviated, time: .shortened)) (keys-registry.json, this device).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Registry as seeded from ~/Keys/README.md (2026-10-09) and the session record. Edits are saved on this device (keys-registry.json).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Reminders

    private func remindersSection(_ items: [KeysReminder]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Reminders", systemImage: "bell.badge").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: items.count.formatted()).font(.callout.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((items.isEmpty ? Color.green : .orange).opacity(0.15), in: Capsule())
            }
            if items.isEmpty {
                Text("Nothing needs you: every key is backed up, unchanged, and a restore was tested in the last 90 days.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: r.severity.symbol).foregroundStyle(r.severity.color)
                            .accessibilityLabel(Text(verbatim: r.severity.title))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: r.text).fixedSize(horizontal: false, vertical: true)
                            if let d = r.detail { Text(verbatim: d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let at = r.readAt {
                                ReleaseSourceLine(source: r.source, at: at)
                            } else {
                                Text("Source: \(r.source)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        reminderAction(r)
                    }
                    .accessibilityElement(children: .contain)
                    if r.id != items.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func reminderAction(_ r: KeysReminder) -> some View {
        switch r.kind {
        case .restoreTestDue, .noRestoreTest:
            Button("Mark restore test done…") { restoreSheet = RestoreSheetRequest(backupID: r.backupID) }
                .buttonStyle(.borderless).minTapTarget()
        case .secondCopyMissing:
            if let gap = keys.registry.secondCopyGap {
                Button("Mark second copy done…") { closingGap = gap }
                    .buttonStyle(.borderless).minTapTarget()
            }
        case .keyChangedAfterBackup:
            if let id = r.backupID, let b = keys.registry.backup(id) {
                Button("Edit backup…") { editingBackup = b }
                    .buttonStyle(.borderless).minTapTarget()
            }
        case .uncoveredFile:
            if let path = r.detail {
                Button("Add to registry…") { editingKey = KeyDraft(key: newKey(path: path), isNew: true) }
                    .buttonStyle(.borderless).minTapTarget()
            }
        case .keyMissing, .keyNotBackedUp, .passphraseMissing:
            EmptyView()
        }
    }

    // MARK: Keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Keys on this Mac", symbol: "key.fill")
                Spacer()
                Button {
                    editingKey = KeyDraft(key: newKey(path: "~/"), isNew: true)
                } label: {
                    Label("Add key…", systemImage: "plus")
                }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(keys.registry.keys) { key in
                    KeyCard(key: key, result: keys.result(for: key), state: keys.backupState(key),
                            backups: key.backupIDs.compactMap(keys.registry.backup), home: keys.home,
                            edit: { editingKey = KeyDraft(key: key, isNew: false) },
                            remove: { removingKey = key })
                }
            }
        }
    }

    private var uncovered: [KeyFileInfo] { KeysRules.unregisteredFiles(keys.checkInput) }

    private var uncoveredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Key files not in the registry", symbol: "questionmark.folder")
            Text("Found by file name only (*.jks, *.keystore, *-private.pem, AuthKey_*.p8). No backup is known for them.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(uncovered, id: \.path) { file in
                StripeCard(tint: .orange) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: file.name).fontWeight(.medium)
                            Text(verbatim: KeyPaths.abbreviate(file.path, home: keys.home))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight)
                            FileFactsLine(file: file)
                        }
                        Spacer(minLength: 8)
                        Button("Add to registry…") {
                            editingKey = KeyDraft(key: newKey(path: KeyPaths.abbreviate(file.path, home: keys.home)), isNew: true)
                        }
                        .minTapTarget()
                    }
                }
            }
        }
    }

    private func newKey(path: String) -> TrackedKey {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let kind: KeyKind = path.hasSuffix(".p8") ? .appStoreConnectAPI : path.hasSuffix("-private.pem") ? .licenceSigning : .androidSigning
        return TrackedKey(id: "key-\(UUID().uuidString.prefix(8).lowercased())", title: name.isEmpty ? "" : name, kind: kind, path: path,
                          source: String(localized: "Entered in Linumic OS"), recordedOn: KeyDay(.now))
    }

    // MARK: Gaps

    private var gapsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Known gaps", symbol: "exclamationmark.shield")
            ForEach(keys.registry.gaps) { gap in
                StripeCard(tint: gap.isOpen ? .orange : .green) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: L(gap.title)).font(.headline)
                        Spacer(minLength: 8)
                        if gap.isOpen {
                            ReleaseBadge(text: String(localized: "Open"), symbol: "circle.dashed", color: .orange)
                        } else {
                            ReleaseBadge(text: String(localized: "Done \(gap.closedOn?.description ?? "")"), symbol: "checkmark.circle.fill", color: .green)
                        }
                    }
                    if let d = gap.detail { Text(verbatim: L(d)).font(.callout).foregroundStyle(.secondary) }
                    if let note = gap.closedNote, !note.isEmpty { Text(verbatim: note).font(.callout) }
                    HStack {
                        Text("Source: \(gap.source), recorded \(gap.recordedOn.description)")
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        Spacer(minLength: 8)
                        if gap.isOpen {
                            Button(gap.kind == .secondCopy ? "Mark second copy done…" : "Mark done…") { closingGap = gap }
                                .minTapTarget()
                        } else {
                            Button("Reopen") { keys.reopenGap(gap.id) }.minTapTarget()
                        }
                    }
                }
            }
        }
    }

    // MARK: Locations (macOS)

    #if os(macOS)
    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Folders the app may read", symbol: "folder.badge.gearshape")
            Text("The app is sandboxed: it can only look in folders you choose. Choosing your home folder once covers every location below. Access is read-only and limited to names, sizes and dates.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(KeysScanner.defaultRoots, id: \.self) { root in
                HStack(spacing: 8) {
                    Text(verbatim: root).font(.callout.monospaced()).environment(\.layoutDirection, .leftToRight)
                    Spacer(minLength: 8)
                    rootBadge(root)
                    if isNotGranted(root) {
                        Button("Not granted — choose folder…") { keys.chooseFolder(suggested: root) }
                    }
                }
            }
            if !keys.grantedFolders.isEmpty {
                Text("Granted: \(keys.grantedFolders.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Choose another folder…") { keys.chooseFolder(suggested: "~") }
                    Button("Remove access", role: .destructive) { keys.revokeFolders() }
                        .help("Forget the folders chosen here (the Oversight workspace stays)")
                }
            } else {
                Button("Choose folder…") { keys.chooseFolder(suggested: "~") }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func status(_ root: String) -> ScanRootStatus? { keys.scan?.roots.first { $0.root == root }?.status }

    private func isNotGranted(_ root: String) -> Bool {
        switch status(root) {
        case .notGranted?, .partly?: true
        case nil: keys.checkedAt != nil
        default: false
        }
    }

    @ViewBuilder
    private func rootBadge(_ root: String) -> some View {
        switch status(root) {
        case .scanned?: ReleaseBadge(text: String(localized: "Checked"), symbol: "checkmark.circle.fill", color: .green)
        case .partly(let inside)?: ReleaseBadge(text: String(localized: "Partly: \(inside.joined(separator: ", "))"), symbol: "circle.lefthalf.filled", color: .orange)
        case .notGranted?: ReleaseBadge(text: String(localized: "Not granted"), symbol: "lock.circle", color: .gray)
        case .missing?: ReleaseBadge(text: String(localized: "No such folder"), symbol: "folder.badge.minus", color: .gray)
        case nil: ReleaseBadge(text: String(localized: "Not checked"), symbol: "questionmark.circle", color: .gray)
        }
    }
    #endif
}

// MARK: - Cards

/// "4.3 KB · modified 3 Oct 2026" from file attributes.
struct FileFactsLine: View {
    let file: KeyFileInfo

    var body: some View {
        Text("\(file.size.formatted(.byteCount(style: .file))) · modified \(file.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct KeyCard: View {
    let key: TrackedKey
    let result: KeyCheckResult?
    let state: KeyBackupState
    let backups: [BackupRecord]
    let home: String
    let edit: () -> Void
    let remove: () -> Void

    private var tint: Color {
        if case .missing? = result?.status { return .red }
        return state == .covered || state == .notApplicable ? (result == nil ? .gray : .green) : state.color
    }

    var body: some View {
        StripeCard(tint: tint) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label { Text(verbatim: L(key.title)).font(.headline) } icon: { Image(systemName: key.kind.symbol) }
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Menu {
                    Button("Edit…", action: edit)
                    Button("Remove from the registry…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel(Text("Actions"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            FitRow(spacing: 6) {
                if let result {
                    ReleaseBadge(text: result.status.title, symbol: result.status.symbol, color: result.status.color)
                } else {
                    ReleaseBadge(text: String(localized: "Not checked"), symbol: "questionmark.circle", color: .gray)
                }
                ReleaseBadge(text: state.title, symbol: state.symbol, color: state.color)
                if key.doNotDelete {
                    ReleaseBadge(text: String(localized: "Do not delete"), symbol: "hand.raised.fill", color: .red)
                }
            }
            Text(verbatim: [key.kind.title, key.product].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: key.path)
                .font(.caption.monospaced()).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(result?.files ?? [], id: \.path) { file in
                if key.isPattern {
                    Text(verbatim: file.name).font(.caption.monospaced()).environment(\.layoutDirection, .leftToRight)
                }
                FileFactsLine(file: file)
            }
            if key.isPattern, let expected = key.expectedCount, let found = result?.files.count, result != nil, found != expected {
                Text("\(found) files found; the source lists \(expected).").font(.caption).foregroundStyle(.orange)
            }
            if case .changedAfterBackup(_, let modified) = state, let b = backups.max(by: { $0.createdOn < $1.createdOn }) {
                Text("Modified \(modified.description), after the backup of \(b.createdOn.description). Make a new backup.")
                    .font(.caption).foregroundStyle(.red)
            }
            if !backups.isEmpty {
                Text("In: \(backups.map(\.fileName).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
            if let note = key.note, !note.isEmpty {
                Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
            }
            Text("Source: \(key.source), recorded \(key.recordedOn.description)")
                .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Remove from the registry…", role: .destructive, action: remove)
        }
    }
}

struct BackupCard: View {
    let backup: BackupRecord
    let passphrase: KeychainPresence?
    let markRestore: () -> Void
    let edit: () -> Void

    var body: some View {
        let age = KeysRules.restoreTestAge(backup, now: .now)
        let due = age.map { $0 > KeysRules.restoreTestMaxDays } ?? true
        StripeCard(tint: due ? .orange : .green) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label { Text(verbatim: L(backup.title)).font(.headline) } icon: { Image(systemName: "lock.doc") }
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let age {
                    ReleaseBadge(text: String(localized: "Restore tested \(age) days ago"),
                                 symbol: due ? "clock.badge.exclamationmark" : "checkmark.circle.fill", color: due ? .orange : .green)
                } else {
                    ReleaseBadge(text: String(localized: "No restore test"), symbol: "clock.badge.exclamationmark", color: .orange)
                }
            }
            Text(verbatim: backup.fileName).font(.callout.monospaced()).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Where", backup.location)
                if let size = backup.sizeBytes { row("Size", Int64(size).formatted(.byteCount(style: .file)) + " (\(size.formatted()) B)") }
                row("Made", backup.createdOn.description)
                if let v = backup.verifiedOn { row("Verified", v.description) }
                row("Encryption", backup.encryption)
                if !backup.passphraseKeptIn.isEmpty { row("Passphrase in", backup.passphraseKeptIn.joined(separator: ", ")) }
                if let test = backup.lastRestoreTest {
                    row("Last restore test", "\(test.on.description), \(test.by)")
                }
            }
            .font(.caption)
            if let v = backup.verification { Text(verbatim: v).font(.caption).foregroundStyle(.secondary) }
            if let service = backup.passphraseKeychainService {
                switch passphrase {
                case .present?:
                    ReleaseBadge(text: String(localized: "Keychain item found"), symbol: "key.icloud", color: .green)
                case .missing?:
                    ReleaseBadge(text: String(localized: "Keychain item “\(service)” not found"), symbol: "exclamationmark.triangle.fill", color: .red)
                case .unknown?, nil:
                    ReleaseBadge(text: String(localized: "Keychain item not checked"), symbol: "questionmark.circle", color: .gray)
                }
            }
            HStack(spacing: 10) {
                if let url = backup.driveURL {
                    Link(destination: url) { Label("Open in Drive", systemImage: "arrow.up.right.square") }
                        .font(.callout)
                }
                Spacer(minLength: 8)
                Button("Edit…", action: edit).minTapTarget()
                Button("Mark restore test done…", action: markRestore).minTapTarget()
            }
            Text("Source: \(backup.source), recorded \(backup.recordedOn.description)")
                .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }
    }
}

// MARK: - Restore guide (read-only)

struct RestoreGuidePanel: View {
    let backups: [BackupRecord]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Read-only. Run these yourself in Terminal; the app runs nothing. openssl asks for the passphrase (Keychain item “Linumic license backup passphrase” or the private Notion page); it never goes on the command line.")
                    .font(.callout).foregroundStyle(.secondary)
                step(1, "Download the backup file from Google Drive, folder Mohem.", command: nil)
                step(2, "Make an empty private folder, move the downloaded file into it, and go there.", command: KeysRestoreGuide.makeFolderCommand())
                ForEach(backups) { b in
                    step(3, LocalizedStringKey("Decrypt and unpack \(b.fileName):"), command: KeysRestoreGuide.decryptCommand(b))
                }
                step(4, "Check that the keys are there (names only), then mark the restore test done here.", command: "ls -la")
                step(5, "Delete the folder afterwards, so no plain copy of the keys stays on disk.", command: KeysRestoreGuide.cleanupCommand())
            }
            .padding(.top, 8)
        } label: {
            Label("Restore guide", systemImage: "arrow.counterclockwise.circle").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func step(_ n: Int, _ text: LocalizedStringKey, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(n.formatted()).").monospacedDigit().foregroundStyle(.secondary)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            if let command {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        KeysClipboard.copy(command)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the command")
                    .accessibilityLabel(Text("Copy the command"))
                    .minTapTarget()
                }
                // Shell commands read left to right in a Dari UI too.
                .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
}

// MARK: - Sheets

/// Records a restore test the owner did. Nothing is saved until Save; the date can't be in the future.
struct RestoreTestSheet: View {
    let backups: [BackupRecord]
    let onSave: (String, KeyDay, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backupID: String
    @State private var date = Date()
    @State private var by = String(localized: "Owner")
    @State private var note = ""

    init(backups: [BackupRecord], backupID: String, onSave: @escaping (String, KeyDay, String, String?) -> Void) {
        self.backups = backups
        self.onSave = onSave
        _backupID = State(initialValue: backupID)
    }

    var body: some View {
        EditorSheet(title: "Mark restore test done", canSave: !backupID.isEmpty && !by.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() },
                    onSave: {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(backupID, KeyDay(date), by.trimmingCharacters(in: .whitespaces), trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }) {
            Picker("Backup", selection: $backupID) {
                ForEach(backups) { Text(verbatim: "\(L($0.title)) (\($0.fileName))").tag($0.id) }
            }
            DatePicker("Restored on", selection: $date, in: ...Date(), displayedComponents: .date)
            TextField("By", text: $by)
            TextField("Note", text: $note, axis: .vertical)
            Text("Record only a restore that was really done: the file was downloaded, decrypted and the keys were there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GapCloseSheet: View {
    let gap: KeyGap
    let onSave: (KeyDay, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        EditorSheet(title: gap.kind == .secondCopy ? "Mark second copy done" : "Mark done",
                    canSave: gap.kind != .secondCopy || !note.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: { dismiss() },
                    onSave: {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(KeyDay(date), trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }) {
            Text(verbatim: L(gap.title)).font(.headline)
            DatePicker("Done on", selection: $date, in: ...Date(), displayedComponents: .date)
            TextField(gap.kind == .secondCopy ? "Where is the second copy? (e.g. USB drive at home)" : "How was it done?", text: $note, axis: .vertical)
        }
    }
}

struct KeyEditorSheet: View {
    @State var draft: TrackedKey
    let isNew: Bool
    let backups: [BackupRecord]
    let existingIDs: Set<String>
    let onSave: (TrackedKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorded = Date()

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.path.hasPrefix("~/") && draft.path.count > 2
            && !draft.source.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        EditorSheet(title: isNew ? "Add key" : "Edit key", canSave: canSave, onCancel: { dismiss() },
                    onSave: {
                        var k = draft
                        k.title = k.title.trimmingCharacters(in: .whitespaces)
                        if isNew { k.recordedOn = KeyDay(recorded) }
                        onSave(k)
                        dismiss()
                    }) {
            TextField("Title", text: $draft.title)
            TextField("Product", text: $draft.product.orEmpty)
            Picker("Kind", selection: $draft.kind) {
                ForEach(KeyKind.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            TextField("Path (starts with ~/; * allowed in the file name)", text: $draft.path)
                .font(.body.monospaced())
                .environment(\.layoutDirection, .leftToRight)
            Section("In backups") {
                ForEach(backups) { b in
                    Toggle(isOn: Binding(
                        get: { draft.backupIDs.contains(b.id) },
                        set: { on in
                            draft.backupIDs.removeAll { $0 == b.id }
                            if on { draft.backupIDs.append(b.id) }
                        })) {
                        Text(verbatim: b.fileName)
                    }
                }
                Text("Tick a backup only if this key was really put into it.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Do not delete", isOn: $draft.doNotDelete)
            TextField("Note", text: $draft.note.orEmpty, axis: .vertical)
            TextField("Source", text: $draft.source)
            if isNew {
                DatePicker("Recorded on", selection: $recorded, in: ...Date(), displayedComponents: .date)
            }
            Text("Only the path is stored. The app never opens the key file.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Edits the facts of a backup after a new bundle was made: its day, verification, size and Drive id.
struct BackupEditorSheet: View {
    @State var draft: BackupRecord
    let onSave: (BackupRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var created = Date()
    @State private var verified: Date?
    @State private var sizeText = ""

    var body: some View {
        EditorSheet(title: "Edit backup", canSave: !draft.fileName.trimmingCharacters(in: .whitespaces).isEmpty && !draft.source.isEmpty,
                    onCancel: { dismiss() },
                    onSave: {
                        var b = draft
                        b.createdOn = KeyDay(created)
                        b.verifiedOn = verified.map { KeyDay($0) }
                        b.sizeBytes = Int(sizeText.trimmingCharacters(in: .whitespaces))
                        onSave(b)
                        dismiss()
                    }) {
            Text(verbatim: draft.title).font(.headline)
            TextField("File name", text: $draft.fileName).environment(\.layoutDirection, .leftToRight)
            TextField("Where", text: $draft.location)
            TextField("Google Drive file id", text: $draft.driveFileID.orEmpty).environment(\.layoutDirection, .leftToRight)
            TextField("Size in bytes", text: $sizeText)
            DatePicker("Made on", selection: $created, in: ...Date(), displayedComponents: .date)
            OptionalDatePicker(title: String(localized: "Verified"), date: $verified)
            TextField("How it was verified", text: $draft.verification.orEmpty, axis: .vertical)
            TextField("Source", text: $draft.source)
            Text("After a new backup, set the day it was made so the staleness check compares against it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            created = draft.createdOn.start()
            verified = draft.verifiedOn?.start()
            sizeText = draft.sizeBytes.map(String.init) ?? ""
        }
    }
}
