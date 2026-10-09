import CryptoKit
import Foundation

/// Why a signing key was refused on import.
public enum SigningKeyError: Error, LocalizedError, Equatable, Sendable {
    /// Not a PEM P-256 private key (PKCS#8 "PRIVATE KEY" or SEC1 "EC PRIVATE KEY").
    case unreadable
    /// A public key was chosen instead of the private key.
    case publicKeyChosen
    /// A valid key, but it belongs to the other product.
    case otherProduct(expected: LicenceProduct, actual: LicenceProduct)
    /// A valid key that matches neither production public key (for example the test key).
    case mismatch(LicenceProduct)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            L("This file isn't a P-256 private key in PEM format. Choose <product>-private.pem.")
        case .publicKeyChosen:
            L("This is a public key. Signing needs the private key (<product>-private.pem).")
        case .otherProduct(let expected, let actual):
            LF("This is the %1$@ signing key, not the %2$@ one. Nothing was saved.", actual.displayName, expected.displayName)
        case .mismatch(let product):
            LF("This key doesn't match the %@ public key built into the app, so licences signed with it would be rejected. Nothing was saved.", product.displayName)
        }
    }
}

/// The private signing keys, kept only in this device's Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
/// not synchronised). They never go to the ledger, logs, Supabase or iCloud.
public struct LicenceSigningKeys: Sendable {
    private let secrets: SecretStore

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    public static func secretKey(for product: LicenceProduct) -> SecretKey {
        switch product {
        case .mediflow: .licenceSigningMediflow
        case .khayatyar: .licenceSigningKhayatyar
        }
    }

    /// Parses a PEM private key and checks that its public half is the production public key of
    /// `product`. The expected public key can be overridden by tests.
    public static func validate(pem: String, for product: LicenceProduct,
                                expected: P256.Signing.PublicKey? = nil) throws -> P256.Signing.PrivateKey {
        if pem.contains("BEGIN PUBLIC KEY") { throw SigningKeyError.publicKeyChosen }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { throw SigningKeyError.unreadable }
        let publicDER = key.publicKey.derRepresentation
        let target = expected ?? product.productionPublicKey
        if publicDER == target.derRepresentation { return key }
        if expected == nil, let other = LicenceProduct.allCases.first(where: { $0 != product && $0.productionPublicKey.derRepresentation == publicDER }) {
            throw SigningKeyError.otherProduct(expected: product, actual: other)
        }
        throw SigningKeyError.mismatch(product)
    }

    /// Validates and stores the key. Only the key's PKCS#8 PEM is stored, nothing else.
    public func importKey(pem: String, for product: LicenceProduct) throws {
        let key = try Self.validate(pem: pem, for: product)
        try secrets.write(key.pemRepresentation, for: Self.secretKey(for: product))
    }

    public func hasKey(for product: LicenceProduct) -> Bool {
        ((try? secrets.read(Self.secretKey(for: product))) ?? nil) != nil
    }

    /// The stored key, re-checked against the production public key every time it is used.
    public func signingKey(for product: LicenceProduct) throws -> P256.Signing.PrivateKey? {
        guard let pem = try secrets.read(Self.secretKey(for: product)) else { return nil }
        return try Self.validate(pem: pem, for: product)
    }

    public func removeKey(for product: LicenceProduct) throws {
        try secrets.delete(Self.secretKey(for: product))
    }
}
