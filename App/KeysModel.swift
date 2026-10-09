import Foundation
import LinumicCore
import Observation
import Security
#if os(macOS)
import AppKit
#endif

/// Keys & Backups (کلیدها و پشتیبان‌ها): the registry of signing keys, licence keys and their encrypted backups
/// (`keys-registry.json`, facts only), and on the Mac a local check of each key file's existence, size and
/// modification date. The app never reads, hashes, copies or uploads a key, a keystore, a .p8, a .pem, a password
/// file or the backup passphrase. For the passphrase it only asks the Keychain whether the item exists (attributes,
/// never data). No network.
@MainActor
@Observable
final class KeysModel {
    private(set) var registry: KeysRegistry
    /// Set when `keys-registry.json` exists but can't be read; the file is then never overwritten.
    private(set) var loadError: String?
    private(set) var results: [String: KeyCheckResult] = [:]
    private(set) var scan: KeysScanResult?
    private(set) var passphrase: [String: KeychainPresence] = [:]
    private(set) var checkedAt: Date?
    private(set) var isChecking = false
    /// The granted folders, home-relative, for display.
    private(set) var grantedFolders: [String] = []
    var errorMessage: String?

    private let store: KeysRegistryStore?
    /// The real home folder (in the sandbox `NSHomeDirectory()` is the app's container).
    let home: String = KeysModel.realHome()

    init() {
        store = (try? KeysRegistryStore.defaultFileURL()).map(KeysRegistryStore.init(fileURL:))
        if let store {
            if let loaded = store.load() {
                registry = loaded
            } else {
                registry = .seed
                loadError = String(localized: "keys-registry.json could not be read. The seeded facts are shown and nothing is saved until the file is fixed or removed.")
            }
        } else {
            registry = .seed
        }
        grantedFolders = KeysAccessStore.grantedPaths().map { KeyPaths.abbreviate($0, home: home) }
    }

    /// Local checks exist only on the Mac. On iPhone and iPad the registry is shown on its own.
    static var supportsLocalChecks: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: Derived

    var checkInput: KeysCheckInput {
        KeysCheckInput(registry: registry, now: .now, home: home, results: Array(results.values), scan: scan,
                       passphrase: passphrase, checkedAt: checkedAt)
    }

    var reminders: [KeysReminder] { KeysRules.reminders(checkInput) }

    /// Scan locations the app may not read, home-relative.
    var notGranted: [String] {
        (scan?.roots ?? []).compactMap { if case .notGranted = $0.status { $0.root } else { nil } }
    }

    var briefInput: BriefKeysInput { BriefKeysInput(check: checkInput, notGranted: notGranted) }

    func result(for key: TrackedKey) -> KeyCheckResult? { results[key.id] }

    func backupState(_ key: TrackedKey) -> KeyBackupState {
        KeysRules.backupState(key, registry: registry, result: results[key.id])
    }

    // MARK: Editing (every change is saved at once)

    func upsert(_ key: TrackedKey) { mutate { $0.upsert(key, now: .now) } }
    func removeKey(_ id: String) { mutate { $0.removeKey(id, now: .now) } }
    func upsert(_ backup: BackupRecord) { mutate { $0.upsert(backup, now: .now) } }
    func upsert(_ gap: KeyGap) { mutate { $0.upsert(gap, now: .now) } }
    func reopenGap(_ id: String) { mutate { $0.reopenGap(id, now: .now) } }

    @discardableResult
    func recordRestoreTest(backupID: String, on day: KeyDay, by: String, note: String?) -> Bool {
        var ok = false
        mutate {
            ok = $0.recordRestoreTest(backupID: backupID, RestoreTest(on: day, by: by, note: note, source: String(localized: "Entered in Linumic OS"),
                                                                      enteredAt: .now), now: .now)
        }
        return ok
    }

    @discardableResult
    func closeGap(_ id: String, on day: KeyDay, note: String?) -> Bool {
        var ok = false
        mutate { ok = $0.closeGap(id, on: day, note: note, now: .now) }
        return ok
    }

