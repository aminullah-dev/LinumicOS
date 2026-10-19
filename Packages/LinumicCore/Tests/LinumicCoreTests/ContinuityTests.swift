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
        #expect(back.inventory?.products.map(\.id) == ["worktrack"])
        #expect(back.obligations.contains { $0.id == "signing.linumicos-mac-profile" })
        // No licence key text, ever; the rest of the ledger is there.
        #expect(back.licences?.first?.keyText == nil)
        #expect(back.licences?.first?.licenceID == "KY-2026-0001")
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

    @Test func moreSecretFormatsAreCaught() throws {
        // Each built from parts, so no file in the repository looks like a key to a secret scanner.
        let age = ["AGE", "SECRET", "KEY", "1" + String(repeating: "Q", count: 58)].joined(separator: "-")
        #expect(ContinuityBundle.forbiddenKinds(in: Data("note: \(age)".utf8)) == ["an age secret key"])
        let jwt = ["ey" + "J" + String(repeating: "h", count: 20), "ey" + "J" + String(repeating: "p", count: 40),
                   String(repeating: "s", count: 43)].joined(separator: ".")
        #expect(ContinuityBundle.forbiddenKinds(in: Data("service_role \(jwt)".utf8)) == ["a JSON Web Token"])
        let stripe = "sk" + "_live_" + String(repeating: "4", count: 24)
        let restricted = "rk" + "_live_" + String(repeating: "5", count: 24)
        #expect(ContinuityBundle.forbiddenKinds(in: Data(stripe.utf8)) == ["a Stripe live key"])
        #expect(ContinuityBundle.forbiddenKinds(in: Data(restricted.utf8)) == ["a Stripe live key"])
        let aws = "AK" + "IA" + String(repeating: "Z", count: 16)
        #expect(ContinuityBundle.forbiddenKinds(in: Data("key \(aws)".utf8)) == ["an AWS access key"])
        // Ordinary text near those shapes is not a secret.
        #expect(ContinuityBundle.forbiddenKinds(in: Data("eyJ only once; sk_test_ is not live; AKIA short".utf8)).isEmpty)
        // The other services the owner uses.
        let others: [(String, String)] = [
            ("nt" + "n_" + String(repeating: "N", count: 46), "a Notion token"),
            ("sec" + "ret_" + String(repeating: "n", count: 43), "a Notion token"),
            ("sk" + "-proj-" + String(repeating: "o", count: 40), "an OpenAI API key"),
            ("sk" + "_" + String(repeating: "a1", count: 24), "an ElevenLabs API key"),
            ("xo" + "xb-" + "123456789012-" + String(repeating: "S", count: 24), "a Slack token"),
            ("ya" + "29." + String(repeating: "g", count: 60), "a Google OAuth token"),
            ("GOC" + "SPX-" + String(repeating: "c", count: 28), "a Google OAuth client secret"),
            ("EA" + "AB" + String(repeating: "m", count: 120), "a Meta access token"),
        ]
        for (token, kind) in others {
            #expect(ContinuityBundle.forbiddenKinds(in: Data("note: \(token) end".utf8)) == [kind], "\(kind)")
        }
        // Words that only start the same way, and a Supabase secret key (its own kind, not a Notion token).
        #expect(ContinuityBundle.forbiddenKinds(in: Data("secret_key, sk_live is Stripe, EAAS team, ya29 short, xoxo".utf8)).isEmpty)
        let supabase = "sb" + "_secret_" + String(repeating: "Q", count: 44)
        #expect(ContinuityBundle.forbiddenKinds(in: Data(supabase.utf8)) == ["a Supabase secret key"])
        // A bundle with a JWT in a note is refused before anything is written.
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ContinuityExporter.Failure.forbiddenContent(["a JSON Web Token"])) {
            try ContinuityExporter.export(bundle(note: jwt), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external,
                                          now: now, workFactor: 10, calendar: utc)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).isEmpty)
    }

    @Test func aFileThatFailsItsCheckIsRemoved() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The bytes change between writing and reading back (a folder that hands back something else).
        #expect(throws: ContinuityExporter.Failure.readBackDiffers) {
            try ContinuityExporter.export(bundle(), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external, now: now,
                                          workFactor: 10, calendar: utc,
                                          write: { try $0.write(to: $1, options: [.withoutOverwriting]) },
                                          afterWrite: { url in
                                              var data = try Data(contentsOf: url)
                                              data[data.count - 1] ^= 0xFF
                                              try data.write(to: url)
                                          })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).isEmpty)
    }

    @Test func aWriteThatStopsHalfwayLeavesNothingAndAnotherFileIsKept() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Pulled: Error {}
        // The USB stick is pulled halfway through the write.
        #expect(throws: Pulled.self) {
            try ContinuityExporter.export(bundle(), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external, now: now,
                                          workFactor: 10, calendar: utc,
                                          write: { data, url in
                                              try data.prefix(data.count / 2).write(to: url, options: [.withoutOverwriting])
                                              throw Pulled()
                                          }, afterWrite: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).isEmpty)
        // A file of the same name that appeared just before the write is someone else's: it stays.
        #expect(throws: CocoaError.self) {
            try ContinuityExporter.export(bundle(), passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external, now: now,
                                          workFactor: 10, calendar: utc,
                                          write: { data, url in
                                              try Data("theirs".utf8).write(to: url)
                                              try data.write(to: url, options: [.withoutOverwriting])
                                          }, afterWrite: { _ in })
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        #expect(left == ["linumic-os-continuity-2026-10-19-1200.json.age"])
        #expect(try Data(contentsOf: dir.appending(path: left[0])) == Data("theirs".utf8))
    }

    @Test func anUnreadInventoryOrObligationsFileIsNoExport() throws {
        // Before the inventory has loaded, after its load failed, or with obligations.json unreadable: nothing is
        // written, nothing is recorded, and no count stands in for what was not read.
        let register = ObligationsBuilder.build(file: ObligationsFile(), live: ObligationLiveInput(), now: now, calendar: utc)
        let noInventory = ContinuityBundle(createdAt: now, app: "Linumic OS 0.2.0 (2)", inventory: nil, obligationEntries: ObligationsFile(),
                                           obligations: register.obligations, accounts: register.accounts, licences: [],
                                           licencesSyncedAt: nil, keysRegistry: KeysRegistry.seed)
        let noObligations = ContinuityBundle(createdAt: now, app: "Linumic OS 0.2.0 (2)", inventory: Inventory(seedRevision: 7, products: []),
                                             obligationEntries: nil, obligations: register.obligations, accounts: register.accounts,
                                             licences: [], licencesSyncedAt: nil, keysRegistry: KeysRegistry.seed)
        #expect(noInventory.counts["products"] == nil && noInventory.requiredPartsNotRead == [.inventory])
        #expect(noObligations.counts["obligations"] == nil && noObligations.counts["accounts"] == nil)
        #expect(noObligations.counts["products"] == 0)   // read, and empty
        #expect(noObligations.requiredPartsNotRead == [.obligationEntries])
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var log = ContinuityLog()
        for (b, missing) in [(noInventory, [ContinuityBundle.Part.inventory]), (noObligations, [.obligationEntries])] {
            #expect(throws: ContinuityExporter.Failure.requiredPartsNotRead(missing)) {
                log.add(try ContinuityExporter.export(b, passphrase: passphrase, to: dir, folderName: "USB", folderKind: .external,
                                                      now: now, workFactor: 10, calendar: utc))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).isEmpty)
        #expect(log.exports.isEmpty && log.lastVerifiedOffMac == nil)
        #expect(ObligationsBuilder.build(file: ObligationsFile(), live: ObligationLiveInput(continuity: log), now: now, calendar: utc)
                    .obligation("continuity.export")?.due == nil)
    }

    @Test func aPartThatWasNotReadIsAbsentNotZero() throws {
        let register = ObligationsBuilder.build(file: ObligationsFile(), live: ObligationLiveInput(), now: now, calendar: utc)
        let b = ContinuityBundle(createdAt: now, app: "Linumic OS 0.2.0 (2)", inventory: Inventory(seedRevision: 7, products: []),
                                 obligationEntries: ObligationsFile(), obligations: register.obligations, accounts: register.accounts,
                                 licences: nil, licencesSyncedAt: nil, keysRegistry: nil)
        #expect(b.counts["licences"] == nil && b.counts["keys"] == nil && b.counts["keyBackups"] == nil)
        #expect(b.counts["products"] == 0)
        #expect(b.partsNotRead.count == 2)
        let json = String(decoding: try b.encoded(), as: UTF8.self)
        #expect(!json.contains("\"licences\"") && !json.contains("\"keysRegistry\""))
        #expect(try ContinuityBundle.decode(b.encoded()) == b)
        #expect(bundle().partsNotRead.isEmpty)
    }

    @Test func aFileThatIsNotTheOneWrittenFailsTheCheck() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Other bytes than were written (a folder that hands back something else): caught by the file's SHA-256 before
        // any decryption, so nothing is recorded as verified.
        let target = dir.appending(path: "x.json.age")
        try Data("not age".utf8).write(to: target)
        #expect(throws: ContinuityExporter.Failure.readBackDiffers) {
            try ContinuityExporter.verify(file: target, passphrase: passphrase, fileSHA256: "0", plaintextSHA256: "0", now: now)
        }
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
        // Typable anywhere: a Dari passphrase can hold letters that look the same but are other characters elsewhere.
        let dari = "این یک عبارت رمز طولانی است"
        #expect(ContinuityPassphrase.problem(dari, confirmation: dari) != nil)
        let halfSpace = "write this on\u{200C}paper 2026"
        #expect(ContinuityPassphrase.problem(halfSpace, confirmation: halfSpace) != nil)
        #expect(!ContinuityPassphrase.isTypableAnywhere("tab\there"))
        #expect(ContinuityPassphrase.isTypableAnywhere("Write this, on paper: 2026!"))
        #expect(ContinuityPassphrase.problem("short", confirmation: "short") != nil)
        #expect(ContinuityPassphrase.problem("aaaaaaaaaaaaaaaaaaaa", confirmation: "aaaaaaaaaaaaaaaaaaaa") != nil)
        #expect(ContinuityPassphrase.problem("write this on paper 2026", confirmation: "write this on paper 2025") != nil)
        #expect(ContinuityPassphrase.problem("write this on paper 2026", confirmation: "write this on paper 2026") == nil)
        // Spaces that can't be seen on paper: age reads them as typed, so the copy from the paper would not open it.
        for spaced in [" write this on paper 2026", "write this on paper 2026 ", "write this  on paper 2026"] {
            #expect(ContinuityPassphrase.problem(spaced, confirmation: spaced) != nil, "\(spaced)")
        }
        let s = ContinuityPassphrase.suggestion()
        #expect(s.count == 29 && s.split(separator: "-").count == 6)
        #expect(ContinuityPassphrase.problem(s, confirmation: s) == nil)
        #expect(s != ContinuityPassphrase.suggestion())
    }

    @Test func whereTheFolderIs() {
        let home = "/Users/a"
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Library/CloudStorage/GoogleDrive-a@b.c/My Drive/Mohem", home: home,
                                              volumeIsInternal: true) == .cloud)
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Linumic", home: home + "/",
                                              volumeIsInternal: true) == .cloud)
        #expect(ContinuityFolderKind.classify(path: "/Volumes/LINUMIC", home: home, volumeIsInternal: false) == .external)
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Documents", home: home, volumeIsInternal: true) == .thisMac)
        #expect(ContinuityFolderKind.classify(path: "/x", home: home, volumeIsInternal: nil) == .unknown)
        #expect(ContinuityFolderKind.classify(path: "/Volumes/share", home: home, volumeIsInternal: nil, volumeIsLocal: false) == .network)
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Documents", home: home, volumeIsInternal: true, volumeIsLocal: true) == .thisMac)
        // A folder on this Mac's disk whose path only holds those names (a copied tree) is not a cloud folder.
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Documents/x/Library/CloudStorage/y", home: home, volumeIsInternal: true) == .thisMac)
        #expect(ContinuityFolderKind.classify(path: "/Users/b/Library/CloudStorage/GoogleDrive-b/My Drive", home: home,
                                              volumeIsInternal: true) == .thisMac)
        #expect(ContinuityFolderKind.classify(path: "/Users/a/Library/CloudStorage/x", home: "", volumeIsInternal: true) == .thisMac)
        #expect(ContinuityFolderKind.external.isOffThisMac && ContinuityFolderKind.network.isOffThisMac)
        #expect(!ContinuityFolderKind.thisMac.isOffThisMac && !ContinuityFolderKind.unknown.isOffThisMac)
    }
}
