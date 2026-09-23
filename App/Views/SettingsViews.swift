import AppKit
import LinumicCore
import SwiftUI

struct IntegrationsSettingsView: View {
    @Environment(InventoryModel.self) private var model
    @State private var tokenInput = ""
    @State private var hasToken = false
    @State private var message: String?

    private let integrations: [(name: String, symbol: String, plan: String)] = [
        ("App Store Connect", "applelogo", "Phase 4: read-only API key"),
        ("Google Play Console", "play.rectangle", "Phase 4: read-only service account"),
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
                    HStack {
                        Text("Relaunch to apply the new language.")
                        Spacer()
                        Button("Relaunch Now") { relaunch() }
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Dari uses right-to-left layout, Persian digits and the Solar Hijri calendar with Afghan month names. Recorded evidence (quotes, sources) stays in its original language.")
            }
            Section {
                LabeledContent("Mode", value: "Local only")
                LabeledContent("Signed in", value: "No account. The backend is not built yet.")
            } footer: {
                Text("Sign-in and role-based access will be added with the cloud backend.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
