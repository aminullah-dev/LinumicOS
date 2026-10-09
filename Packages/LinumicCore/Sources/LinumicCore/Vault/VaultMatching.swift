import Foundation

/// A sign-in form in the app that the Vault can fill: which product and environment, and what it asks for.
public struct VaultSignInForm: Sendable, Equatable {
    public var product: VaultProduct
    public var environment: VaultEnvironment
    public var loginKind: VaultLoginKind
    /// False for VELRO, which signs in with a phone number and an SMS code.
    public var needsPassword: Bool
    /// The page an entry created from this form points to, when the form has one.
    public var url: URL?

    public init(product: VaultProduct, environment: VaultEnvironment, loginKind: VaultLoginKind, needsPassword: Bool = true, url: URL? = nil) {
        self.product = product
        self.environment = environment
        self.loginKind = loginKind
        self.needsPassword = needsPassword
        self.url = url
    }

    public static func worktrack(_ env: WorkTrackEnvironment) -> VaultSignInForm {
        VaultSignInForm(product: .worktrack, environment: env.vaultEnvironment, loginKind: .email)
    }
    public static func talar(_ env: TalarEnvironment) -> VaultSignInForm {
        VaultSignInForm(product: .talar, environment: env.vaultEnvironment, loginKind: .email)
    }
    public static func safeBeauty(_ env: SafeBeautyEnvironment) -> VaultSignInForm {
        VaultSignInForm(product: .safeBeauty, environment: env.vaultEnvironment, loginKind: .phone)
    }
    public static func velro(_ env: VelroEnvironment) -> VaultSignInForm {
        VaultSignInForm(product: .velro, environment: env.vaultEnvironment, loginKind: .phone, needsPassword: false)
    }
}

extension WorkTrackEnvironment {
    public var vaultEnvironment: VaultEnvironment {
        switch self { case .production: .production; case .demo: .demo; case .localEmulator: .local }
    }
}

extension TalarEnvironment {
    public var vaultEnvironment: VaultEnvironment {
        switch self { case .production: .production; case .demo: .demo; case .localEmulator: .local }
    }
}

extension SafeBeautyEnvironment {
    public var vaultEnvironment: VaultEnvironment {
        switch self { case .production: .production; case .staging: .staging; case .localEmulator: .local }
    }
}

extension VelroEnvironment {
    public var vaultEnvironment: VaultEnvironment {
        switch self { case .production: .production; case .localBackend: .local }
    }
}

/// Which Vault entries fit a sign-in form, and whether a successful sign-in is already stored.
public enum VaultMatcher {
    /// Entries that can fill the form, best first: the exact environment before "any environment", entries with
    /// both a login and a password before partial ones, then the most recently changed. Entries for another
    /// environment, of a login kind the form can't take, or with nothing to fill are left out.
    public static func candidates(_ entries: [VaultEntry], for form: VaultSignInForm) -> [VaultEntry] {
        entries
            .filter { fits($0, form) && ($0.trimmedLogin != nil || (form.needsPassword && $0.hasPassword)) }
            .sorted { a, b in
                let ea = a.environment == form.environment, eb = b.environment == form.environment
                if ea != eb { return ea }
                let ca = a.trimmedLogin != nil && (a.hasPassword || !form.needsPassword)
                let cb = b.trimmedLogin != nil && (b.hasPassword || !form.needsPassword)
                if ca != cb { return ca }
                return a.updatedAt > b.updatedAt
            }
    }

    /// True when the Vault already holds this login for the form (with a password, when the form needs one).
    public static func isStored(_ entries: [VaultEntry], form: VaultSignInForm, login: String) -> Bool {
        let key = normalize(login, kind: form.loginKind)
        guard !key.isEmpty else { return true }
        return entries.contains { e in
            fits(e, form) && e.trimmedLogin.map { normalize($0, kind: form.loginKind) } == key && (e.hasPassword || !form.needsPassword)
        }
    }

    /// The existing entry a "Save to Vault" should fill instead of adding a new one: an entry with the same login
    /// (missing its password), otherwise an empty template for this product and environment. Nil means add a new entry.
    public static func saveTarget(_ entries: [VaultEntry], form: VaultSignInForm, login: String) -> VaultEntry? {
        let key = normalize(login, kind: form.loginKind)
        let fitting = entries.filter { fits($0, form) }
        if let same = fitting.first(where: { $0.trimmedLogin.map { normalize($0, kind: form.loginKind) } == key }) { return same }
        return fitting.filter(\.isEmpty).sorted { ($0.environment == form.environment) && ($1.environment != form.environment) }.first
    }

    /// The entry a "Save to Vault" writes: the target filled in, or a new entry titled after the product and environment.
    public static func entryToSave(_ entries: [VaultEntry], form: VaultSignInForm, login: String) -> VaultEntry {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        if var target = saveTarget(entries, form: form, login: login) {
            target.login = login
            target.loginKind = form.loginKind
            return target
        }
        return VaultEntry(title: "\(form.product.title) · \(form.environment.title)", product: form.product, environment: form.environment,
                          url: form.url, login: login, loginKind: form.loginKind)
    }

    /// Normalised login for comparison only (never stored): emails and usernames are compared without case;
    /// phone numbers by their national digits, so 0700…, 700…, +93700… and 0093700… are the same number.
    public static func normalize(_ login: String, kind: VaultLoginKind) -> String {
        let t = login.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .email, .username:
            return t.lowercased()
        case .phone:
            var digits = t.filter(\.isASCII).filter(\.isNumber)
            if digits.hasPrefix("00") { digits.removeFirst(2) }
            if digits.hasPrefix("93"), digits.count == 11 { digits.removeFirst(2) }
            while digits.hasPrefix("0") { digits.removeFirst() }
            return digits
        }
    }

    private static func fits(_ e: VaultEntry, _ form: VaultSignInForm) -> Bool {
        guard e.product == form.product else { return false }
        guard e.environment == form.environment || e.environment == .any else { return false }
        switch form.loginKind {
        case .phone: return e.loginKind == .phone || e.trimmedLogin == nil
        case .email, .username: return e.loginKind != .phone || e.trimmedLogin == nil
        }
    }
}
