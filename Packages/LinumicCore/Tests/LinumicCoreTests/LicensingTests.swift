import CryptoKit
import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only. The key pair in licensing-test-vectors.json is a throwaway TEST key from
// licensing/test-vectors.json; it never signs real licences and is not the production key.

private struct Vectors: Decodable {
    struct Machine: Decodable { let product: String; let platform_id: String; let code: String }
    struct Key: Decodable { let `case`: String; let product: String; let machine: String?; let key: String }
    let test_public_key_pem: String
    let test_private_key_pem: String
    let machine_codes: [Machine]
    let keys: [Key]

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "licensing-test-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    var publicKey: P256.Signing.PublicKey { get throws { try P256.Signing.PublicKey(pemRepresentation: test_public_key_pem) } }
    var privateKey: P256.Signing.PrivateKey { get throws { try P256.Signing.PrivateKey(pemRepresentation: test_private_key_pem) } }
}

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ s: String) -> Date { LicenceDate.date(from: s, calendar: utc)!.addingTimeInterval(12 * 3600) }

private func record(_ id: String, product: LicenceProduct = .mediflow, status: LicenceStatus = .active, expires: String? = nil,
                    machine: String = "4HDG-0NK5-EAKX-GQVR", key: String? = nil, notes: String = "",
                    updated: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> LicenceRecord {
    LicenceRecord(id: UUID(), product: product, licenceID: id, customer: "SAMPLE Clinic", machine: machine, issued: "2026-10-08",
                  expires: expires, keyText: key, status: status, notes: notes, createdBy: "test",
                  createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: updated)
}

@Suite("LNM1 protocol")
struct LicenceProtocolTests {
    @Test func everyTestVectorVerifiesOrRejectsAsLabelled() throws {
        let v = try Vectors.load()
        let pub = try v.publicKey
        #expect(v.keys.count == 14)
        for k in v.keys {
            let product = try #require(LicenceProduct(rawValue: k.product))
            let other: LicenceProduct = product == .mediflow ? .khayatyar : .mediflow
            switch k.case {
            case "valid_perpetual", "valid_expires_2026_12_31", "valid_any_machine", "with_whitespace_valid":
                let payload = try LicenceKey.verify(k.key, product: product, publicKey: pub)
                #expect(payload.product == product.rawValue)
                #expect(payload.customer == "کلینیک آزمایشی / Test")
                if let machine = k.machine { #expect(payload.machine == machine) }
                #expect(payload.expires == (k.case == "valid_expires_2026_12_31" ? "2026-12-31" : nil))
                #expect(payload.features == ["*"])
            case "wrong_product":
                #expect(throws: LicenceKeyError.wrongProduct(other.rawValue)) { try LicenceKey.verify(k.key, product: product, publicKey: pub) }
            case "tampered_payload":
                #expect(throws: LicenceKeyError.badSignature) { try LicenceKey.verify(k.key, product: product, publicKey: pub) }
            case "wrong_version":
                #expect(throws: LicenceKeyError.wrongVersion(2)) { try LicenceKey.verify(k.key, product: product, publicKey: pub) }
            default:
                Issue.record("Unlabelled vector \(k.case)")
            }
        }
    }

    @Test func vectorsSignedWithTheTestKeyFailAgainstTheProductionKey() throws {
        let v = try Vectors.load()
        for k in v.keys where k.case == "valid_perpetual" {
            let product = try #require(LicenceProduct(rawValue: k.product))
            #expect(throws: LicenceKeyError.badSignature) { try LicenceKey.verify(k.key, product: product) }
        }
    }

    @Test func malformedKeysAreRejected() throws {
        let pub = try Vectors.load().publicKey
        #expect(throws: LicenceKeyError.wrongPrefix) { try LicenceKey.verify("LNM2.abc.def", product: .mediflow, publicKey: pub) }
        #expect(throws: LicenceKeyError.wrongPrefix) { try LicenceKey.verify("LNM1.abc", product: .mediflow, publicKey: pub) }
        #expect(throws: LicenceKeyError.badBase64) { try LicenceKey.verify("LNM1.a+b.c/d", product: .mediflow, publicKey: pub) }
        #expect(throws: LicenceKeyError.badSignature) { try LicenceKey.verify("LNM1.e30.MEUCIQ", product: .mediflow, publicKey: pub) }
    }

    @Test func machineCodesMatchTheProtocolVectors() throws {
        for m in try Vectors.load().machine_codes {
            let product = try #require(LicenceProduct(rawValue: m.product))
            #expect(MachineCode.compute(product: product, platformID: m.platform_id) == m.code)
        }
    }

    @Test func machineCodeNormalisation() {
        #expect(MachineCode.normalize("k7q2 9xmb 4t1d wp3c") == "K7Q2-9XMB-4T1D-WP3C")
        #expect(MachineCode.normalize("K7Q2-9XMB-4T1D-WP3C") == "K7Q2-9XMB-4T1D-WP3C")
        // O → 0, I and L → 1, as the Python tool.
        #expect(MachineCode.normalize("OOOO-IIII-LLLL-0000") == "0000-1111-1111-0000")
        // Persian digits typed on a Dari keyboard.
        #expect(MachineCode.normalize("۴HDG-۰NK۵-EAKX-GQVR") == "4HDG-0NK5-EAKX-GQVR")
        #expect(MachineCode.check(" * ") == .valid("*"))
        #expect(MachineCode.check("") == .empty)
        #expect(MachineCode.check("K7Q2-9X") == .incomplete(count: 6))
        #expect(MachineCode.check("K7Q2-9XMB-4T1D-WP3U") == .invalidCharacter("U"))
        #expect(MachineCode.check("K7Q2-9XMB-4T1D-WP3C-A") == .tooLong(count: 17))
        #expect(MachineCode.normalize("**") == nil)
    }

    @Test func canonicalJSONIsByteIdenticalToPythonForAPersianName() throws {
        // Python: json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
        let pythonBytes = try #require(Data(base64Encoded: "eyJjIjoi2qnZhNuM2YbbjNqpINi02YHYpyAvIFNoaWZhIFwiQVwiXHTYqtiz2KoiLCJlIjpudWxsLCJlZCI6InN0YW5kYXJkIiwiZiI6WyIqIl0sImkiOiIyMDI2LTEwLTA4IiwiaWQiOiJNRi0yMDI2LTAwMDciLCJtIjoiSzdRMi05WE1CLTRUMUQtV1AzQyIsInAiOiJtZWRpZmxvdyIsInYiOjF9"))
        let payload = LicencePayload(product: "mediflow", licenceID: "MF-2026-0007", customer: "کلینیک شفا / Shifa \"A\"\tتست",
                                     machine: "K7Q2-9XMB-4T1D-WP3C", issued: "2026-10-08", expires: nil)
        #expect(payload.canonicalJSON == pythonBytes)
    }

    @Test func reEncodingEveryPythonPayloadGivesTheSameBytes() throws {
        for k in try Vectors.load().keys {
            let compact = String(k.key.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            let body = try #require(Base64URL.decode(String(compact.split(separator: ".")[1])))
            let payload = try JSONDecoder().decode(LicencePayload.self, from: body)
            #expect(payload.canonicalJSON == body, "\(k.product) \(k.case)")
        }
    }

    @Test func controlCharactersAreEscapedLikePython() {
        // json.dumps("\u0001\b\f\n\r\t\\\u007f/", ensure_ascii=False) == '"\\u0001\\b\\f\\n\\r\\t\\\\\x7f/"'
        let out = String(decoding: CanonicalJSON.encode(.string("\u{01}\u{08}\u{0C}\n\r\t\\\u{7F}/")), as: UTF8.self)
        #expect(out == "\"\\u0001\\b\\f\\n\\r\\t\\\\\u{7F}/\"")
    }

    @Test func signsWithTheTestKeyAndVerifies() throws {
        let v = try Vectors.load()
        let payload = LicencePayload(product: "khayatyar", licenceID: "KY-2026-0042", customer: "خیاطی امید، کابل",
                                     machine: "BDZ2-PWKS-XGAW-3YGB", issued: "2026-10-08", expires: "2027-10-07")
        let key = try LicenceKey.sign(payload, with: try v.privateKey)
        #expect(key.hasPrefix("LNM1."))
        #expect(!key.contains("="))
        #expect(try LicenceKey.verify(key, product: .khayatyar, publicKey: try v.publicKey) == payload)
        #expect(throws: LicenceKeyError.wrongProduct("khayatyar")) { try LicenceKey.verify(key, product: .mediflow, publicKey: try v.publicKey) }
        // DER, not raw r||s.
        let sig = try #require(Base64URL.decode(String(key.split(separator: ".")[2])))
        #expect(sig.first == 0x30)
    }

    /// Dev check, not part of CI: with LNM1_PYTHON_CHECK_OUT set, writes Swift-signed keys and their
    /// canonical bytes for `tools/licensing/python_crosscheck.sh` to verify with Python `cryptography`.
    @Test func writesKeysForThePythonCrossCheck() throws {
        guard let path = ProcessInfo.processInfo.environment["LNM1_PYTHON_CHECK_OUT"] else { return }
        let v = try Vectors.load()
        let samples = [
            LicencePayload(product: "mediflow", licenceID: "MF-2026-0001", customer: "کلینیک شفا / Shifa \"A\"",
                           machine: "4HDG-0NK5-EAKX-GQVR", issued: "2026-10-08", expires: nil),
            LicencePayload(product: "khayatyar", licenceID: "KY-2026-0001", customer: "خیاطی امید، کابل",
                           machine: "*", issued: "2026-10-08", expires: "2027-10-07", edition: "standard", features: ["*"]),
        ]
        let out = try samples.map { p -> [String: Any] in
            ["product": p.product, "key": try LicenceKey.sign(p, with: try v.privateKey),
             "canonical_b64": p.canonicalJSON.base64EncodedString(),
             "payload": ["v": 1, "p": p.product, "id": p.licenceID, "c": p.customer, "m": p.machine, "i": p.issued,
                         "e": p.expires as Any? ?? NSNull(), "ed": p.edition, "f": p.features]]
        }
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: path))
    }

    @Test func productionPublicKeysAreTheOnesInLicensingPublic() {
        // sha256 of the DER SubjectPublicKeyInfo of licensing/public/<product>-public.pem, computed with Python on 2026-10-08.
        #expect(KeyFingerprint.sha256Hex(LicenceProduct.mediflow.productionPublicKey) == "6da03722ebc3ea2510ad416eca6f5126e10a0fb13c6e6d8e50d8d00a661536db")
        #expect(KeyFingerprint.sha256Hex(LicenceProduct.khayatyar.productionPublicKey) == "8ab62a12dee76fd20c88c6a482c990ae97a16fac6093ff5e7b03c239524c14b7")
        #expect(KeyFingerprint.short(LicenceProduct.mediflow.productionPublicKey) == "6da0 3722 ebc3 ea25")
    }
}

@Suite("Licence signing keys")
struct LicenceSigningKeyTests {
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        var values: [SecretKey: String] = [:]
        func read(_ key: SecretKey) throws -> String? { lock.withLock { values[key] } }
        func write(_ value: String, for key: SecretKey) throws { lock.withLock { values[key] = value } }
        func delete(_ key: SecretKey) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    }

    @Test func acceptsAKeyWhosePublicHalfMatches() throws {
        let v = try Vectors.load()
        let key = try LicenceSigningKeys.validate(pem: v.test_private_key_pem, for: .mediflow, expected: try v.publicKey)
        #expect(key.publicKey.derRepresentation == (try v.publicKey).derRepresentation)
    }

    @Test func refusesKeysThatDontMatchTheProductionKey() throws {
        let v = try Vectors.load()
        #expect(throws: SigningKeyError.mismatch(.mediflow)) { try LicenceSigningKeys.validate(pem: v.test_private_key_pem, for: .mediflow) }
        #expect(throws: SigningKeyError.publicKeyChosen) { try LicenceSigningKeys.validate(pem: v.test_public_key_pem, for: .khayatyar) }
        #expect(throws: SigningKeyError.unreadable) { try LicenceSigningKeys.validate(pem: "not a key", for: .khayatyar) }
        let secrets = MemorySecrets()
        let keys = LicenceSigningKeys(secrets: secrets)
        #expect(throws: SigningKeyError.mismatch(.khayatyar)) { try keys.importKey(pem: v.test_private_key_pem, for: .khayatyar) }
        #expect(secrets.values.isEmpty)
        #expect(!keys.hasKey(for: .khayatyar))
    }

    @Test func storesEachProductUnderItsOwnName() {
        #expect(LicenceSigningKeys.secretKey(for: .mediflow).rawValue == "licence.signing.mediflow")
        #expect(LicenceSigningKeys.secretKey(for: .khayatyar).rawValue == "licence.signing.khayatyar")
    }
}

