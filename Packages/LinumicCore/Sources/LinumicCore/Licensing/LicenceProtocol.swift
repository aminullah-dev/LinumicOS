import CryptoKit
import Foundation

// Linumic licence protocol, version 1 (LNM1). The reference is `licensing/PROTOCOL.md` and the
// issuing tool `licensing/linumic_license.py` next to this repository; this file must produce and
// accept exactly the same keys.
//
//   LNM1.<base64url(payload JSON)>.<base64url(DER ECDSA P-256/SHA-256 signature over the JSON bytes)>
//
// Only *public* keys live in code. A private signing key is imported by the owner into the Keychain
// (see `LicenceSigningKeys`) and never appears in source, logs, the ledger or Supabase.

/// A product that uses LNM1 offline licences.
public enum LicenceProduct: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    case mediflow
    case khayatyar

    public var id: String { rawValue }

    /// Shown in the UI. Product names are not translated.
    public var displayName: String {
        switch self {
        case .mediflow: "MediFlow"
        case .khayatyar: "KhayatYar"
        }
    }

    /// Licence id prefix, as in the Python tool (`MF-2026-0001`, `KY-2026-0001`).
    public var idPrefix: String {
        switch self {
        case .mediflow: "MF"
        case .khayatyar: "KY"
        }
    }

    /// Production public key, copied on 2026-10-08 from `licensing/public/<product>-public.pem`.
    /// The private half signs licences; it is never in this repository.
    public var productionPublicKeyPEM: String {
        switch self {
        case .mediflow:
            """
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEu2YAmOhZzLpumwyOXTP02TtnjSli
            BKjaQq7OYMYWd1gRcSTYvp53XOyUB4wLfmTF2faRBHzIdb/AFIZ9jaiv/g==
            -----END PUBLIC KEY-----
            """
        case .khayatyar:
            """
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmO5oWyI7lvDaIgR1vuJvKgTDz+sM
            dAYKM/BTMmoO2/5XG2M/gsAVKur9BcQQIo8CVq0UUO2NZyEIhvi+osMdIg==
            -----END PUBLIC KEY-----
            """
        }
    }

    public var productionPublicKey: P256.Signing.PublicKey {
        // The constants above are fixed and covered by a test, so this cannot fail at runtime.
        try! P256.Signing.PublicKey(pemRepresentation: productionPublicKeyPEM)
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The signed LNM1 payload. Field names are the protocol's short keys.
public struct LicencePayload: Codable, Hashable, Sendable {
    /// `v`: protocol version, always 1.
    public var version: Int
    /// `p`
    public var product: String
    /// `id`, e.g. `MF-2026-0001`
    public var licenceID: String
    /// `c`: customer (clinic / workshop) name, shown in the customer's app.
    public var customer: String
    /// `m`: `XXXX-XXXX-XXXX-XXXX` or `*` (any machine).
    public var machine: String
    /// `i`: issue date `YYYY-MM-DD`.
    public var issued: String
    /// `e`: last valid day `YYYY-MM-DD`, or nil for perpetual.
    public var expires: String?
    /// `ed`: edition label, display only.
    public var edition: String
    /// `f`: enabled feature keys; `["*"]` means everything.
    public var features: [String]

    public init(version: Int = 1, product: String, licenceID: String, customer: String, machine: String,
                issued: String, expires: String?, edition: String = "standard", features: [String] = ["*"]) {
        self.version = version
        self.product = product
        self.licenceID = licenceID
        self.customer = customer
        self.machine = machine
        self.issued = issued
        self.expires = expires
        self.edition = edition
        self.features = features
    }

    enum CodingKeys: String, CodingKey {
        case version = "v", product = "p", licenceID = "id", customer = "c", machine = "m"
        case issued = "i", expires = "e", edition = "ed", features = "f"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        product = try c.decode(String.self, forKey: .product)
        licenceID = try c.decode(String.self, forKey: .licenceID)
        customer = try c.decode(String.self, forKey: .customer)
        machine = try c.decode(String.self, forKey: .machine)
        issued = try c.decode(String.self, forKey: .issued)
        expires = try c.decodeIfPresent(String.self, forKey: .expires)
        edition = try c.decode(String.self, forKey: .edition)
        features = try c.decode([String].self, forKey: .features)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(product, forKey: .product)
        try c.encode(licenceID, forKey: .licenceID)
        try c.encode(customer, forKey: .customer)
        try c.encode(machine, forKey: .machine)
        try c.encode(issued, forKey: .issued)
        try c.encode(expires, forKey: .expires)  // explicit null, as in the protocol
        try c.encode(edition, forKey: .edition)
        try c.encode(features, forKey: .features)
    }

    /// The exact bytes that are signed: compact JSON, keys sorted, UTF-8, non-ASCII kept.
    /// Byte-identical to Python's `json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)`.
    public var canonicalJSON: Data {
        CanonicalJSON.encode(.object([
            "v": .int(version),
            "p": .string(product),
            "id": .string(licenceID),
            "c": .string(customer),
            "m": .string(machine),
            "i": .string(issued),
            "e": expires.map(CanonicalJSON.Value.string) ?? .null,
            "ed": .string(edition),
            "f": .array(features.map(CanonicalJSON.Value.string)),
        ]))
    }
}

/// A tiny JSON writer whose output matches Python's `json.dumps(..., ensure_ascii=False,
/// separators=(",", ":"), sort_keys=True)` byte for byte. Foundation's encoders differ (they escape
/// "/" and don't promise key order), so the signed bytes are written here.
public enum CanonicalJSON {
    public indirect enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case string(String)
        case array([Value])
        case object([String: Value])
    }

    public static func encode(_ value: Value) -> Data {
        var out = ""
        write(value, into: &out)
        return Data(out.utf8)
    }

    private static func write(_ value: Value, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            // Python sorts str keys by code point.
            let keys = members.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
            for (n, key) in keys.enumerated() {
                if n > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(members[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// Python's escaping with ensure_ascii=False: `"` `\` and control characters only.
    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// base64url without padding, as used by LNM1.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem == 1 { return nil }
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }
}

/// Machine codes: `first 16 chars of Crockford-base32(SHA-256("<product>|<platform id>"))`, as 4-4-4-4.
public enum MachineCode {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// The "any machine" value.
    public static let anyMachine = "*"

    /// Computes the code an app shows for a platform id (used by tests against the protocol's vectors).
    public static func compute(product: LicenceProduct, platformID: String) -> String {
        let digest = Array(SHA256.hash(data: Data("\(product.rawValue)|\(platformID)".utf8)))
        var chars: [Character] = []
        var buffer = 0, bits = 0, index = 0
        while chars.count < 16 {
            if bits < 5 {
                buffer = (buffer << 8) | Int(digest[index]); index += 1; bits += 8
            }
            bits -= 5
            chars.append(alphabet[(buffer >> bits) & 31])
        }
        return group(String(chars))
    }

    public enum Check: Equatable, Sendable {
        /// A complete, normalised code (`XXXX-XXXX-XXXX-XXXX`) or `*`.
        case valid(String)
        /// Nothing typed yet.
        case empty
        /// Only allowed characters so far, but not 16 of them.
        case incomplete(count: Int)
        /// A character that can never appear in a machine code.
        case invalidCharacter(Character)
        /// More than 16 characters.
        case tooLong(count: Int)

        public var normalized: String? {
            if case .valid(let code) = self { code } else { nil }
        }
    }

    /// Normalises what the owner typed (as `norm_machine` in the Python tool): upper case, spaces
    /// and dashes ignored, O→0, I/L→1. Persian and Arabic-Indic digits are read as 0–9, because the
    /// code is often typed on a Dari keyboard; the result is always the ASCII form.
    public static func check(_ input: String) -> Check {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed == anyMachine { return .valid(anyMachine) }
        var out: [Character] = []
        for ch in trimmed.uppercased() {
            if ch == "-" || ch == " " || ch == "\u{2010}" || ch == "\u{2011}" || ch == "\u{2013}" || ch.isWhitespace { continue }
            var c = ch
            if let ascii = asciiDigit(c) { c = ascii }
            switch c {
            case "O": c = "0"
            case "I", "L": c = "1"
            default: break
            }
            guard alphabet.contains(c) else { return .invalidCharacter(ch) }
            out.append(c)
        }
        if out.count < 16 { return out.isEmpty ? .empty : .incomplete(count: out.count) }
        if out.count > 16 { return .tooLong(count: out.count) }
        return .valid(group(String(out)))
    }

    public static func normalize(_ input: String) -> String? { check(input).normalized }

    private static func group(_ s: String) -> String {
        let a = Array(s)
        return stride(from: 0, to: a.count, by: 4).map { String(a[$0..<min($0 + 4, a.count)]) }.joined(separator: "-")
    }

    private static func asciiDigit(_ c: Character) -> Character? {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return nil }
        switch scalar.value {
        case 0x06F0...0x06F9: return Character(String(scalar.value - 0x06F0))  // Extended Arabic-Indic (Persian)
        case 0x0660...0x0669: return Character(String(scalar.value - 0x0660))  // Arabic-Indic
        default: return nil
        }
    }
}

/// Why a licence key was rejected. Mirrors the protocol's list.
public enum LicenceKeyError: Error, LocalizedError, Equatable, Sendable {
    case wrongPrefix
    case badBase64
    case badSignature
    case badJSON
    case wrongVersion(Int)
    case wrongProduct(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPrefix: L("This is not an LNM1 licence key.")
        case .badBase64: L("The licence key is damaged (it isn't valid base64url).")
        case .badSignature: L("The signature doesn't match. The key was changed, or signed with a different key.")
        case .badJSON: L("The licence contents can't be read.")
        case .wrongVersion(let v): LF("Unsupported licence version %ld.", v)
        case .wrongProduct(let p): LF("This licence is for another product (%@).", p)
        }
    }
}

/// Signs and verifies LNM1 keys with CryptoKit.
public enum LicenceKey {
    public static let prefix = "LNM1"

    /// Signs the payload's canonical JSON. ECDSA signatures are randomised, so two calls give
    /// different (equally valid) keys.
    public static func sign(_ payload: LicencePayload, with key: P256.Signing.PrivateKey) throws -> String {
        let body = payload.canonicalJSON
        let signature = try key.signature(for: body)
        return "\(prefix).\(Base64URL.encode(body)).\(Base64URL.encode(signature.derRepresentation))"
    }

    /// Verifies a key (whitespace anywhere is ignored) for a product with its public key.
    public static func verify(_ text: String, product: LicenceProduct, publicKey: P256.Signing.PublicKey) throws -> LicencePayload {
        let compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix else { throw LicenceKeyError.wrongPrefix }
        guard let body = Base64URL.decode(String(parts[1])), let sig = Base64URL.decode(String(parts[2])) else {
            throw LicenceKeyError.badBase64
        }
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: sig),
              publicKey.isValidSignature(signature, for: body) else { throw LicenceKeyError.badSignature }
        guard let payload = try? JSONDecoder().decode(LicencePayload.self, from: body) else { throw LicenceKeyError.badJSON }
        guard payload.version == 1 else { throw LicenceKeyError.wrongVersion(payload.version) }
        guard payload.product == product.rawValue else { throw LicenceKeyError.wrongProduct(payload.product) }
        return payload
    }

    /// Verifies with the embedded production public key.
    public static func verify(_ text: String, product: LicenceProduct) throws -> LicencePayload {
        try verify(text, product: product, publicKey: product.productionPublicKey)
    }

    /// Reads the payload without checking the signature (for display of an unverifiable key only).
    public static func unverifiedPayload(_ text: String) -> LicencePayload? {
        let compact = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let body = Base64URL.decode(String(parts[1])) else { return nil }
        return try? JSONDecoder().decode(LicencePayload.self, from: body)
    }
}

/// Public-key fingerprints, so the owner can compare a key with the one built into the apps.
public enum KeyFingerprint {
    /// SHA-256 of the DER SubjectPublicKeyInfo, lower-case hex (64 characters). The same value as
    /// `openssl pkey -pubin -in <product>-public.pem -outform DER | shasum -a 256`.
    public static func sha256Hex(_ key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.derRepresentation).map { String(format: "%02x", $0) }.joined()
    }

    /// The first 16 hex characters in groups of four, for display.
    public static func short(_ key: P256.Signing.PublicKey) -> String {
        let hex = Array(sha256Hex(key).prefix(16))
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<$0 + 4]) }.joined(separator: " ")
    }
}
