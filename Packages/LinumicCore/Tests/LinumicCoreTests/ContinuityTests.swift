import CryptoKit
import Foundation
import Testing
@testable import LinumicCore

// The encrypted export: written, read back from the folder, decrypted and compared before it counts. No network.

private let now = Date(timeIntervalSince1970: 1_792_411_200) // 2026-10-19T12:00:00Z
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func sha(_ d: Data) -> String { ageTestSHA(d) }

// MARK: - The export

private func bundle(licenceKey: String? = "LNM1.\(String(repeating: "A", count: 40)).\(String(repeating: "B", count: 40))",
                    note: String = "") -> ContinuityBundle {
    var product = Product(id: "worktrack", name: "WorkTrack")
    product.notes = note
    let licence = LicenceRecord(product: .khayatyar, licenceID: "KY-2026-0001", customer: "A tailor", machine: "M1",
                                issued: "2026-10-17", expires: "2028-10-17", keyText: licenceKey, createdBy: "test", createdAt: now)
    let register = ObligationsBuilder.build(file: ObligationsFile(), live: ObligationLiveInput(), now: now, calendar: utc)
    return ContinuityBundle(createdAt: now, app: "Linumic OS 0.2.0 (2)", inventory: Inventory(seedRevision: 7, products: [product]),
                            obligationEntries: ObligationsFile(), obligations: register.obligations, accounts: register.accounts,
                            licences: [licence], licencesSyncedAt: now, keysRegistry: KeysRegistry.seed)
}

private func folder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "continuity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Continuity: the encrypted export")
struct ContinuityExportTests {
    private let passphrase = "write this on paper 2026"

