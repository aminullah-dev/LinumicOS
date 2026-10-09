import Foundation

/// What to do with an entry's password when it is saved.
public enum VaultPasswordChange: Sendable, Equatable {
    case keep
    case set(String)
    case remove
}

public enum VaultError: Error, LocalizedError, Equatable {
    case missingTitle
    case unreadableIndex
    case entryNotFound

    public var errorDescription: String? {
        switch self {
        case .missingTitle: L("Give the entry a title.")
        case .unreadableIndex: L("The Vault's list in the Keychain could not be read, so nothing was changed. No entry was overwritten.")
        case .entryNotFound: L("This entry is no longer in the Vault.")
        }
    }
}

/// The owner's credential Vault, entirely in this device's Keychain.
///
/// Layout (service `com.linumic.commandcenter.vault`, every item `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
/// not synchronizable, through `KeychainSecretStore`):
/// - `vault.index`: JSON `VaultIndex`, the metadata of every entry (title, product, environment, URL, login, notes,
///   dates). No password is ever in it.
/// - `vault.password.<entry id>`: one item per password, read only after the owner unlocks the Vault.
///
/// Nothing here goes to a file, UserDefaults, Supabase, iCloud or a log.
public struct VaultStore: Sendable {
    public static let keychainService = "com.linumic.commandcenter.vault"
    static let indexAccount = "vault.index"
    static func passwordAccount(_ id: UUID) -> String { "vault.password.\(id.uuidString)" }

    private let secrets: AccountSecretStore
    private let now: @Sendable () -> Date

    public init(secrets: AccountSecretStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.secrets = secrets
        self.now = now
    }

    /// The store the app uses: this device's Keychain, in the Vault's own service.
    public static func keychain() -> VaultStore {
        VaultStore(secrets: KeychainSecretStore(service: keychainService))
    }

    /// Reads the index. On first use (or when a newer template set exists) it adds the empty templates once and
    /// saves, so a template the owner deletes never comes back.
    public func load() throws -> VaultIndex {
        var index = try readIndex() ?? VaultIndex()
        if index.templatesRevision < VaultTemplates.revision {
            let at = now()
            index.entries += VaultTemplates.all
                .filter { $0.addedInRevision > index.templatesRevision }
                .map { $0.entry(createdAt: at) }
            index.templatesRevision = VaultTemplates.revision
            try writeIndex(index)
        }
        return index
    }

    /// Adds or updates an entry. The password item is written before the index, so the index never claims a
    /// password that isn't stored. Returns the entry as saved (dates and `hasPassword` set here).
    @discardableResult
    public func save(_ entry: VaultEntry, password: VaultPasswordChange = .keep) throws -> VaultEntry {
        var entry = entry
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.title.isEmpty else { throw VaultError.missingTitle }
        entry.login = entry.trimmedLogin
        var index = try readIndex() ?? VaultIndex(templatesRevision: VaultTemplates.revision)
        let existingAt = index.entries.firstIndex { $0.id == entry.id }
        let at = now()
        // Dates and the password flag are the store's to set, never the caller's.
        if let i = existingAt {
            entry.createdAt = index.entries[i].createdAt
            entry.hasPassword = index.entries[i].hasPassword
            entry.passwordChangedAt = index.entries[i].passwordChangedAt
        } else {
            entry.createdAt = at
            entry.hasPassword = false
            entry.passwordChangedAt = nil
        }

        var wrotePassword = false
        switch password {
        case .keep:
            break
        case .set(let value) where !value.isEmpty:
            try secrets.write(value, account: Self.passwordAccount(entry.id))
            wrotePassword = true
            entry.hasPassword = true
            entry.passwordChangedAt = at
        case .set, .remove:
            try secrets.delete(account: Self.passwordAccount(entry.id))
            entry.hasPassword = false
            entry.passwordChangedAt = nil
        }
        entry.updatedAt = at
        if let i = existingAt { index.entries[i] = entry } else { index.entries.append(entry) }
        do {
            try writeIndex(index)
        } catch {
            // A brand-new entry's password must not stay behind without an index line pointing to it.
            if wrotePassword, existingAt == nil { try? secrets.delete(account: Self.passwordAccount(entry.id)) }
            throw error
        }
        return entry
    }

    /// Deletes the password item first, then the index line.
    public func delete(id: UUID) throws {
        var index = try readIndex() ?? VaultIndex()
        try secrets.delete(account: Self.passwordAccount(id))
        index.entries.removeAll { $0.id == id }
        try writeIndex(index)
    }

    /// The stored password. Callers must have unlocked the Vault (Touch ID or the device password) first.
    public func password(for id: UUID) throws -> String? {
        try secrets.read(account: Self.passwordAccount(id))
    }

    // MARK: Index

    private func readIndex() throws -> VaultIndex? {
        guard let text = try secrets.read(account: Self.indexAccount) else { return nil }
        do {
            return try Self.decoder.decode(VaultIndex.self, from: Data(text.utf8))
        } catch {
            throw VaultError.unreadableIndex
        }
    }

    private func writeIndex(_ index: VaultIndex) throws {
        try secrets.write(String(decoding: try Self.encoder.encode(index), as: UTF8.self), account: Self.indexAccount)
    }

    private static let encoder: JSONEncoder = {
        // Default date encoding (seconds since 2001 as a Double) keeps dates exact across a round trip.
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}
