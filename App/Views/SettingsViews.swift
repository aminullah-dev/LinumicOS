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
    @AppStorage(InventoryModel.autoRefreshKey) private var autoRefresh = true
    @AppStorage(InventoryModel.notifyKey) private var notifyChanges = true
    @AppStorage(InventoryModel.autoRefreshOversightKey) private var autoRefreshOversight = true
    @AppStorage(InventoryModel.notifyOversightKey) private var notifyOversight = true
    @AppStorage(LicenceModel.notifyKey) private var notifyLicences = true
    @AppStorage(PlatformHubModel.autoRefreshKey) private var autoRefreshPlatforms = true
    @Environment(LicenceModel.self) private var licences
    @Environment(WorkTrackModel.self) private var worktrack
    @AppStorage(WorkTrackModel.notifyKey) private var notifyWorkTrack = true
    @Environment(OperationsModel.self) private var operations
    @AppStorage(OperationsModel.notifyKey) private var notifyOperations = true
    @AppStorage(MonitorModel.notifyKey) private var notifyMonitor = true
    @AppStorage(ReleaseCenterModel.autoRefreshKey) private var autoRefreshReleases = true

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
                Text("Use a fine-grained token with read-only Metadata, Contents, Issues, Pull requests, Actions, and (for oversight) Dependabot alerts and Administration. A classic token with the repo scope also works. It's stored only in this Mac's Keychain.")
            }
            StoreConsoleSection(store: .appStore)
            StoreConsoleSection(store: .googlePlay)
            Section {
                Toggle(isOn: $autoRefresh) {
                    Text("Refresh store status automatically")
                    Text("When the app opens, then every 30 minutes while it's open. Only connected stores are read.")
                }
                Toggle(isOn: $notifyChanges) {
                    Text("Notify me about store changes")
                    Text("A notification when a version goes live, is rejected, or a new one is waiting.")
                }
            } header: {
                Text("Automatic refresh")
            }
            Section {
                Toggle(isOn: $autoRefreshOversight) {
                    Text("Sweep all repositories automatically")
                    Text("When the app opens, then every 30 minutes while it's open. Reads GitHub (and your local folder, if chosen) read-only. Needs a GitHub token.")
                }
                Toggle(isOn: $notifyOversight) {
                    Text("Notify me about oversight changes")
                    Text("A notification when a new security alert appears, CI breaks, or uncommitted work shows up.")
                }
            } header: {
                Text("Project oversight")
            }
            Section {
                Toggle(isOn: $autoRefreshPlatforms) {
                    Text("Refresh platforms automatically")
                    Text("When the app opens, then every 30 minutes while it's open. Reads versions, releases, CI and pull requests from GitHub with conditional requests, read-only. Needs a GitHub token.")
                }
            } header: {
                Text("Platforms")
            }
            Section {
                Toggle(isOn: $notifyLicences) {
                    Text("Remind me before licences expire")
                    Text("Local notifications 30, 14, 7 and 1 days before a MediFlow or KhayatYar licence's last valid day.")
                }
                .onChange(of: notifyLicences) { Task { await LicenceNotifier.reschedule(for: licences.records) } }
            } header: {
                Text("Licences")
            }
            Section {
                LabeledContent("Vendor account") {
                    if let s = worktrack.session {
                        HStack(spacing: 6) {
                            WorkTrackEnvironmentBadge(environment: s.environment)
                            Text(verbatim: s.email)
                        }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $notifyWorkTrack) {
                    Text("Remind me before WorkTrack licences expire")
                    Text("Local notifications 30, 14, 7 and 1 days before a production customer's last licensed day (TEST and DUPLICATE companies excluded). The list is read when the app opens and every 6 hours while it's open.")
                }
                .onChange(of: notifyWorkTrack) { Task { await WorkTrackNotifier.reschedule(for: worktrack.companies, environment: worktrack.environment) } }
            } header: {
                Text("WorkTrack customers")
            } footer: {
                Text("Sign in under WorkTrack customers in the sidebar. Only a refresh token is kept, in this device's Keychain (worktrack.vendor.session).")
            }
            Section {
                LabeledContent("Talar") {
                    if let s = operations.talar.session {
                        HStack(spacing: 6) { OpsEnvironmentBadge(s.environment); Text(verbatim: s.email) }
                    } else { Text("Not signed in").foregroundStyle(.secondary) }
                }
                LabeledContent("SafeBeauty") {
                    if let s = operations.safeBeauty.session {
                        HStack(spacing: 6) { OpsEnvironmentBadge(s.environment); Text(verbatim: s.name.isEmpty ? s.appUID : s.name) }
                    } else { Text("Not signed in").foregroundStyle(.secondary) }
                }
                LabeledContent("VELRO") {
                    if let s = operations.velro.session {
                        HStack(spacing: 6) { OpsEnvironmentBadge(s.environment); Text(verbatim: s.roles.joined(separator: ", ")) }
                    } else { Text("Not signed in").foregroundStyle(.secondary) }
                }
                Toggle(isOn: $notifyOperations) {
                    Text("Notify me when a queue starts waiting")
                    Text("A notification when a production queue goes from empty to waiting: Talar halls or reviews, SafeBeauty identity checks or salon approvals, VELRO drivers. Queues are read when the app opens and every 30 minutes while it's open.")
                }
            } header: {
                Text("Operations")
            } footer: {
                Text("Sign in under Operations in the sidebar. Only refresh tokens are kept, in this device's Keychain (talar.admin.session, safebeauty.admin.session, velro.staff.session); the last queue counts are kept for the notifications, nothing else.")
            }
            Section {
                Toggle(isOn: $notifyMonitor) {
                    Text("Notify me when a platform goes down")
                    Text("After two failed checks in a row, when it is back, and when a TLS certificate or the linumic.com registration enters the 30, 14 or 7-day window.")
                }
            } header: {
                Text("Monitor")
            } footer: {
                Text("Public pages and health endpoints only, with no credentials. Checked when the app opens and every 5 minutes while it runs; the last 24 hours stay on this device (monitor.json).")
            }
            Section {
                Toggle(isOn: $autoRefreshReleases) {
                    Text("Refresh releases automatically")
                    Text("When the app opens, then every 30 minutes while it's open. Reads App Store Connect, Google Play and GitHub with the credentials above.")
                }
            } header: {
                Text("Releases")
            } footer: {
                Text("Reads only. The one write is releasing an approved App Store version, which you confirm each time; it needs an App Store Connect key with the App Manager or Admin role.")
            }
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
                Text("Later")
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
    private var steps: [LocalizedStringKey] {
        isApple ? [
            "In App Store Connect, open \u{2068}Users and Access › Integrations\u{2069}.",
            "Under \u{2068}App Store Connect API › Team Keys\u{2069}, create a key with the \u{2068}Developer\u{2069} role.",
            "Download the key file (Apple allows this only once) and copy the \u{2068}Issuer ID\u{2069} shown above the keys.",
            "Enter the Issuer ID here, choose the file, and save. The Key ID is filled in from the file name.",
        ] : [
            "In Google Cloud, create a project (free) and enable the \u{2068}Google Play Android Developer API\u{2069}.",
            "Create a service account and download a JSON key for it.",
            "In Play Console, open \u{2068}Users and permissions\u{2069} and invite the service account's email with \u{2068}View app information (read-only)\u{2069}.",
            "Choose the JSON file here and save.",
        ]
    }

    private var setupLink: (title: LocalizedStringKey, url: URL) {
        isApple ? ("Open App Store Connect", URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                : ("Open Google Cloud Console", URL(string: "https://console.cloud.google.com/apis/library/androidpublisher.googleapis.com")!)
    }

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
                SetupSteps(steps: steps, link: setupLink)
                if isApple {
                    TextField("Issuer ID", text: $issuerID, prompt: Text(verbatim: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
                    TextField("Key ID", text: $keyID, prompt: Text(verbatim: "ABC123DEFG"))
                }
                HStack {
                    Button(isApple ? "Choose Key File (p8)…" : "Choose Key File (JSON)…") { isImporting = true }
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
            Text("Free. Read-only. The key stays in this Mac's Keychain and is never uploaded.")
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
        if !sync.report.failed.isEmpty { text += " " + String(localized: "\(sync.report.failed.count) failed:") + "\n" + sync.report.failureSummary }
        return text
    }
}

/// Numbered setup instructions with a link to the console where they start.
private struct SetupSteps: View {
    let steps: [LocalizedStringKey]
    let link: (title: LocalizedStringKey, url: URL)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text((i + 1).formatted())
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .trailing)
                    Text(steps[i])
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Link(destination: link.url) {
                Label(link.title, systemImage: "arrow.up.forward.square")
            }
            .font(.callout)
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

struct SecuritySettingsView: View {
    var body: some View {
        Form {
            Section("This app") {
                LabeledContent("App Sandbox", value: "Enabled")
                LabeledContent("Credential storage", value: "macOS Keychain (this device only)")
                LabeledContent("Stored credentials", value: "Only what you added: GitHub token, store console keys, licence signing keys (Mac)")
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