@Suite("Licence ledger")
struct LicenceLedgerTests {
    @Test func nextIDFollowsThePythonTool() {
        #expect(LicenceLedger.nextID(for: .mediflow, year: 2026, in: []) == "MF-2026-0001")
        let ledger = [record("MF-2026-0003"), record("MF-2025-0009"), record("KY-2026-0010", product: .khayatyar), record("MF-TEST-0001")]
        #expect(LicenceLedger.nextID(for: .mediflow, year: 2026, in: ledger) == "MF-2026-0004")
        #expect(LicenceLedger.nextID(for: .khayatyar, year: 2026, in: ledger) == "KY-2026-0011")
        #expect(LicenceLedger.nextID(for: .khayatyar, year: 2027, in: ledger) == "KY-2027-0001")
    }

    @Test func issuesAVerifiedKey() throws {
        let v = try Vectors.load()
        let request = LicenceRequest(product: .mediflow, customer: "  کلینیک شفا  ", machine: "4hdg 0nk5 eakx gqvr", expires: "2027-10-07", notes: " paid ")
        let r = try LicenceLedger.issue(request, signingKey: try v.privateKey, publicKey: try v.publicKey,
                                        ledger: [record("MF-2026-0001")], createdBy: "Linumic OS", now: day("2026-10-08"), calendar: utc)
        #expect(r.licenceID == "MF-2026-0002")
        #expect(r.customer == "کلینیک شفا")
        #expect(r.machine == "4HDG-0NK5-EAKX-GQVR")
        #expect(r.issued == "2026-10-08")
        #expect(r.notes == "paid")
        #expect(r.status == .active)
        let payload = try LicenceKey.verify(try #require(r.keyText), product: .mediflow, publicKey: try v.publicKey)
        #expect(payload.licenceID == "MF-2026-0002")
        #expect(payload.expires == "2027-10-07")
    }

    @Test func neverHandsOutAKeyThatDoesntVerifyWithTheBuiltInKey() throws {
        let v = try Vectors.load()
        let request = LicenceRequest(product: .mediflow, customer: "SAMPLE", machine: "*", expires: nil)
        #expect(throws: LicenceLedgerError.self) {
            try LicenceLedger.issue(request, signingKey: try v.privateKey, ledger: [], createdBy: "t")  // production key expected
        }
    }

