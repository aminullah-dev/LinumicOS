import Foundation
import Security

/// Names of stored credentials. Add a case for each new integration. Never store the secret values in code.
public enum SecretKey: String, CaseIterable, Sendable {
    case gitHubToken = "github.token"
    /// The signed-in Supabase session (access + refresh token), never written anywhere but the Keychain.
    case supabaseSession = "supabase.session"
    /// App Store Connect API key: Issuer ID, Key ID and the .p8 contents, as JSON.
    case appStoreConnectKey = "appstoreconnect.key"
    /// Google Play service-account JSON key.
    case googlePlayServiceAccount = "googleplay.serviceaccount"
    /// LNM1 licence signing keys (PKCS#8 PEM), imported by the owner on the Mac. Never uploaded.
    case licenceSigningMediflow = "licence.signing.mediflow"
    case licenceSigningKhayatyar = "licence.signing.khayatyar"
    /// WorkTrack vendor session: JSON `{environment, email, refreshToken}`. Never the password or the ID token.
    case workTrackVendorSession = "worktrack.vendor.session"
    /// Talar admin session: JSON `{environment, email, refreshToken}`. Never the password or the ID token.
    case talarAdminSession = "talar.admin.session"
    /// SafeBeauty admin session: JSON `{environment, appUID, name, refreshToken}`. Never the phone, password or salt.
    case safeBeautyAdminSession = "safebeauty.admin.session"
    /// VELRO staff session: JSON `{environment, userID, roles, refreshToken, deviceID}`, rewritten after every
    /// successful refresh (the token rotates). Never the phone number or the access token.
    case velroStaffSession = "velro.staff.session"
}

/// Credential storage. Values never appear in source, logs or the inventory file.
public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

/// Credential storage addressed by a free-form account name, for stores whose items aren't known at compile time
/// (the Vault keeps one item per entry). Same Keychain rules as `SecretStore`.
public protocol AccountSecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// An in-memory `AccountSecretStore` for tests and previews. Nothing leaves the process.
public final class InMemoryAccountSecretStore: AccountSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    public func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
    /// The account names currently stored (tests only check that nothing is left behind).
    public var accounts: [String] { lock.withLock { values.keys.sorted() } }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Keychain-backed generic-password store. Items are device-only, available only
/// while the device is unlocked, and never synced to iCloud.
///
/// It prefers the data-protection keychain. Builds signed without a team (ad-hoc local
/// development) lack the entitlement for it (`errSecMissingEntitlement`), and those fall
/// back to the login keychain, which is still device-local and encrypted.
public struct KeychainSecretStore: SecretStore, AccountSecretStore {
    public let service: String
    private let useDataProtection: Bool

    public init(service: String = "com.linumic.commandcenter") {
        self.init(service: service, useDataProtection: true)
    }

    private init(service: String, useDataProtection: Bool) {
        self.service = service
        self.useDataProtection = useDataProtection
    }

    private var fallback: KeychainSecretStore? {
        useDataProtection ? KeychainSecretStore(service: service, useDataProtection: false) : nil
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func read(_ key: SecretKey) throws -> String? { try read(account: key.rawValue) }
    public func write(_ value: String, for key: SecretKey) throws { try write(value, account: key.rawValue) }
    public func delete(_ key: SecretKey) throws { try delete(account: key.rawValue) }

    public func read(account key: String) throws -> String? {
        do { return try readOnce(key) } catch let e as KeychainError where e.status == errSecMissingEntitlement {
            guard let fallback else { throw e }
            return try fallback.read(account: key)
        }
    }

    public func write(_ value: String, account key: String) throws {
        do { try writeOnce(value, for: key) } catch let e as KeychainError where e.status == errSecMissingEntitlement {
            guard let fallback else { throw e }
            try fallback.write(value, account: key)
        }
    }

    public func delete(account key: String) throws {
        do { try deleteOnce(key) } catch let e as KeychainError where e.status == errSecMissingEntitlement {
            guard let fallback else { throw e }
            try fallback.delete(account: key)
        }
    }

    private func readOnce(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private func writeOnce(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private func deleteOnce(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
