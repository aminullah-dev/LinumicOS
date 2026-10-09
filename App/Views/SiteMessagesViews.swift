import LinumicCore
import SwiftUI

// MARK: - Website messages screen (پیام‌های سایت)

/// The linumic.com contact-form entries the app last read, new ones first. Each message opens in wp-admin or starts a
/// reply in the mail app; "Mark seen" is kept on this device only and changes nothing in WordPress.
struct SiteMessagesView: View {
    @Environment(SiteMessagesModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !model.isConfigured {
                    notConnected
                } else if let reading = model.reading {
                    let new = model.new
                    if new.isEmpty {
                        Label("No new messages. Everything read so far is marked seen.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(reading.messages) { m in
                        SiteMessageCard(message: m, isSeen: model.isSeen(m),
                                        toggleSeen: { model.isSeen(m) ? model.markUnseen(m) : model.markSeen(m) })
                    }
                    ReleaseSourceLine(source: SiteMessagesSource.sourceText, at: reading.readAt)
                    Text("Shows the newest \(SiteMessagesSource.pageSize) of \(reading.total) entries. Older ones are in wp-admin.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.loadError == nil {
                    Label("Connected, not read yet.", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
                Text("Messages are kept in memory only. This device stores just the ids you marked seen or were notified about (site-messages.json). Nothing is changed in WordPress.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(SidebarItem.siteMessages.title)
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(!model.isConfigured || model.isRefreshing)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            FitRow(spacing: 8) {
                if let n = model.newCount {
                    ReleaseBadge(text: String(localized: "\(n) new"), symbol: "envelope.badge", color: n > 0 ? .orange : .green)
                } else {
                    ReleaseBadge(text: String(localized: "Not read"), symbol: "questionmark.circle", color: .gray)
                }
                if !model.new.isEmpty {
                    Button("Mark all seen") { model.markAllSeen() }
                        .buttonStyle(.borderless).minTapTarget()
                }
                Link(destination: SiteMessagesSource.entriesAdminURL()) {
                    Label("All entries in wp-admin", systemImage: "safari")
                }
                .buttonStyle(.borderless).minTapTarget()
            }
            if let error = model.loadError {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    .font(.callout)
            }
        }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not connected", systemImage: "link.badge.plus").font(.headline)
            Text("The contact form's notification emails don't reach you, so the app reads the entries from WordPress. It needs an application password of an Administrator and SureForms' \u{2068}Enable Abilities\u{2069} setting.")
            Button("Open Settings → Integrations") { router.go(.integrations) }
                .minTapTarget()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SiteMessageCard: View {
    let message: SiteMessage
    let isSeen: Bool
    let toggleSeen: () -> Void

    var body: some View {
        StripeCard(tint: isSeen ? .gray : .orange) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: message.sender).font(.headline).textSelection(.enabled)
                Spacer(minLength: 8)
                if !isSeen { ReleaseBadge(text: String(localized: "New"), symbol: "envelope.badge", color: .orange) }
                if message.isUnreadInWordPress {
                    ReleaseBadge(text: String(localized: "Unread in WordPress"), symbol: "circle.fill", color: .blue)
                }
            }
            FitRow(spacing: 6) {
                if let at = message.createdAt {
                    Text(at.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text(verbatim: message.createdAtText)
                }
                if let email = message.email {
                    Text(verbatim: email).textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                }
                Text(verbatim: "\(message.formName) · #\(message.id)")
            }
            .font(.caption).foregroundStyle(.secondary)
            // The full text, in its own writing direction (a Dari message reads right to left in an English UI too).
            Text(verbatim: message.message.isEmpty ? String(localized: "(no message text)") : message.message)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            FitRow(spacing: 12) {
                Link(destination: message.adminURL()) { Label("Open in wp-admin", systemImage: "safari") }
                    .minTapTarget()
                if let reply = message.replyURL {
                    Link(destination: reply) { Label("Reply by email", systemImage: "arrowshape.turn.up.left") }
                        .minTapTarget()
                }
                Button(isSeen ? String(localized: "Mark as new") : String(localized: "Mark seen"), action: toggleSeen)
                    .minTapTarget()
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Settings → Integrations → Website messages: the WordPress application password (Keychain) and the notification.
struct SiteMessagesSettingsSection: View {
    @Environment(SiteMessagesModel.self) private var model
    @AppStorage(SiteMessagesModel.notifyKey) private var notify = true
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?

    var body: some View {
        Section {
            LabeledContent {
                StatusBadge(text: model.isConfigured ? "Password saved" : "Not connected", color: model.isConfigured ? .green : .gray)
            } label: {
                Label("linumic.com (WordPress)", systemImage: "envelope")
                Text("Reads contact-form entries through SureForms' read-only abilities. It never changes WordPress.")
            }
            if let user = model.username {
                LabeledContent("WordPress user") { Text(verbatim: user) }
            }
            TextField("WordPress username", text: $username, prompt: Text(model.username ?? "admin"))
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Application password", text: $password, prompt: Text(model.isConfigured ? "•••• •••• (stored in Keychain)" : "xxxx xxxx xxxx xxxx xxxx xxxx"))
                .textContentType(.password)
            HStack {
                Button("Save to Keychain") { save() }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                Button("Remove", role: .destructive) { remove() }
                    .disabled(!model.isConfigured)
                Spacer()
                Button {
                    Task { await model.refresh(); message = model.loadError ?? model.reading.map { _ in String(localized: "Read.") } }
                } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) } else { Text("Read now") }
                }
                .disabled(!model.isConfigured || model.isRefreshing)
            }
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            Toggle(isOn: $notify) {
                Text("Notify me about new website messages")
                Text("A local notification with the sender's name when a refresh finds a message you haven't seen. Read when the app opens and every 30 minutes.")
            }
            Link(destination: SiteMessagesSource.applicationPasswordsURL()) { Label("Create an application password in wp-admin", systemImage: "safari") }
            Link(destination: SiteMessagesSource.sureFormsSettingsURL()) { Label("SureForms settings (Enable Abilities)", systemImage: "safari") }
        } header: {
            Text("Website messages")
        } footer: {
            Text("1. wp-admin → Users → Profile → Application Passwords: name it \u{2068}Linumic OS\u{2069} and press Add. Copy the password once. 2. SureForms → Settings: turn on \u{2068}Enable Abilities\u{2069} (leave Edit and Delete off). 3. Paste your username and the password here. It is stored only in this device's Keychain (wordpress.linumic.apppassword) and sent only to https://linumic.com. Revoke it in the same WordPress screen at any time.")
        }
        .onAppear { username = model.username ?? "" }
    }

    private func save() {
        do {
            try model.saveCredential(username: username, password: password)
            password = ""
            message = String(localized: "Saved to the Keychain.")
            Task { await model.refresh(); message = model.loadError ?? String(localized: "Saved and read.") }
        } catch {
            password = ""
            message = String(localized: "Could not save: \(error.localizedDescription)")
        }
    }

    private func remove() {
        do {
            try model.removeCredential()
            message = String(localized: "Removed.")
        } catch {
            message = String(localized: "Could not remove: \(error.localizedDescription)")
        }
    }
}