    @Test func validatesTheRequest() throws {
        let v = try Vectors.load()
        func issue(_ r: LicenceRequest) throws -> LicenceRecord {
            try LicenceLedger.issue(r, signingKey: try v.privateKey, publicKey: try v.publicKey, ledger: [], createdBy: "t", now: day("2026-10-08"), calendar: utc)
        }
        #expect(throws: LicenceLedgerError.customerMissing) { try issue(LicenceRequest(product: .mediflow, customer: " ", machine: "*", expires: nil)) }
        #expect(throws: LicenceLedgerError.machineInvalid) { try issue(LicenceRequest(product: .mediflow, customer: "A", machine: "K7Q2", expires: nil)) }
        #expect(throws: LicenceLedgerError.expiryInvalid) { try issue(LicenceRequest(product: .mediflow, customer: "A", machine: "*", expires: "2027-02-30")) }
        #expect(throws: LicenceLedgerError.expiryBeforeIssue) { try issue(LicenceRequest(product: .mediflow, customer: "A", machine: "*", expires: "2026-10-07")) }
    }

    @Test func renewalKeepsCustomerAndMachineAndSupersedesTheOldLicence() throws {
        let v = try Vectors.load()
        let old = record("MF-2026-0001", expires: "2026-11-01")
        let (renewed, superseded) = try LicenceLedger.renew(old, expires: "2027-11-01", signingKey: try v.privateKey, publicKey: try v.publicKey,
                                                            ledger: [old], createdBy: "Linumic OS", now: day("2026-10-20"), calendar: utc)
        #expect(renewed.licenceID == "MF-2026-0002")
        #expect(renewed.renewedFrom == "MF-2026-0001")
        #expect(renewed.customer == old.customer && renewed.machine == old.machine)
        #expect(renewed.expires == "2027-11-01")
        #expect(superseded.status == .superseded)
        #expect(superseded.licenceID == old.licenceID)
        // renewedFrom is ledger-only: it's not in the signed payload.
        let renewedKey = try #require(renewed.keyText)
        let body = try #require(Base64URL.decode(String(renewedKey.split(separator: ".")[1])))
        #expect(!String(decoding: body, as: UTF8.self).contains("MF-2026-0001"))
        #expect(throws: LicenceLedgerError.cannotRenew(.superseded)) {
            try LicenceLedger.renew(superseded, expires: nil, signingKey: try v.privateKey, publicKey: try v.publicKey, ledger: [], createdBy: "t")
        }
    }

    @Test func voidIsLedgerOnlyAndKeepsTheReason() {
        let r = LicenceLedger.void(record("MF-2026-0001", notes: "first"), reason: "Customer refunded")
        #expect(r.status == .void)
        #expect(r.notes == "first\nCustomer refunded")
    }

    @Test func expiryWindows() {
        let today = day("2026-10-08")
        #expect(record("A", expires: "2026-10-08").daysUntilExpiry(today: today) == 0)
        #expect(record("A", expires: "2026-11-07").isExpiring(within: 30, today: today))
        #expect(!record("A", expires: "2026-11-08").isExpiring(within: 30, today: today))
        #expect(record("A", expires: "2026-10-07").isExpired(today: today))
        #expect(!record("A", status: .superseded, expires: "2026-10-10").isExpiring(within: 30, today: today))
        #expect(!record("A").isExpiring(within: 30, today: today))
        #expect(LicenceDate.adding(years: 1, to: "2028-02-29") == "2029-02-28")
    }

    @Test func summaryCountsActiveLicencesPerProduct() {
        let today = day("2026-10-08")
        let s = LicenceSummary(records: [
            record("MF-1", expires: "2026-10-20"), record("MF-2"), record("MF-3", status: .void),
            record("KY-1", product: .khayatyar, expires: "2026-10-01"),
        ], today: today)
        #expect(s.activeByProduct[.mediflow] == 2)
        #expect(s.activeByProduct[.khayatyar] == 1)
        #expect(s.expiringSoon.map(\.licenceID) == ["MF-1"])
        #expect(s.expired.map(\.licenceID) == ["KY-1"])
    }

    @Test func remindersAt30_14_7_1Days() {
        let reminders = LicenceReminder.schedule(for: [record("MF-1", expires: "2026-11-30"), record("MF-2", status: .void, expires: "2026-11-30")],
                                                 today: day("2026-11-01"), calendar: utc)
        #expect(reminders.map(\.daysBefore) == [14, 7, 1])  // the 30-day one (Oct 31) is already past
        #expect(reminders.map(\.fireDay) == ["2026-11-16", "2026-11-23", "2026-11-29"])
        #expect(reminders.first?.id == "licence-MF-1-14")
    }

    @Test func mergeNeverDropsAndStatusOnlyMovesForward() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(60)
        let local = [record("MF-1", status: .void, notes: "local", updated: t1), record("MF-2", key: "LNM1.k"), record("MF-3")]
        let remote = [record("MF-1", status: .superseded, notes: "remote", updated: t0), record("MF-2"), record("MF-4")]
        let (merged, conflicts) = LicenceLedger.merge(local, remote)
        #expect(conflicts.isEmpty)
        #expect(Set(merged.map(\.licenceID)) == ["MF-1", "MF-2", "MF-3", "MF-4"])
        let m1 = merged.first { $0.licenceID == "MF-1" }
        #expect(m1?.status == .void)
        #expect(m1?.notes == "local")
        #expect(merged.first { $0.licenceID == "MF-2" }?.keyText == "LNM1.k")
        // An older remote "active" never revives a void licence.
        let back = LicenceLedger.merge([record("MF-1", status: .active, updated: t1)], [record("MF-1", status: .void, updated: t0)])
        #expect(back.records.first?.status == .void)
    }

    @Test func mergeReportsSignedFieldConflicts() {
        let (merged, conflicts) = LicenceLedger.merge([record("MF-1", machine: "*")], [record("MF-1")])
        #expect(conflicts == [LicenceLedger.Conflict(licenceID: "MF-1")])
        #expect(merged.first?.machine == "4HDG-0NK5-EAKX-GQVR")  // the server copy is kept
    }
}

