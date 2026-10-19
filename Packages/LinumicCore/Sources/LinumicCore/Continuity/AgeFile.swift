import CryptoKit
import Foundation

/// The age file format, v1 (https://age-encryption.org/v1), with a passphrase (the scrypt recipient), so an export
/// opens with the standard `age` tool and needs nothing from Linumic OS: `age -d -o export.json file.json.age`.
///
/// - A random 16-byte file key is wrapped with ChaCha20-Poly1305 under scrypt(passphrase, "age-encryption.org/v1/scrypt"
///   ‖ 16-byte salt, N = 2^workFactor, r = 8, p = 1), zero nonce: the one stanza `-> scrypt <salt> <workFactor>`.
/// - The header ends with `---` and an HMAC-SHA256 under HKDF-SHA256(file key, no salt, "header").
/// - The payload is a 16-byte nonce, then the content in 64 KiB chunks, each sealed with ChaCha20-Poly1305 under
///   HKDF-SHA256(file key, nonce, "payload"), nonce = 11-byte big-endian counter ‖ 0x01 on the last chunk, else 0x00.
///
/// Only the scrypt recipient is written or read; it must be the file's only stanza, as the format requires. The header
/// grammar and STREAM are checked against the format's own test vectors (C2SP/CCTV, `Tests/…/Fixtures/age`).
public enum AgeFile {
    public static let headerLine = "age-encryption.org/v1"
    /// age's own default for passphrases (about a second on this Mac, 256 MiB of memory).
    public static let defaultWorkFactor = 18
    /// The most `decrypt` accepts, as age itself does by default, so a file can't make it run for hours.
    public static let maxWorkFactor = 22
    static let chunkSize = 64 * 1024
    static let scryptLabel = Array("age-encryption.org/v1/scrypt".utf8)

    public enum Failure: LocalizedError, Equatable {
        case notAge
        case malformedHeader(String)
        case notPassphrase
        case workFactorTooHigh(Int)
        case wrongPassphrase
        case headerMACMismatch
        case truncated
        case damaged

        public var errorDescription: String? {
            switch self {
            case .notAge: L("It is not an age file.")
            case .malformedHeader(let why): LF("Its age header is malformed (%@).", why)
            case .notPassphrase: L("It is not encrypted with a passphrase.")
            case .workFactorTooHigh(let n): LF("Its work factor (%d) is higher than allowed.", n)
            case .wrongPassphrase: L("The passphrase does not open it.")
            case .headerMACMismatch: L("Its header has been changed or damaged.")
            case .truncated: L("It ends too early; part of the file is missing.")
            case .damaged: L("Its contents have been changed or damaged.")
            }
        }
    }

    // MARK: Encrypt

    public static func encrypt(_ plaintext: Data, passphrase: String, workFactor: Int = defaultWorkFactor) throws -> Data {
        var rng = SystemRandomNumberGenerator()
        let fileKey = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let nonce = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return try encrypt(plaintext, passphrase: passphrase, workFactor: workFactor, fileKey: fileKey, salt: salt, nonce: nonce)
    }

    /// With the random parts given (tests only).
    static func encrypt(_ plaintext: Data, passphrase: String, workFactor: Int, fileKey: [UInt8], salt: [UInt8], nonce: [UInt8]) throws -> Data {
        let wrapKey = try Scrypt.derive(password: Array(passphrase.utf8), salt: scryptLabel + salt, logN: workFactor, r: 8, p: 1, length: 32)
        let wrapped = try ChaChaPoly.seal(Data(fileKey), using: SymmetricKey(data: wrapKey), nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        let body = wrapped.ciphertext + wrapped.tag
        var header = "\(headerLine)\n-> scrypt \(b64(salt)) \(workFactor)\n"
        header += wrapLines(b64(Array(body)))
        header += "---"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(header.utf8), using: hkdf(fileKey, salt: [], info: "header"))
        var out = Data((header + " " + b64(Array(mac)) + "\n").utf8)
        out.append(contentsOf: nonce)
        out.append(try seal(plaintext, key: hkdf(fileKey, salt: nonce, info: "payload")))
        return out
    }

    // MARK: Decrypt

