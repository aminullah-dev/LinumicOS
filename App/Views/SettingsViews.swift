#if os(macOS)
import AppKit
#endif
import AuthenticationServices
import LinumicCore
import SwiftUI
import UniformTypeIdentifiers

struct IntegrationsSettingsView: View {
    @Environment(InventoryModel.self) private var model
    @State private var tokenInput = ""
    @State private var hasToken = false
    @State private var message: String?

    private let integrations: [(name: String, symbol: String, plan: String)] = [
        ("Social networks", "bubble.left.and.bubble.right", "Phase 5: OAuth, approval before publishing"),
        ("AI provider", "sparkles", "Phase 6: key held on backend"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    StatusBadge(text: hasToken ? "Token saved" : "Public repositories only", color: hasToken ? .green : .orange)
                } label: {
                    Label("GitHub (read-only)", systemImage: "chevron.left.forwardslash.chevron.right")
                    Text("Reads repository metadata, commits, releases, PRs, issues and CI. It never writes.")
                }
                SecureField("Personal access token", text: $tokenInput, prompt: Text(hasToken ? "•••••••• (stored in Keychain)" : "github_pat_…"))
                    .textContentType(.password)
                HStack {
                    Button("Save to Keychain") { saveToken() }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove Token", role: .destructive) { removeToken() }
                        .disabled(!hasToken)
                    Spacer()
                    Button {
                        Task { await model.refreshGitHub(); message = syncSummary() }
                    } label: {
                        if model.isSyncingGitHub { ProgressView().controlSize(.small) } else { Text("Refresh All Repositories") }
                    }
                    .disabled(model.isSyncingGitHub)
                }
                if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Use a fine-grained token with read-only Metadata, Contents, Issues, Pull requests and Actions on the Linumic repositories. It's stored only in this Mac's Keychain.")
            }
            StoreConsoleSection(store: .appStore)
            StoreConsoleSection(store: .googlePlay)
            Section {
                ForEach(integrations, id: \.name) { i in
                    LabeledContent {
                        StatusBadge(text: "Not connected", color: .gray)
                    } label: {
                        Label(LocalizedStringKey(i.name), systemImage: i.symbol)
                        Text(LocalizedStringKey(i.plan))
                    }
                }
            } header: {
                Text("Not connected")
            } footer: {
                Text("These need credentials and authorization before they can be added. See docs/integrations.md.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
        .onAppear { hasToken = ((try? model.secrets.read(.gitHubToken)) ?? nil) != nil }
    }

    private func saveToken() {
        do {
            try model.secrets.write(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines), for: .gitHubToken)
            tokenInput = ""
            hasToken = true
            message = String(localized: "Token saved to the Keychain.")
        } catch {
            message = String(localized: "Could not save: \(error.localizedDescription)")
        }
    }

    private func removeToken() {
        do {
            try model.secrets.delete(.gitHubToken)
            hasToken = false
            message = String(localized: "Token removed.")
        } catch {
            message = String(localized: "Could not remove: \(error.localizedDescription)")
        }
    }

    private func syncSummary() -> String? {
        guard let sync = model.lastGitHubSync else { return nil }
        var text = String(localized: "Refreshed \(sync.report.updated.count) repositories at \(sync.at.formatted(date: .omitted, time: .shortened)).")
        if !sync.report.failed.isEmpty { text += " " + String(localized: "\(sync.report.failed.count) failed:") + " " + sync.report.failed.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; ") }
        return text
    }
}

/// Read-only store console credentials: an App Store Connect API key or a Google Play service account.
/// The key file is read once and kept only in the Keychain.
private struct StoreConsoleSection: View {
    let store: AppStore
    @Environment(InventoryModel.self) private var model
    @State private var issuerID = ""
    @State private var keyID = ""
    @State private var keyFileContents: String?
    @State private var keyFileName: String?
    @State private var isImporting = false
    @State private var connected = false
    @State private var message: String?

    private var isApple: Bool { store == .appStore }
    private var fileTypes: [UTType] { isApple ? [UTType(filenameExtension: "p8") ?? .data, .data] : [.json] }