@Suite("Licence CSV")
struct LicenceCSVTests {
    // Shaped exactly like the Python tool's issued.csv (csv.writer quotes a field with a comma).
    private let issuedCSV = [
        "id,product,customer,machine,issued,expires,edition",
        "MF-2026-0001,mediflow,\"کلینیک شفا، کابل\",K7Q2-9XMB-4T1D-WP3C,2026-10-08,,standard",
        #"KY-2026-0001,khayatyar,"Omid ""Tailor""",*,2026-10-08,2027-10-07,standard"#,
        "MF-2026-0002,mediflow,Bad,K7Q2,2026-10-08,,standard",
        "MF-2026-0003,mediflow,Dup,K7Q2-9XMB-4T1D-WP3C,2026-10-08,,standard",
    ].joined(separator: "\r\n") + "\r\n"

    @Test func importsIssuedCSVWithUnknownKeyAndFeatures() {
        let result = LicenceCSV.importLedger(issuedCSV, existing: [record("MF-2026-0003")])
        #expect(result.added.map(\.licenceID) == ["MF-2026-0001", "KY-2026-0001"])
        #expect(result.skipped == ["MF-2026-0003"])
        #expect(result.rejected.map(\.line) == [4])
        let mf = result.added[0]
        #expect(mf.customer == "کلینیک شفا، کابل")
        #expect(mf.expires == nil)
        #expect(mf.keyText == nil)   // issued.csv has no key: unknown, never invented
        #expect(mf.features == nil)
        #expect(mf.createdBy == "issued.csv import")
        #expect(result.added[1].customer == "Omid \"Tailor\"")
        #expect(result.added[1].machine == "*")
        #expect(result.added[1].expires == "2027-10-07")
    }

