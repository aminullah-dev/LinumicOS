import LinumicCore
import SwiftUI

// MARK: - Vault screen

/// The Vault: every sign-in the owner keeps, grouped by product, with copy buttons. Passwords are dots until the
/// owner unlocks with Touch ID or the device password.
struct VaultView: View {
    @Environment(VaultModel.self) private var vault
    @Environment(Router.self) private var router
    @State private var search = ""
    @State private var editing: VaultEntry?
    @State private var isAdding = false
    @State private var deleting: VaultEntry?

    private var groups: [(product: VaultProduct, entries: [VaultEntry])] {
        vaultGroups(vault.entries.filter { $0.matches(search: search) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section { VaultLockCard() }
                if let error = vault.loadError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                if vault.entries.isEmpty, vault.loadError == nil {
                    ContentUnavailableView {
                        Label("The Vault is empty", systemImage: "lock.rectangle.stack")
                    } description: {
                        Text("Add the sign-ins you use, and copy them from here whenever you need them.")
                    } actions: {
                        Button("Add Sign-In") { isAdding = true }.buttonStyle(.borderedProminent)
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(groups, id: \.product) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            VaultEntryRow(entry: entry, onEdit: { editing = entry }, onDelete: { deleting = entry })
                        }
                    } header: {
                        Label { Text(verbatim: group.product.title) } icon: { Image(systemName: group.product.symbol) }
                    }
                }
            }
            .navigationTitle("Vault")
            .searchable(text: $search, prompt: Text("Title, login, address or note"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isAdding = true } label: { Label("Add Sign-In", systemImage: "plus") }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .help("Add a sign-in to the Vault")
                }
                ToolbarItem {
                    if vault.isUnlocked {
                        Button { vault.lock() } label: { Label("Lock Now", systemImage: "lock") }
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                            .help("Lock the Vault and hide every password")
                    }
                }
            }
            .overlay(alignment: .bottom) { VaultCopyNotice() }
        }
        .sheet(isPresented: $isAdding) { VaultEntryEditor(entry: nil) }
        // From the Command Palette: the editor for a new entry (saved only when the owner presses Save), or a search.
        .onChange(of: router.request, initial: true) {
            switch router.take({ if case .vaultSearch = $0 { true } else { $0 == .newVaultEntry } }) {
            case .newVaultEntry: isAdding = true
            case .vaultSearch(let text): search = text
            default: break
            }
        }
        .sheet(item: $editing) { VaultEntryEditor(entry: $0) }
        .confirmationDialog("Delete this sign-in?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete", role: .destructive) { Task { await vault.delete(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\(entry.title) and its saved password are removed from this device's Keychain. This can't be undone, and it doesn't change the account itself.")
        }
        .alert("Vault", isPresented: Binding(get: { vault.errorMessage != nil }, set: { if !$0 { vault.errorMessage = nil } })) {
            Button("OK") { vault.errorMessage = nil }
        } message: {
            Text(verbatim: vault.errorMessage ?? "")
        }
        .onAppear { if vault.entries.isEmpty { vault.load() } }
    }
}

/// Lock state at the top of the Vault: what is protected, and the unlock / lock button with the time left.
struct VaultLockCard: View {
    @Environment(VaultModel.self) private var vault

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: vault.isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.title2)
                .foregroundStyle(vault.isUnlocked ? Color.orange : Color.accentColor)
                .frame(width: 40, height: 40)
                .background((vault.isUnlocked ? Color.orange : Color.accentColor).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let until = vault.unlockedUntil {
                    Text("Unlocked · locks in \(Text(timerInterval: Date.now...until, countsDown: true).monospacedDigit())")
                        .font(.headline)
                } else {
                    Text("Locked").font(.headline)
                }
                Text("Saved only in this device's Keychain, never synced or uploaded. Showing, copying or filling a password asks for Touch ID or your device password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if vault.isUnlocked {
                Button { vault.lock() } label: { Label("Lock", systemImage: "lock") }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await vault.unlock(reason: String(localized: "Unlock the Vault")) }
                } label: {
                    Label("Unlock", systemImage: "touchid")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: vault.isUnlocked)
        .accessibilityElement(children: .contain)
    }
}

