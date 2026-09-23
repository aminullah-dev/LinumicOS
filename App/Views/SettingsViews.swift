import LinumicCore
import SwiftUI

struct IntegrationsSettingsView: View {
    private let integrations: [(name: String, symbol: String, plan: String)] = [
        ("GitHub", "chevron.left.forwardslash.chevron.right", "Phase 2: read-only token in Keychain"),
        ("App Store Connect", "applelogo", "Phase 4: read-only API key"),
        ("Google Play Console", "play.rectangle", "Phase 4: read-only service account"),
        ("Social networks", "bubble.left.and.bubble.right", "Phase 5: OAuth, approval before publishing"),
        ("AI provider", "sparkles", "Phase 6: key held on backend"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(integrations, id: \.name) { i in
                    LabeledContent {
                        StatusBadge(text: "Not connected", color: .gray)
                    } label: {
                        Label(i.name, systemImage: i.symbol)
                        Text(i.plan)
                    }
                }
            } footer: {
                Text("No integration is connected. Each one will be added only with explicit credentials and authorization. See docs/integrations.md.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
    }
}

struct SecuritySettingsView: View {
    var body: some View {
        Form {
            Section("This app") {
                LabeledContent("App Sandbox", value: "Enabled")
                LabeledContent("Credential storage", value: "macOS Keychain (this device only)")
                LabeledContent("Stored credentials", value: "None")
                LabeledContent("Network", value: "HTTPS only, no integrations active")
            }
            Section("Local data") {
                LabeledContent("Inventory file") {
                    Text((try? JSONFileInventoryStore.defaultFileURL().path()) ?? "Unavailable")
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