    @Test func refusesAFileThatIsntALedger() {
        let result = LicenceCSV.importLedger("name,email\na,b\n", existing: [])
        #expect(result.added.isEmpty)
        #expect(result.rejected.first?.line == 1)
    }

    @Test func exportRoundTrips() {
        var r = record("KY-2026-0001", product: .khayatyar, status: .superseded, expires: "2027-01-01", notes: "line 1\nline, 2")
        r.customer = "خیاطی \"امید\""
        r.renewedFrom = "KY-2025-0009"
        let csv = LicenceCSV.export([r])
        #expect(csv.hasPrefix(LicenceCSV.exportColumns.joined(separator: ",")))
        let back = LicenceCSV.importLedger(csv, existing: [])
        #expect(back.rejected.isEmpty)
        let b = back.added.first
        #expect(b?.customer == r.customer)
        #expect(b?.notes == r.notes)
        #expect(b?.status == .superseded)
        #expect(b?.renewedFrom == "KY-2025-0009")
        #expect(b?.features == ["*"])
    }

    @Test func attachesVerifiedKeysFromLnmlicFiles() throws {
        let v = try Vectors.load()
        let pub = try v.publicKey
        let valid = try #require(v.keys.first { $0.product == "mediflow" && $0.case == "valid_perpetual" })
        let tampered = try #require(v.keys.first { $0.product == "mediflow" && $0.case == "tampered_payload" })
        let row = LicenceRecord(product: .mediflow, licenceID: "MF-TEST-0001", customer: "کلینیک آزمایشی / Test", machine: "4HDG-0NK5-EAKX-GQVR",
                                issued: "2026-10-08", expires: nil, features: nil, createdBy: "issued.csv import", createdAt: .now)
        let result = LicenceCSV.attach(keys: [("MF-TEST-0001.lnmlic", valid.key + "\n"), ("bad.lnmlic", tampered.key)],
                                       to: [row], publicKey: { _ in pub })
        #expect(result.attached == ["MF-TEST-0001"])
        #expect(result.rejected.count == 1)
        #expect(result.records.first?.keyText == valid.key)
        #expect(result.records.first?.features == ["*"])
    }
}