    /// Opens a passphrase-encrypted age file. The scrypt stanza must be the file's only stanza, as the format requires.
    public static func decrypt(_ file: Data, passphrase: String, maxWorkFactor: Int = maxWorkFactor) throws -> Data {
        let header = try Header.parse([UInt8](file))
        guard header.stanzas.contains(where: { $0.args.first == "scrypt" }) else { throw Failure.notPassphrase }
        guard header.stanzas.count == 1, let stanza = header.stanzas.first else {
            throw Failure.malformedHeader("scrypt must be the only stanza")
        }
        guard stanza.args.count == 3, let salt = unb64(stanza.args[1]), salt.count == 16 else {
            throw Failure.malformedHeader("scrypt arguments")
        }
        let factor = stanza.args[2]
        guard !factor.isEmpty, factor.utf8.allSatisfy({ (0x30...0x39).contains($0) }), !factor.hasPrefix("0"),
              let workFactor = Int(factor), workFactor > 0 else { throw Failure.malformedHeader("work factor") }
        guard workFactor <= maxWorkFactor else { throw Failure.workFactorTooHigh(workFactor) }
        guard stanza.body.count == 32 else { throw Failure.malformedHeader("scrypt body") }

        let wrapKey = try Scrypt.derive(password: Array(passphrase.utf8), salt: scryptLabel + salt, logN: workFactor, r: 8, p: 1, length: 32)
        let fileKey: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)), ciphertext: Data(stanza.body.prefix(16)),
                                               tag: Data(stanza.body.suffix(16)))
            fileKey = try ChaChaPoly.open(box, using: SymmetricKey(data: wrapKey))
        } catch {
            throw Failure.wrongPassphrase
        }
        return try open(file, header: header, fileKey: Array(fileKey))
    }

    /// Opens any age file whose file key is already known (the format's test vectors give it): the header MAC, then the
    /// payload. For tests of the header grammar and STREAM against other implementations' vectors.
    static func decrypt(_ file: Data, fileKey: [UInt8]) throws -> Data {
        try open(file, header: Header.parse([UInt8](file)), fileKey: fileKey)
    }

    private static func open(_ file: Data, header: Header, fileKey: [UInt8]) throws -> Data {
        guard HMAC<SHA256>.isValidAuthenticationCode(header.mac, authenticating: header.macInput,
                                                     using: hkdf(fileKey, salt: [], info: "header")) else {
            throw Failure.headerMACMismatch
        }
        let bytes = [UInt8](file)
        // A missing or short nonce is a broken header, as the format's test vectors class it.
        guard bytes.count >= header.payloadStart + 16 else { throw Failure.malformedHeader("no payload nonce") }
        let nonce = Array(bytes[header.payloadStart..<(header.payloadStart + 16)])
        return try open(Data(bytes[(header.payloadStart + 16)...]), key: hkdf(fileKey, salt: nonce, info: "payload"))
    }

    /// The header, parsed strictly: the version line, one or more stanzas (`-> type args…`, then a body in canonical
    /// unpadded base64 of full 64-column lines and one shorter final line, possibly empty), then `--- <MAC>`. Lines end
    /// in LF only; arguments are non-empty runs of visible ASCII.
    struct Header {
        struct Stanza {
            var args: [String]
            var body: [UInt8]
        }

        var stanzas: [Stanza]
        var mac: [UInt8]
        /// The header bytes the MAC covers: everything up to and including "---".
        var macInput: Data
        var payloadStart: Int

        static func parse(_ bytes: [UInt8]) throws -> Header {
            var at = 0
            func nextLine() throws -> ArraySlice<UInt8> {
                guard at < bytes.count, let end = bytes[at...].firstIndex(of: 0x0A) else {
                    throw at == 0 ? Failure.notAge : Failure.malformedHeader("ends early")
                }
                let line = bytes[at..<end]
                at = end + 1
                return line
            }
            let first = try nextLine()
            guard Array(first) == Array(headerLine.utf8) else {
                if first.starts(with: Array("age-encryption.org/".utf8)) { throw Failure.malformedHeader("unsupported version") }
                throw Failure.notAge
            }
            var stanzas: [Stanza] = []
            var lineStart = at
            var line = try nextLine()
            while line.starts(with: Array("-> ".utf8)) {
                let args = line.dropFirst(3).split(separator: 0x20, omittingEmptySubsequences: false)
                guard !args.isEmpty, args.allSatisfy({ !$0.isEmpty && $0.allSatisfy { (0x21...0x7E).contains($0) } }) else {
                    throw Failure.malformedHeader("stanza arguments")
                }
                var body: [UInt8] = []
                while true {
                    let bodyLine = try nextLine()
                    guard bodyLine.count <= 64, let text = String(bytes: bodyLine, encoding: .ascii), let decoded = unb64(text) else {
                        throw Failure.malformedHeader("stanza body")
                    }
                    body += decoded
                    if bodyLine.count < 64 { break }
                }
                stanzas.append(Stanza(args: args.map { String(decoding: $0, as: UTF8.self) }, body: body))
                lineStart = at
                line = try nextLine()
            }
            guard !stanzas.isEmpty else { throw Failure.malformedHeader("no stanza") }
            // "--- " and the MAC, nothing else on the line.
            guard line.starts(with: Array("--- ".utf8)), let text = String(bytes: line.dropFirst(4), encoding: .ascii),
                  let mac = unb64(text), mac.count == 32 else { throw Failure.malformedHeader("MAC line") }
            return Header(stanzas: stanzas, mac: mac, macInput: Data(bytes[..<(lineStart + 3)]), payloadStart: at)
        }
    }

    // MARK: STREAM

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        var counter: UInt64 = 0
        var start = plaintext.startIndex
        repeat {
            let end = plaintext.index(start, offsetBy: min(chunkSize, plaintext.endIndex - start))
            let last = end == plaintext.endIndex
            let box = try ChaChaPoly.seal(plaintext[start..<end], using: key, nonce: try streamNonce(counter, last: last))
            out.append(box.ciphertext)
            out.append(box.tag)
            counter += 1
            start = end
        } while start < plaintext.endIndex
        return out
    }

    static func open(_ payload: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        var counter: UInt64 = 0
        var start = payload.startIndex
        let sealedSize = chunkSize + 16
        guard payload.count >= 16 else { throw Failure.truncated }
        while start < payload.endIndex {
            let remaining = payload.endIndex - start
            let last = remaining <= sealedSize
            let end = start + min(sealedSize, remaining)
            let chunk = payload[start..<end]
            guard chunk.count >= 16 else { throw Failure.truncated }
            do {
                let box = try ChaChaPoly.SealedBox(nonce: try streamNonce(counter, last: last), ciphertext: chunk.dropLast(16),
                                                   tag: chunk.suffix(16))
                let plain = try ChaChaPoly.open(box, using: key)
                // Only the whole content may be empty, and only a final chunk may be short.
                if plain.isEmpty, counter > 0 { throw Failure.damaged }
                out.append(plain)
            } catch let f as Failure {
                throw f
            } catch {
                // A full-size chunk that fails as "not last" may be a file cut at a chunk boundary.
                throw last ? Failure.damaged : Failure.truncated
            }
            counter += 1
            start = end
        }
        return out
    }

    static func streamNonce(_ counter: UInt64, last: Bool) throws -> ChaChaPoly.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        for k in 0..<8 { n[10 - k] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(k))) }
        n[11] = last ? 1 : 0
        return try ChaChaPoly.Nonce(data: n)
    }

    // MARK: Helpers

    static func hkdf(_ ikm: [UInt8], salt: [UInt8], info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    /// Standard base64 without padding, as age writes it.
    static func b64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Strict: no padding, no line breaks, no other alphabet, and canonical (it encodes back to the same text).
    static func unb64(_ text: String) -> [UInt8]? {
        if text.isEmpty { return [] }
        guard text.utf8.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F }),
              text.utf8.count % 4 != 1 else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), b64(Array(data)) == text else { return nil }
        return Array(data)
    }

    /// Lines of 64 columns; the last one shorter (empty when the text fills whole lines), each ending in "\n".
    static func wrapLines(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while rest.count >= 64 {
            out += rest.prefix(64) + "\n"
            rest = rest.dropFirst(64)
        }
        return out + rest + "\n"
    }
}
