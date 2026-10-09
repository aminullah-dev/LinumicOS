import Foundation

/// What a Vault entry signs in to. The groups the Vault list shows, in this order.
public enum VaultProduct: String, Codable, CaseIterable, Sendable, Identifiable {
    case worktrack
    case talar
    case safeBeauty
    case velro
    case mediflow
    case khayatyar
    case wordpress
    case godaddy
    case googlePlayConsole
    case appStoreConnect
    case github
    case supabase
    case firebase
    case other

    public var id: String { rawValue }

    /// Product and service names are brand names and stay as written; only "Other" is translated.
    public var title: String {
        switch self {
        case .worktrack: "WorkTrack"
        case .talar: "Talar"
        case .safeBeauty: "SafeBeauty"
        case .velro: "VELRO"
        case .mediflow: "MediFlow"
        case .khayatyar: "KhayatYar"
        case .wordpress: "linumic.com (WordPress)"
        case .godaddy: "GoDaddy"
        case .googlePlayConsole: "Google Play Console"
        case .appStoreConnect: "App Store Connect"
        case .github: "GitHub"
        case .supabase: "Supabase"
        case .firebase: "Firebase"
        case .other: L("Other")
        }
    }

    /// SF Symbol for the group header (never a brand logo).
    public var symbol: String {
        switch self {
        case .worktrack: "clock.badge.checkmark"
        case .talar: "building.columns"
        case .safeBeauty: "sparkles"
        case .velro: "car"
        case .mediflow: "cross.case"
        case .khayatyar: "scissors"
        case .wordpress: "globe"
        case .godaddy: "network"
        case .googlePlayConsole: "play.rectangle"
        case .appStoreConnect: "applelogo"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .supabase: "cylinder.split.1x2"
        case .firebase: "flame"
        case .other: "key"
        }
    }
}

/// Which deployment of a product an entry is for. `any` means the same account works everywhere,
/// or the service has only one (GitHub, GoDaddy).
public enum VaultEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case any
    case production
    case demo
    case staging
    case local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: L("Any environment")
        case .production: L("Production")
        case .demo: L("Demo")
        case .staging: L("Staging")
        case .local: L("Local")
        }
    }
}

/// What the entry's login is, so a sign-in form that wants a phone number isn't offered an email.
public enum VaultLoginKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case email
    case phone
    case username

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .email: L("Email")
        case .phone: L("Phone number")
        case .username: L("Username")
        }
    }

    public var symbol: String {
        switch self {
        case .email: "envelope"
        case .phone: "phone"
        case .username: "person"
        }
    }
}

/// One Vault entry's metadata. The password is never part of it: it lives in its own Keychain item and is
/// read only after the owner unlocks the Vault. `hasPassword` records whether that item was written.
public struct VaultEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var product: VaultProduct
    public var environment: VaultEnvironment
    public var url: URL?
    public var login: String?
    public var loginKind: VaultLoginKind
    public var notes: String
    public var hasPassword: Bool
    /// When the password was last set in the Vault (not when it was changed on the service).
    public var passwordChangedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// For entries the Vault created as empty templates: where the sign-in URL was verified.
    public var templateSource: String?

    public init(id: UUID = UUID(), title: String, product: VaultProduct, environment: VaultEnvironment = .any, url: URL? = nil,
                login: String? = nil, loginKind: VaultLoginKind = .email, notes: String = "", hasPassword: Bool = false,
                passwordChangedAt: Date? = nil, createdAt: Date = .now, updatedAt: Date? = nil, templateSource: String? = nil) {
        self.id = id
        self.title = title
        self.product = product
        self.environment = environment
        self.url = url
        self.login = login
        self.loginKind = loginKind
        self.notes = notes
        self.hasPassword = hasPassword
        self.passwordChangedAt = passwordChangedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.templateSource = templateSource
    }

    /// Trimmed login, nil when empty.
    public var trimmedLogin: String? {
        guard let t = login?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// A template nobody has filled in yet: no login and no password.
    public var isEmpty: Bool { trimmedLogin == nil && !hasPassword }

    /// Case- and diacritic-insensitive search over the metadata (never the password).
    public func matches(search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [title, product.title, login ?? "", url?.absoluteString ?? "", notes, environment.title]
            .contains { $0.localizedStandardContains(q) }
    }
}

/// The Vault's metadata document, stored as one Keychain item.
public struct VaultIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    /// The template set last added (see `VaultTemplates.revision`), so deleted templates never come back.
    public var templatesRevision: Int
    public var entries: [VaultEntry]

    public init(version: Int = VaultIndex.currentVersion, templatesRevision: Int = 0, entries: [VaultEntry] = []) {
        self.version = version
        self.templatesRevision = templatesRevision
        self.entries = entries
    }
}

/// Entries grouped for the list: product order as in `VaultProduct.allCases`, then production before other
/// environments, then title.
public func vaultGroups(_ entries: [VaultEntry]) -> [(product: VaultProduct, entries: [VaultEntry])] {
    let order = Dictionary(uniqueKeysWithValues: VaultEnvironment.allCases.enumerated().map { ($1, $0) })
    return VaultProduct.allCases.compactMap { product in
        let items = entries.filter { $0.product == product }.sorted {
            if $0.environment != $1.environment {
                // Production first, then any, demo, staging, local.
                let rank: (VaultEnvironment) -> Int = { $0 == .production ? -1 : order[$0]! }
                return rank($0.environment) < rank($1.environment)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return items.isEmpty ? nil : (product, items)
    }
}