@Suite("Licence sync")
struct LicenceSyncTests {
    private actor StubRemote: LicenceRemote {
        var rows: [LicenceRecord]
        var upserts: [[LicenceRecord]] = []
        init(_ rows: [LicenceRecord]) { self.rows = rows }
        func fetchAll() async throws -> [LicenceRecord] { rows }
        func upsert(_ records: [LicenceRecord]) async throws {
            upserts.append(records)
            rows = LicenceLedger.merge(records, rows).records  // the server applies the same rules
        }
    }

    @Test func uploadsOnlyWhatChangedAndKeepsServerRows() async throws {
        let remote = StubRemote([record("MF-1"), record("MF-2")])
        let result = try await LicenceSync.sync(local: [record("MF-1", status: .void), record("MF-3")], remote: remote)
        #expect(Set(result.records.map(\.licenceID)) == ["MF-1", "MF-2", "MF-3"])
        #expect(result.uploaded == 2)
        let sent = await remote.upserts
        #expect(sent.count == 1)
        #expect(Set(sent[0].map(\.licenceID)) == ["MF-1", "MF-3"])
        #expect(await remote.rows.first { $0.licenceID == "MF-1" }?.status == .void)
    }

    @Test func nothingToSendWhenInStep() async throws {
        let rows = [record("MF-1")]
        let remote = StubRemote(rows)
        let result = try await LicenceSync.sync(local: rows, remote: remote)
        #expect(result.uploaded == 0)
        #expect(await remote.upserts.isEmpty)
    }