/// One sign-in: title and environment, then login, password and address, each with its own buttons.
struct VaultEntryRow: View {
    @Environment(VaultModel.self) private var vault
    let entry: VaultEntry
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: entry.title).font(.headline)
                if entry.environment != .any { VaultEnvironmentBadge(environment: entry.environment) }
                Spacer(minLength: 4)
                Menu {
                    menuItems
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Edit, copy or delete")
            }
            loginLine
            passwordLine
            if let url = entry.url {
                VaultFieldLine(symbol: "link", label: Text("Address")) {
                    Text(verbatim: url.host() ?? url.absoluteString)
                        .lineLimit(1).truncationMode(.middle)
                        .environment(\.layoutDirection, .leftToRight)
                        .help(url.absoluteString)
                } actions: {
                    VaultIconButton(title: "Open", symbol: "arrow.up.forward.square") { openURL(url) }
                }
            }
            if !entry.notes.isEmpty {
                Text(verbatim: entry.notes).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            footer
        }
        .padding(.vertical, 6)
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button { onEdit() } label: { Label("Edit…", systemImage: "pencil") }
        if entry.trimmedLogin != nil {
            Button { vault.copyLogin(entry) } label: { Label("Copy \(entry.loginKind.title)", systemImage: "doc.on.doc") }
        }
        if entry.hasPassword {
            Button { Task { await vault.copyPassword(entry) } } label: { Label("Copy Password", systemImage: "key") }
        }
        if let url = entry.url {
            Button { openURL(url) } label: { Label("Open Address", systemImage: "arrow.up.forward.square") }
        }
        Divider()
        Button(role: .destructive) { onDelete() } label: { Label("Delete…", systemImage: "trash") }
    }

    @ViewBuilder private var loginLine: some View {
        VaultFieldLine(symbol: entry.loginKind.symbol, label: Text(entry.loginKind.title)) {
            if let login = entry.trimmedLogin {
                Text(verbatim: login)
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                Text("Not added yet").foregroundStyle(.secondary).italic()
            }
        } actions: {
            if entry.trimmedLogin != nil {
                VaultIconButton(title: "Copy \(entry.loginKind.title)", symbol: "doc.on.doc") { vault.copyLogin(entry) }
            }
        }
    }

    @ViewBuilder private var passwordLine: some View {
        let revealed = vault.revealedPassword(entry.id)
        VaultFieldLine(symbol: "key", label: Text("Password")) {
            if !entry.hasPassword {
                Text("No password saved").foregroundStyle(.secondary).italic()
            } else if let revealed {
                Text(verbatim: revealed)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                Text(verbatim: "••••••••••••").foregroundStyle(.secondary).accessibilityLabel(Text("Hidden"))
            }
        } actions: {
            if entry.hasPassword {
                VaultIconButton(title: revealed == nil ? "Show Password" : "Hide Password",
                                symbol: revealed == nil ? "eye" : "eye.slash") { Task { await vault.toggleReveal(entry) } }
                VaultIconButton(title: "Copy Password", symbol: "doc.on.doc") { Task { await vault.copyPassword(entry) } }
            }
        }
    }

    private var footer: some View {
        Group {
            if let changed = entry.passwordChangedAt {
                Text("Password saved \(changed.formatted(date: .abbreviated, time: .shortened))")
            } else if let source = entry.templateSource, entry.isEmpty {
                Text("Address found in \(source). Add your login and password.")
            } else {
                Text("Updated \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

/// An icon, a label for VoiceOver, the value, and the buttons at the end of the line.
struct VaultFieldLine<Value: View, Actions: View>: View {
    let symbol: String
    let label: Text
    @ViewBuilder let value: Value
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(label)
            HStack(spacing: 2) { actions }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A small borderless icon button with a tooltip and a spoken name.
struct VaultIconButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .minTapTarget()
    }
}

struct VaultEnvironmentBadge: View {
    let environment: VaultEnvironment

    var body: some View {
        let color: Color = switch environment {
        case .production: .red
        case .demo, .staging: .blue
        case .local: .gray
        case .any: .secondary
        }
        Text(verbatim: environment.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(Text("Environment: \(environment.title)"))
    }
}

/// The brief "copied" confirmation at the bottom of the Vault and of the sign-in sheets.
struct VaultCopyNotice: View {
    @Environment(VaultModel.self) private var vault

    var body: some View {
        if let text = vault.copyNotice {
            Label { Text(verbatim: text) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Editor

struct VaultEntryEditor: View {
    @Environment(VaultModel.self) private var vault
    @Environment(\.dismiss) private var dismiss
    let entry: VaultEntry?

    @State private var draft: VaultEntry
    @State private var newPassword = ""
    @State private var showPassword = false
    @State private var removePassword = false
    @State private var options = PasswordGenerator.Options()
    @State private var isSaving = false

    init(entry: VaultEntry?) {
        self.entry = entry
        _draft = State(initialValue: entry ?? VaultEntry(title: "", product: .other, environment: .any))
    }

    private var passwordChange: VaultPasswordChange {
        if !newPassword.isEmpty { return .set(newPassword) }
        return removePassword ? .remove : .keep
    }

    var body: some View {
        EditorSheet(title: entry == nil ? "Add Sign-In" : "Edit Sign-In",
                    canSave: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving,
                    onCancel: { newPassword = ""; dismiss() },
                    onSave: { Task { await save() } }) {
            Section {
                TextField("Title", text: $draft.title, prompt: Text("For example: Talar admin"))
                Picker("Product", selection: $draft.product) {
                    ForEach(VaultProduct.allCases) { p in
                        Label { Text(verbatim: p.title) } icon: { Image(systemName: p.symbol) }.tag(p)
                    }
                }
                Picker("Environment", selection: $draft.environment) {
                    ForEach(VaultEnvironment.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                TextField("Sign-in address", text: Binding(
                    get: { draft.url?.absoluteString ?? "" },
                    set: { let t = $0.trimmingCharacters(in: .whitespaces); draft.url = t.isEmpty ? nil : URL(string: t) }),
                          prompt: Text(verbatim: "https://"))
                    .environment(\.layoutDirection, .leftToRight)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
            } footer: {
                if let source = draft.templateSource {
                    Text("Address found in \(source).")
                }
            }
            Section("Login") {
                Picker("Login type", selection: $draft.loginKind) {
                    ForEach(VaultLoginKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(draft.loginKind.title, text: $draft.login.orEmpty)
                    .textContentType(draft.loginKind == .phone ? .telephoneNumber : .username)
                    .environment(\.layoutDirection, .leftToRight)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(draft.loginKind == .email ? .emailAddress : draft.loginKind == .phone ? .phonePad : .default)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            passwordSection
            Section("Notes") {
                TextField("Notes", text: $draft.notes, prompt: Text("Recovery hints, who the account belongs to…"), axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
        .onDisappear { newPassword = "" }
    }

    private var passwordSection: some View {
        Section {
            HStack {
                Group {
                    if showPassword {
                        TextField("New password", text: $newPassword)
                            .font(.body.monospaced())
                    } else {
                        SecureField("New password", text: $newPassword)
                    }
                }
                .textContentType(.newPassword)
                .autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
                VaultIconButton(title: showPassword ? "Hide Password" : "Show Password", symbol: showPassword ? "eye.slash" : "eye") {
                    showPassword.toggle()
                }
            }
            DisclosureGroup("Generate a password") {
                Stepper(value: $options.length, in: PasswordGenerator.Options.lengthRange) {
                    Text("Length: \(options.length)")
                }
                Toggle("Digits", isOn: $options.digits)
                Toggle("Symbols", isOn: $options.symbols)
                Toggle("Avoid look-alike characters", isOn: $options.avoidAmbiguous)
                Button {
                    newPassword = PasswordGenerator.generate(options)
                    showPassword = true
                    removePassword = false
                } label: {
                    Label("Generate", systemImage: "dice")
                }
            }
            if entry?.hasPassword == true {
                Toggle("Remove the saved password", isOn: $removePassword)
                    .disabled(!newPassword.isEmpty)
            }
        } header: {
            Text("Password")
        } footer: {
            if entry?.hasPassword == true {
                Text("Leave empty to keep the saved password. Replacing or removing it asks for Touch ID or your device password. Saving here doesn't change the password on the service itself.")
            } else {
                Text("Stored only in this device's Keychain. Saving here doesn't change the password on the service itself.")
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await vault.save(draft, password: passwordChange) {
            newPassword = ""
            dismiss()
        }
    }
}

// MARK: - Sign-in assist

/// "Fill from Vault" for a sign-in form: lists the matching entries and fills the fields after Touch ID or the
/// device password. When nothing matches it says so, and the owner can add one in the Vault.
struct VaultFillMenu: View {
    @Environment(VaultModel.self) private var vault
    let form: VaultSignInForm
    let onFill: (_ login: String?, _ password: String?) -> Void

    var body: some View {
        let candidates = vault.candidates(for: form)
        Menu {
            if candidates.isEmpty {
                Text("Nothing saved for \(form.product.title) · \(form.environment.title). Add it in the Vault.")
            } else {
                ForEach(candidates) { entry in
                    Button {
                        Task {
                            if let filled = await vault.fill(entry, form: form) { onFill(filled.login, filled.password) }
                        }
                    } label: {
                        Text(verbatim: [entry.title, entry.trimmedLogin].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        } label: {
            Label("Fill from Vault", systemImage: "lock.rectangle.stack")
        }
        .fixedSize()
        .help(candidates.isEmpty ? Text("No saved sign-in for this product and environment yet") : Text("Fill the form from a saved sign-in"))
    }
}

extension View {
    /// After a successful sign-in: asks whether to keep the login (and password) in the Vault, then calls `onDone`.
    func vaultSaveOffer(_ offer: Binding<VaultSaveOffer?>, onDone: @escaping () -> Void) -> some View {
        modifier(VaultSaveOfferModifier(offer: offer, onDone: onDone))
    }
}

private struct VaultSaveOfferModifier: ViewModifier {
    @Environment(VaultModel.self) private var vault
    @Binding var offer: VaultSaveOffer?
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Save to Vault?", isPresented: Binding(
            get: { offer != nil },
            set: { if !$0, offer != nil { offer = nil; onDone() } }
        ), titleVisibility: .visible, presenting: offer) { o in
            Button("Save to Vault") { vault.accept(o) }
            Button("Not Now", role: .cancel) {}
        } message: { o in
            Text("Keep \(o.login) for \(o.form.product.title) · \(o.form.environment.title) in this device's Keychain, so you can fill this form next time.")
        }
    }
}
