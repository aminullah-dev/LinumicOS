import CryptoKit
import Foundation
import Testing
@testable import LinumicCore

// The continuity export must open with the standard `age` tool. So the format is checked against age's own test
// vectors (C2SP/CCTV, Fixtures/age), and our encryption, given the same random parts, must write the vector byte for byte.

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func ageTestSHA(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// One CCTV vector: its textual header and the age file after the blank line (zlib-inflated when marked so).
private struct Vector {
    var name: String
    var fields: [String: [String]]
    var file: Data

    var expect: String { fields["expect"]?.first ?? "" }
    var payloadSHA: String? { fields["payload"]?.first }
    var fileKey: [UInt8]? { fields["file key"]?.first.map(hex) }
    var passphrase: String? { fields["passphrase"]?.first }

    static func all() throws -> [Vector] {
        let dir = try #require(Bundle.module.url(forResource: "age", withExtension: nil, subdirectory: "Fixtures"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).filter { !$0.hasSuffix(".md") }.sorted()
        return try names.map { name in
            let bytes = try Data(contentsOf: dir.appending(path: name))
            let split = try #require(bytes.range(of: Data("\n\n".utf8)))
            var fields: [String: [String]] = [:]
            for line in String(decoding: bytes[..<split.lowerBound], as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { fields[parts[0], default: []].append(parts[1]) }
            }
            var file = Data(bytes[split.upperBound...])
            if fields["compressed"]?.first == "zlib" {
                // zlib = a 2-byte header, raw DEFLATE, a 4-byte checksum; Foundation inflates the raw part.
                file = try (Data(file.dropFirst(2).dropLast(4)) as NSData).decompressed(using: .zlib) as Data
            }
            return Vector(name: name, fields: fields, file: file)
        }
    }
}

/// The outcome classes the vectors use.
private func outcome(_ body: () throws -> Data) -> (String, Data?) {
    do {
        return ("success", try body())
    } catch let f as AgeFile.Failure {
        switch f {
        case .notAge, .malformedHeader, .workFactorTooHigh: return ("header failure", nil)
        case .notPassphrase, .wrongPassphrase: return ("no match", nil)
        case .headerMACMismatch: return ("HMAC failure", nil)
        case .truncated, .damaged: return ("payload failure", nil)
        }
    } catch {
        return ("other: \(error)", nil)
    }
}

@Suite("Continuity: scrypt and the age format")
struct AgeFormatTests {
    @Test func scryptMatchesRFC7914() throws {
        let one = try Scrypt.derive(password: [], salt: [], logN: 4, r: 1, p: 1, length: 64)
        #expect(one == hex("77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"))
        let two = try Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), logN: 10, r: 8, p: 16, length: 64)
        #expect(two == hex("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"))
        #expect(throws: Scrypt.Failure.parameters) { try Scrypt.derive(password: [], salt: [], logN: 0, r: 1, p: 1, length: 64) }
    }

    @Test func everyApplicableVectorOfTheAgeTestSuite() throws {
        let vectors = try Vector.all()
        #expect(vectors.count >= 70)
        var checked = 0
        for v in vectors {
            let result: (String, Data?)
            if let passphrase = v.passphrase {
                result = outcome { try AgeFile.decrypt(v.file, passphrase: passphrase) }
            } else if let key = v.fileKey {
                // X25519 files: the stanza is not ours to open, but the header grammar, the MAC and STREAM are.
                result = outcome { try AgeFile.decrypt(v.file, fileKey: key) }
            } else {
                result = outcome { try AgeFile.decrypt(v.file, passphrase: "") }
            }
            #expect(result.0 == v.expect, "\(v.name): \(result.0), expected \(v.expect)")
            if v.expect == "success", let data = result.1 {
                #expect(ageTestSHA(data) == v.payloadSHA, "\(v.name): payload")
            }
            checked += 1
        }
        #expect(checked == vectors.count)
    }

    @Test func ourEncryptionWritesTheVectorByteForByte() throws {
        let v = try #require(try Vector.all().first { $0.name == "scrypt" })
        let plain = try AgeFile.decrypt(v.file, passphrase: "password")
        // The random parts, read back from the vector: salt from the stanza, nonce after the header.
        let header = try AgeFile.Header.parse([UInt8](v.file))
        let salt = try #require(AgeFile.unb64(header.stanzas[0].args[1]))
        let nonce = Array(v.file[header.payloadStart..<(header.payloadStart + 16)])
        let ours = try AgeFile.encrypt(plain, passphrase: "password", workFactor: 10, fileKey: try #require(v.fileKey), salt: salt, nonce: nonce)
        #expect(ours == v.file)
    }

    @Test func roundTripsAndRefusals() throws {
        for size in [0, 1, 65_535, 65_536, 65_537, 200_000] {
            let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let sealed = try AgeFile.encrypt(plain, passphrase: "correct horse battery staple", workFactor: 10)
            #expect(try AgeFile.decrypt(sealed, passphrase: "correct horse battery staple") == plain, "size \(size)")
        }
        let sealed = try AgeFile.encrypt(Data("records".utf8), passphrase: "correct horse battery staple", workFactor: 10)
        #expect(throws: AgeFile.Failure.wrongPassphrase) { try AgeFile.decrypt(sealed, passphrase: "wrong horse battery staple") }
        var flipped = sealed
        flipped[flipped.count - 3] ^= 1
        #expect(throws: AgeFile.Failure.damaged) { try AgeFile.decrypt(flipped, passphrase: "correct horse battery staple") }
        #expect(throws: AgeFile.Failure.self) { try AgeFile.decrypt(sealed.prefix(sealed.count - 20), passphrase: "correct horse battery staple") }
        let high = try AgeFile.encrypt(Data("x".utf8), passphrase: "p", workFactor: 10)
        #expect(throws: AgeFile.Failure.workFactorTooHigh(10)) { try AgeFile.decrypt(high, passphrase: "p", maxWorkFactor: 9) }
        #expect(throws: AgeFile.Failure.notAge) { try AgeFile.decrypt(Data("{\"json\": true}\n".utf8), passphrase: "p") }
        // The header names the work factor in plain text, as age writes it.
        #expect(String(decoding: sealed.prefix(60), as: UTF8.self).hasPrefix("age-encryption.org/v1\n-> scrypt "))
    }
}