    @Test func ledgerFileRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "licences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LicenceLedgerStore(fileURL: url)
        #expect(try await store.load().records.isEmpty)
        let file = LicenceLedgerFile(records: [record("MF-1", expires: "2027-01-01")], needsUpload: true)
        try await store.save(file)
        #expect(try await store.load() == file)
    }

    private final class Recorder: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        let body: String
        init(_ body: String) { self.body = body }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { requests.append(request) }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func supabaseRemoteUsesTheAdminRPCs() async throws {
        let exported = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","product":"mediflow","licenceID":"MF-2026-0001","customer":"SAMPLE","machine":"*","issued":"2026-10-08","edition":"standard","status":"active","notes":"","createdBy":"Linumic OS","createdAt":"2026-10-08T10:00:00Z","updatedAt":"2026-10-08T10:00:00Z"}]"#
        let t = Recorder(exported)
        let remote = SupabaseLicenceRemote(config: SupabaseConfig(url: URL(string: "https://sample.supabase.co")!, publishableKey: "sb_publishable_SAMPLE"),
                                           transport: t, token: { "tok" })
        let rows = try await remote.fetchAll()
        #expect(rows.first?.licenceID == "MF-2026-0001")
        #expect(rows.first?.expires == nil)
        #expect(rows.first?.keyText == nil)
        #expect(rows.first?.features == nil)
        try await remote.upsert(rows)
        #expect(t.requests.map { $0.url!.path } == ["/rest/v1/rpc/export_licences", "/rest/v1/rpc/upsert_licences"])
        #expect(t.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        let body = try JSONSerialization.jsonObject(with: try #require(t.requests[1].httpBody)) as? [String: Any]
        #expect((body?["rows"] as? [Any])?.count == 1)
    }
}
