import Foundation
import LinumicCore
import LocalAuthentication
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// The Vault (گاوصندوق): the owner's own sign-in details, in this device's Keychain only (`VaultStore`).
///
/// Metadata (titles, logins, URLs, notes) is shown without unlocking. A password is shown, copied or used to fill a
/// sign-in form only after Touch ID or the device password (`deviceOwnerAuthentication`). The Vault then stays
/// unlocked for two minutes, and locks earlier when the Mac sleeps, its screen locks or the app is hidden (on
/// iPhone and iPad: when the app goes to the background). Revealed passwords are held in memory only while unlocked.
@MainActor
@Observable
final class VaultModel {
    private(set) var entries: [VaultEntry] = []
    private(set) var loadError: String?
    private(set) var window = VaultUnlockWindow()
    /// A short confirmation after a copy ("Password copied, clears in 30 seconds").
    private(set) var copyNotice: String?
    var errorMessage: String?

    private var revealed: [UUID: String] = [:]
    private let store: VaultStore
    private let clipboard: ClipboardGuard
    private var lockTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(store: VaultStore = .keychain()) {
        self.store = store
        clipboard = ClipboardGuard(pasteboard: SystemPasteboard())
        observeSystemLockEvents()
    }

    func load() {
        do {
            entries = try store.load().entries
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    var groups: [(product: VaultProduct, entries: [VaultEntry])] { vaultGroups(entries) }
    func entry(_ id: UUID) -> VaultEntry? { entries.first { $0.id == id } }

    // MARK: Lock

    var isUnlocked: Bool { window.isUnlocked(at: .now) }
    var unlockedUntil: Date? { isUnlocked ? window.unlockedUntil : nil }

    /// Asks for Touch ID or the device password unless the Vault is already unlocked. False when cancelled or failed.
    @discardableResult
    func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        do {
            try await Self.authenticate(reason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        window.unlock(at: .now)
        lockTask?.cancel()
        let delay = window.duration
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
        return true
    }

    /// Locks now and forgets every revealed password.
    func lock() {
        lockTask?.cancel()
        lockTask = nil
        window.lock()
        revealed.removeAll()
    }

    /// Runs the system prompt off the main actor; the context never leaves this function.
    nonisolated private static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.passcodeNotSet)
        }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    private func observeSystemLockEvents() {
        #if os(macOS)
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
            (NotificationCenter.default, NSApplication.didHideNotification),
        ]
        #else
        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, UIApplication.didEnterBackgroundNotification),
        ]
        #endif
        observers = names.map { center, name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
    }

    /// Locks when the app leaves the foreground (iOS scene phase; also called by the app on macOS when every
    /// window is closed).
    func appMovedToBackground() { lock() }

    // MARK: Reveal and copy

    /// The revealed password while the Vault is unlocked, else nil.
    func revealedPassword(_ id: UUID) -> String? { isUnlocked ? revealed[id] : nil }

    func toggleReveal(_ entry: VaultEntry) async {
        if revealedPassword(entry.id) != nil { revealed[entry.id] = nil; return }
        guard let password = await password(for: entry, reason: String(localized: "Show the password for \(entry.title)")) else { return }
        revealed[entry.id] = password
    }

    func copyPassword(_ entry: VaultEntry) async {
        guard let password = await password(for: entry, reason: String(localized: "Copy the password for \(entry.title)")) else { return }
        clipboard.copy(password)
        notice(String(localized: "Password copied. The clipboard clears in 30 seconds."))
    }

    /// Logins aren't secret, so copying one needs no unlock; it still clears after 30 seconds.
    func copyLogin(_ entry: VaultEntry) {
        guard let login = entry.trimmedLogin else { return }
        clipboard.copy(login)
        notice(String(localized: "\(entry.loginKind.title) copied. The clipboard clears in 30 seconds."))
    }

    private func password(for entry: VaultEntry, reason: String) async -> String? {
        guard entry.hasPassword, await unlock(reason: reason) else { return nil }
        do {
            guard let value = try store.password(for: entry.id) else {
                errorMessage = String(localized: "The password for this entry is no longer in the Keychain. Edit the entry to save it again.")
                return nil
            }
            return value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func notice(_ text: String) {
        copyNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.copyNotice = nil
        }
    }

    // MARK: Edit

    /// Saves an entry. Replacing or removing a password that is already stored needs the Vault unlocked.
    @discardableResult
    func save(_ entry: VaultEntry, password: VaultPasswordChange) async -> Bool {
        let existing = self.entry(entry.id)
        if existing?.hasPassword == true, password != .keep,
           !(await unlock(reason: String(localized: "Change the saved password for \(entry.title)"))) {
            return false
        }
        do {
            try store.save(entry, password: password)
            revealed[entry.id] = nil
            load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes after Touch ID or the device password (the view has already asked for confirmation).
    func delete(_ entry: VaultEntry) async {
        guard await unlock(reason: String(localized: "Delete \(entry.title) from the Vault")) else { return }
        do {
            try store.delete(id: entry.id)
            revealed[entry.id] = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Sign-in assist

    func candidates(for form: VaultSignInForm) -> [VaultEntry] { VaultMatcher.candidates(entries, for: form) }

    /// The login and (when the form needs one) the password of an entry, after Touch ID or the device password.
    func fill(_ entry: VaultEntry, form: VaultSignInForm) async -> (login: String?, password: String?)? {
        guard form.needsPassword, entry.hasPassword else { return (entry.trimmedLogin, nil) }
        guard let password = await password(for: entry, reason: String(localized: "Fill the sign-in form with \(entry.title)")) else { return nil }
        return (entry.trimmedLogin, password)
    }

    /// An offer to keep a login that just worked, or nil when the Vault already holds it.
    func saveOffer(form: VaultSignInForm, login: String, password: String?) -> VaultSaveOffer? {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, loadError == nil, !VaultMatcher.isStored(entries, form: form, login: login) else { return nil }
        if form.needsPassword, (password ?? "").isEmpty { return nil }
        return VaultSaveOffer(form: form, login: login, password: password)
    }

    /// Saves an accepted offer: fills the matching template or same-login entry, or adds a new entry. No unlock is
    /// needed, because it never replaces a password that is already stored.
    func accept(_ offer: VaultSaveOffer) {
        let entry = VaultMatcher.entryToSave(entries, form: offer.form, login: offer.login)
        do {
            try store.save(entry, password: offer.password.map { .set($0) } ?? .keep)
            load()
            notice(String(localized: "Saved to the Vault."))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// What a sign-in sheet offers to keep after a successful sign-in. Held only until the owner answers.
struct VaultSaveOffer: Identifiable {
    let id = UUID()
    let form: VaultSignInForm
    let login: String
    let password: String?
}

// MARK: - Pasteboard

/// The system pasteboard. macOS: the value is marked `org.nspasteboard.ConcealedType` and
/// `org.nspasteboard.TransientType` (nspasteboard.org), which clipboard managers skip. iOS: the item is local only
/// (never to Universal Clipboard) and expires on its own.
@MainActor
final class SystemPasteboard: VaultPasteboard {
    #if os(macOS)
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var changeCount: Int { NSPasteboard.general.changeCount }

    func writeConcealed(_ value: String, expiresAfter: TimeInterval) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, Self.concealed, Self.transient], owner: nil)
        pb.setString(value, forType: .string)
        pb.setString(value, forType: Self.concealed)
        pb.setData(Data(), forType: Self.transient)
    }

    func currentString() -> String? { NSPasteboard.general.string(forType: .string) }
    func clear() { NSPasteboard.general.clearContents() }
    #else
    var changeCount: Int { UIPasteboard.general.changeCount }

    func writeConcealed(_ value: String, expiresAfter: TimeInterval) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(expiresAfter)])
    }

    /// Reading would show the system paste notice, so the change count alone decides.
    func currentString() -> String? { nil }
    func clear() { UIPasteboard.general.items = [] }
    #endif
}