    private func mutate(_ change: (inout KeysRegistry) -> Void) {
        guard loadError == nil else {
            errorMessage = loadError
            return
        }
        var copy = registry
        change(&copy)
        guard copy != registry else { return }
        do {
            try store?.save(copy)
            registry = copy
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Local checks (macOS)

    /// Checks every registry path, scans the key folders by file name, and asks the Keychain whether the passphrase
    /// item exists. Attributes only; runs off the main actor inside the granted security scopes.
    func check() async {
        #if os(macOS)
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let registry = registry
        let home = home
        let urls = KeysAccessStore.resolveAll()
        grantedFolders = urls.map { KeyPaths.abbreviate($0.path, home: home) }
        let outcome = await Task.detached(priority: .utility) { () -> ([KeyCheckResult], KeysScanResult) in
            let started = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
            let access = KeyAccess(roots: started.map(\.path))
            let fs = LocalKeyFileSystem()
            let results = registry.keys.map { KeyChecker.check($0, home: home, access: access, fs: fs) }
            let scan = KeysScanner.scan(home: home, access: access, fs: fs)
            return (results, scan)
        }.value
        results = Dictionary(outcome.0.map { ($0.keyID, $0) }, uniquingKeysWith: { a, _ in a })
        scan = outcome.1
        passphrase = Dictionary(uniqueKeysWithValues: registry.passphraseServices.map { ($0, Self.keychainItemPresence(service: $0)) })
        checkedAt = .now
        #endif
    }

    /// Asks the Keychain for the item's attributes only (`kSecReturnAttributes`), never its data, so the passphrase is
    /// never read. Searches the login keychain, where the item was created.
    nonisolated static func keychainItemPresence(service: String) -> KeychainPresence {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: false,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .missing
        default: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    #if os(macOS)
    /// Lets the owner grant read-only access to a folder (one of the key locations, or a folder above them).
    func chooseFolder(suggested: String) {
        guard let url = KeysAccessStore.choose(suggested: KeyPaths.expand(suggested, home: home)) else { return }
        grantedFolders = (grantedFolders + [KeyPaths.abbreviate(url.path, home: home)]).uniqued()
        Task { await check() }
    }

    func revokeFolders() {
        KeysAccessStore.removeAll()
        grantedFolders = KeysAccessStore.grantedPaths().map { KeyPaths.abbreviate($0, home: home) }
        results = [:]
        scan = nil
        checkedAt = nil
    }
    #endif

    nonisolated static func realHome() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Read-only security-scoped bookmarks to the folders the owner chose for Keys & Backups, plus the repositories
/// workspace already chosen for Oversight (`WorkspaceStore`). The same pattern as `WorkspaceStore`, several folders.
enum KeysAccessStore {
    private static let defaultsKey = "LCCKeysBookmarks"

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Paths of the stored grants (for display before they are resolved).
    static func grantedPaths() -> [String] {
        var paths = Array(bookmarks.keys)
        if let w = WorkspaceStore.displayPath { paths.append(w) }
        return Array(Set(paths)).sorted()
    }

    #if os(macOS)
    @MainActor
    static func choose(suggested: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: suggested)
        panel.prompt = String(localized: "Grant read access")
        panel.message = String(localized: "Choose a folder that holds keys. Linumic OS reads only file names, sizes and dates in it, never the files.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            var all = bookmarks
            all[url.path] = data
            bookmarks = all
            return url
        } catch {
            return nil
        }
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Resolves every stored grant (refreshing stale bookmarks) and the Oversight workspace.
    static func resolveAll() -> [URL] {
        var out: [URL] = []
        var all = bookmarks
        for (path, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue
            }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                all[path] = fresh
            }
            out.append(url)
        }
        bookmarks = all
        if let workspace = WorkspaceStore.resolvedURL() { out.append(workspace) }
        return out
    }
    #else
    static func resolveAll() -> [URL] { [] }
    #endif
}
