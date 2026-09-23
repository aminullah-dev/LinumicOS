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
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
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
                        Label(i.name, systemImage: i.symbol)
                        Text(i.plan)
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
            message = "Token saved to the Keychain."
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func removeToken() {
        do {
            try model.secrets.delete(.gitHubToken)
            hasToken = false
            message = "Token removed."
        } catch {
            message = "Could not remove: \(error.localizedDescription)"
        }
    }

    private func syncSummary() -> String? {
        guard let sync = model.lastGitHubSync else { return nil }
        var text = "Refreshed \(sync.report.updated.count) repositories at \(sync.at.formatted(date: .omitted, time: .shortened))."
        if !sync.report.failed.isEmpty { text += " \(sync.report.failed.count) failed: " + sync.report.failed.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; ") }
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

struct AccountSettingsView: View {
    var body: some View {
        Form {
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
}