    var body: some View {
        Section {
            LabeledContent {
                StatusBadge(text: connected ? String(localized: "Connected (read-only)") : String(localized: "Not connected"), color: connected ? .green : .gray)
            } label: {
                Label(isApple ? "App Store Connect" : "Google Play Console", systemImage: isApple ? "applelogo" : "play.rectangle")
                Text(isApple ? "Reads versions and review states of your apps. It never changes anything." : "Reads the releases on each track and their review state. It never creates an edit or changes anything.")
            }
            if !connected {
                if isApple {
                    TextField("Issuer ID", text: $issuerID, prompt: Text(verbatim: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                    TextField("Key ID", text: $keyID, prompt: Text(verbatim: "ABC123DEFG"))
                }
                HStack {
                    Button(isApple ? "Choose .p8 Key File…" : "Choose JSON Key File…") { isImporting = true }
                    if let keyFileName { Text(verbatim: keyFileName).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save to Keychain") { save() }
                        .disabled(keyFileContents == nil || (isApple && (issuerID.isEmpty || keyID.isEmpty)))
                }
            } else {
                HStack {
                    Button("Remove Key", role: .destructive) { remove() }
                    Spacer()
                    Button {
                        Task { await model.refreshFromConsole(store); message = summary() }
                    } label: {
                        if model.syncingConsoles.contains(store) { ProgressView().controlSize(.small) } else { Text("Refresh \(store.title) Listings") }
                    }
                    .disabled(model.syncingConsoles.contains(store))
                }
            }
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text(isApple ? "App Store Connect" : "Google Play")
        } footer: {
            Text(isApple
                 ? "App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys. Create a key with the Developer role and download the .p8 file (Apple lets you download it only once). Free."
                 : "Google Cloud → create a service account and a JSON key, enable the Google Play Android Developer API. Then Play Console → Users and permissions → invite the service account's email with \"View app information (read-only)\". Free.")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: fileTypes) { result in load(result) }
        .onAppear { connected = model.hasConsoleCredentials(store) }
    }

    private func load(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            if isApple {
                try AppStoreConnectCredentials(issuerID: "-", keyID: "-", privateKeyPEM: text).validate()
                // The file is named AuthKey_<KeyID>.p8, so the Key ID can be filled in for the owner.
                let name = url.deletingPathExtension().lastPathComponent
                if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
            } else {
                _ = try GooglePlayCredentials(serviceAccountJSON: Data(text.utf8))
            }
            keyFileContents = text
            keyFileName = url.lastPathComponent
            message = nil
        } catch {
            keyFileContents = nil
            keyFileName = nil
            message = error.localizedDescription
        }
    }

    private func save() {
        guard let keyFileContents else { return }
        do {
            let value: String
            if isApple {
                let credentials = AppStoreConnectCredentials(issuerID: issuerID, keyID: keyID, privateKeyPEM: keyFileContents)
                try credentials.validate()
                value = String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
            } else {
                value = keyFileContents
            }
            try model.secrets.write(value, for: model.consoleSecretKey(store))
            self.keyFileContents = nil
            keyFileName = nil
            issuerID = ""
            keyID = ""
            connected = true
            message = String(localized: "Saved to the Keychain. You can delete the downloaded key file now.")
        } catch {
            message = String(localized: "Could not save: \(error.localizedDescription)")
        }
    }

    private func remove() {
        do {
            try model.secrets.delete(model.consoleSecretKey(store))
            connected = false
            message = String(localized: "Key removed.")
        } catch {
            message = String(localized: "Could not remove: \(error.localizedDescription)")
        }
    }

    private func summary() -> String? {
        guard let sync = model.lastConsoleSync[store] else { return nil }
        var text = String(localized: "Refreshed \(sync.report.updated.count) listings at \(sync.at.formatted(date: .omitted, time: .shortened)).")
        if !sync.report.notInAccount.isEmpty { text += " " + String(localized: "Not found in this account: \(sync.report.notInAccount.joined(separator: ", ")).") }
        if !sync.report.failed.isEmpty { text += " " + String(localized: "\(sync.report.failed.count) failed:") + " " + sync.report.failed.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; ") }
        return text
    }
}

struct SecuritySettingsView: View {
    var body: some View {
        Form {
            Section("This app") {
                LabeledContent("App Sandbox", value: "Enabled")
                LabeledContent("Credential storage", value: "macOS Keychain (this device only)")
                LabeledContent("Stored credentials", value: "GitHub token only, if you saved one")
                LabeledContent("Network", value: "HTTPS only. GitHub read-only when you refresh")
            }
            Section("Local data") {
                LabeledContent("Inventory file") {
                    Text((try? JSONFileInventoryStore.defaultFileURL().path(percentEncoded: false)) ?? "Unavailable")
                        .textSelection(.enabled)
                        .font(.callout.monospaced())
                }
                Text("The inventory file contains no secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Authentication, roles, audit logging and server-side secret management arrive with the backend phase. See docs/security.md.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Security")
    }
}

/// App language. macOS picks the language at launch, so a change applies after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", dari = "fa-AF"
    var id: String { rawValue }

    /// Shown in its own language so it's recognisable whatever the current UI language is.
    var nativeName: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .dari: "دری"
        }
    }

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.object(forKey: "AppleLanguages") as? [String],
              UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil,
              let first = list.first else { return .system }
        return first.hasPrefix("fa") ? .dari : .english
    }

    /// Sets the app's language, and for Dari also the formatting locale (Persian digits,
    /// Solar Hijri calendar with Afghan month names). These are app-only settings.
    func apply() {
        let d = UserDefaults.standard
        switch self {
        case .system:
            d.removeObject(forKey: "AppleLanguages")
            d.removeObject(forKey: "AppleLocale")
        case .english:
            d.set(["en"], forKey: "AppleLanguages")
            d.removeObject(forKey: "AppleLocale")
        case .dari:
            d.set(["fa-AF"], forKey: "AppleLanguages")
            d.set("fa_AF", forKey: "AppleLocale")
        }
        Self.syncWritingDirection(rightToLeft: self == .dari)
    }

    /// Forces AppKit right-to-left for this app only (read at launch).
    static func syncWritingDirection(rightToLeft: Bool) {
        let d = UserDefaults.standard
        for key in ["NSForceRightToLeftWritingDirection", "AppleTextDirection"] {
            if rightToLeft { d.set(true, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }
}

/// Sign in with Apple → Supabase. Shows who is signed in, the sync state, and the user ID
/// that must be added to `app_admins` once.
private struct CloudAccountSection: View {
    @Environment(InventoryModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var rawNonce = ""

    var body: some View {
        Section {
            if !model.isCloudAvailable {
                Text("Cloud sync isn't configured in this build.").foregroundStyle(.secondary)
            } else if let user = model.cloudUser {
                LabeledContent("Signed in") { Text(verbatim: user.email ?? "Apple ID") }
                LabeledContent("User ID") {
                    Text(verbatim: user.userID).font(.caption.monospaced()).textSelection(.enabled)
                }
                statusRow
                HStack {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        if model.isSyncing { ProgressView().controlSize(.small) } else { Text("Sync Now") }
                    }
                    .disabled(model.isSyncing)
                    Spacer()
                    Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                }
            } else {
                Text("Local only. Sign in to keep the inventory on the Linumic server (Supabase) and use it on Mac and iPhone.")
                    .foregroundStyle(.secondary)
                SignInWithAppleButton(.signIn) { request in
                    rawNonce = AppleSignInNonce.make()
                    request.requestedScopes = [.email]
                    request.nonce = AppleSignInNonce.sha256(rawNonce)
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                            model.errorMessage = String(localized: "Apple didn't return an identity token.")
                            return
                        }
                        let nonce = rawNonce
                        Task { await model.signInWithApple(idToken: token, rawNonce: nonce) }
                    case .failure(let error):
                        if (error as? ASAuthorizationError)?.code != .canceled {
                            model.errorMessage = String(localized: "Sign in failed: \(error.localizedDescription)")
                        }
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 34)
            }
        } header: {
            Text("Cloud")
        } footer: {
            Text("Only accounts added as admins on the server can read or change data. Everything is also kept on this device, so it works offline.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.cloudStatus {
        case .synced(let at)?:
            Label(String(localized: "Synced \(at.formatted(date: .omitted, time: .shortened))"), systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case .offline(let reason)?:
            Label(reason, systemImage: "icloud.slash").foregroundStyle(.orange)
        case .pendingUpload(let reason)?:
            Label(String(localized: "Changes waiting to upload: \(reason)"), systemImage: "arrow.clockwise.icloud").foregroundStyle(.orange)
        case nil:
            Label("Not synced yet", systemImage: "icloud").foregroundStyle(.secondary)
        }
    }
}

struct AccountSettingsView: View {
    @State private var language = AppLanguage.current
    @State private var needsRelaunch = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                }
                .onChange(of: language) { language.apply(); needsRelaunch = true }
                if needsRelaunch {
                    #if os(macOS)
                    HStack {
                        Text("Relaunch to apply the new language.")
                        Spacer()
                        Button("Relaunch Now") { relaunch() }
                    }
                    #else
                    Text("Close and reopen the app to apply the new language.")
                    #endif
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Dari uses right-to-left layout, Persian digits and the Solar Hijri calendar with Afghan month names. Recorded evidence (quotes, sources) stays in its original language.")
            }
            CloudAccountSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
    }

    #if os(macOS)
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif
}