    @Test func writesReadsBackAndRecordsTheEvidence() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = bundle()
        let record = try ContinuityExporter.export(b, passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external,
                                                   now: now, workFactor: 10, calendar: utc)
        #expect(record.fileName == "linumic-os-continuity-2026-10-19-1200.json.age")
        #expect(record.isVerified && record.verifiedAt == now)
        #expect(record.counts["products"] == 1 && record.counts["licences"] == 1)
        // What is on the disk opens with the passphrase alone and is the documented JSON.
        let file = try Data(contentsOf: dir.appending(path: record.fileName))
        #expect(sha(file) == record.fileSHA256 && file.count == record.fileBytes)
        let plain = try AgeFile.decrypt(file, passphrase: passphrase)
        #expect(sha(plain) == record.plaintextSHA256)
        let back = try ContinuityBundle.decode(plain)
        #expect(back.format == "linumic-os-continuity" && back.formatVersion == 1)
        #expect(back.inventory.products.map(\.id) == ["worktrack"])
        #expect(back.obligations.contains { $0.id == "signing.linumicos-mac-profile" })
        // No licence key text, ever; the rest of the ledger is there.
        #expect(back.licences.first?.keyText == nil)
        #expect(back.licences.first?.licenceID == "KY-2026-0001")
        #expect(!String(decoding: plain, as: UTF8.self).contains("LNM1."))
        #expect(!back.excluded.isEmpty)
    }

    @Test func aSecretInAnyRecordStopsTheExportBeforeAnythingIsWritten() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Built from parts, so no file in the repository looks like a key to a secret scanner.
        let pem = ["-----BEGIN", "PRIVATE", "KEY-----\nMIIE\n-----END", "PRIVATE", "KEY-----"].joined(separator: " ")
        #expect(throws: ContinuityExporter.Failure.forbiddenContent(["a PEM key or certificate block"])) {
            try ContinuityExporter.export(bundle(note: pem), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external,
                                          now: now, workFactor: 10, calendar: utc)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).isEmpty)
        #expect(ContinuityBundle.forbiddenKinds(in: Data("token ghp_\(String(repeating: "x", count: 36))".utf8)) == ["a GitHub token"])
        #expect(ContinuityBundle.forbiddenKinds(in: Data("LNM1 licences for MediFlow".utf8)).isEmpty)
    }

    @Test func neverOverwritesAndChecksAgainLater() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ContinuityExporter.export(bundle(), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external,
                                                  now: now, workFactor: 10, calendar: utc)
        let second = try ContinuityExporter.export(bundle(), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external,
                                                   now: now, workFactor: 10, calendar: utc)
        #expect(second.fileName == "linumic-os-continuity-2026-10-19-1200-2.json.age")
        #expect(try ContinuityExporter.reverify(first, in: dir, passphrase: passphrase, now: now.addingTimeInterval(60)) == now.addingTimeInterval(60))
        #expect(throws: AgeFile.Failure.wrongPassphrase) {
            try ContinuityExporter.reverify(first, in: dir, passphrase: "not the passphrase at all", now: now)
        }
        // A file changed in the folder is caught before it is even decrypted.
        var data = try Data(contentsOf: dir.appending(path: first.fileName))
        data[data.count - 1] ^= 0xFF
        try data.write(to: dir.appending(path: first.fileName))
        #expect(throws: ContinuityExporter.Failure.readBackDiffers) {
            try ContinuityExporter.reverify(first, in: dir, passphrase: passphrase, now: now)
        }
    }

    @Test func theLogKeepsTheEvidenceAndTheOutsideChecks() throws {
        var log = ContinuityLog()
        #expect(log.lastVerified == nil)
        let onMac = ContinuityExportRecord(fileName: "a.json.age", folder: "~/Documents", folderKind: .thisMac, createdAt: now,
                                           verifiedAt: now, fileBytes: 1, fileSHA256: "f", plaintextBytes: 1, plaintextSHA256: "p",
                                           workFactor: 18, formatVersion: 1, counts: [:])
        log.add(onMac)
        #expect(log.lastVerified?.fileName == "a.json.age")
        #expect(log.lastVerifiedOffMac == nil)   // a folder on this Mac's own disk is not off this Mac
        #expect(throws: ObligationError.missingEvidence) {
            try log.recordOutsideCheck(onMac.id, on: KeyDay("2026-10-19")!, evidence: " ", now: now, calendar: utc)
        }
        #expect(throws: ObligationError.futureDay) {
            try log.recordOutsideCheck(onMac.id, on: KeyDay("2026-10-20")!, evidence: "opened", now: now, calendar: utc)
        }
        try log.recordOutsideCheck(onMac.id, on: KeyDay("2026-10-19")!, evidence: "age -d on the office PC; SHA-256 matched",
                                   now: now, calendar: utc)
        log.markReverified(onMac.id, at: now.addingTimeInterval(3600))
        #expect(log.exports[0].outsideChecks.count == 1)
        #expect(log.exports[0].lastVerifiedAt == now.addingTimeInterval(3600))

        let url = FileManager.default.temporaryDirectory.appending(path: "continuity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ContinuityStore(fileURL: url)
        try store.save(log)
        guard case .loaded(let back) = store.load() else { Issue.record("not loaded"); return }
        #expect(back == log)
    }

    @Test func passphraseRulesAndSuggestions() {
        #expect(ContinuityPassphrase.problem("short", confirmation: "short") != nil)
        #expect(ContinuityPassphrase.problem("aaaaaaaaaaaaaaaaaaaa", confirmation: "aaaaaaaaaaaaaaaaaaaa") != nil)
        #expect(ContinuityPassphrase.problem("write this on paper 2026", confirmation: "write this on paper 2025") != nil)
        #expect(ContinuityPassphrase.problem("write this on paper 2026", confirmation: "write this on paper 2026") == nil)
        let s = ContinuityPassphrase.suggestion()
        #expect(s.count == 29 && s.split(separator: "-").count == 6)
        #expect(ContinuityPassphrase.problem(s, confirmation: s) == nil)
        #expect(s != ContinuityPassphrase.suggestion())
    }

    @Test func whereTheFolderIs() {
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Library/CloudStorage/GoogleDrive-a@b.c/My Drive/Mohem", volumeIsInternal: true) == .cloud)
        #expect(ContinuityFolderKind.classify(path: "/Volumes/LINUMIC", volumeIsInternal: false) == .external)
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Documents", volumeIsInternal: true) == .thisMac)
        #expect(ContinuityFolderKind.classify(path: "/x", volumeIsInternal: nil) == .unknown)
        #expect(ContinuityFolderKind.external.isOffThisMac && !ContinuityFolderKind.thisMac.isOffThisMac)
    }
}
