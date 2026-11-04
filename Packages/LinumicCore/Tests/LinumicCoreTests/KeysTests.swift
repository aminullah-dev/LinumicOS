import Foundation
import Testing
@testable import LinumicCore

// A fake file system only: no test touches a real key, keystore or the home folder.

private let home = "/Users/owner"
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ s: String) -> KeyDay { KeyDay(s)! }
private func at(_ s: String, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: Int(s.prefix(4)), month: Int(s.dropFirst(5).prefix(2)), day: Int(s.suffix(2)), hour: hour))!
}

private struct FakeFS: KeyFileSystem {
    /// Absolute path → modification day. Size is the path length, so it is never real.
    var files: [String: Date] = [:]
    var directories: Set<String> = []
    var links: Set<String> = []

    init(files: [String: Date], extraDirectories: [String] = [], links: [String] = []) {
        self.files = files
        var dirs = Set(extraDirectories)
        for path in files.keys {
            var p = (path as NSString).deletingLastPathComponent
            while p != "/" && !p.isEmpty {
                dirs.insert(p)
                p = (p as NSString).deletingLastPathComponent
            }
        }
        directories = dirs
        self.links = Set(links)
    }

    func fileInfo(atPath path: String) -> KeyFileInfo? {
        files[path].map { KeyFileInfo(path: path, size: Int64(path.count), modifiedAt: $0) }
    }

    func directoryExists(atPath path: String) -> Bool { directories.contains(path) }

    func entries(ofDirectory path: String) -> [KeyDirEntry]? {
        guard directories.contains(path) else { return nil }
        var out: [String: KeyDirEntry] = [:]
        for p in Array(files.keys) + Array(directories) + Array(links) {
            guard (p as NSString).deletingLastPathComponent == path else { continue }
            let name = (p as NSString).lastPathComponent
            out[name] = KeyDirEntry(name: name, isDirectory: directories.contains(p), isSymbolicLink: links.contains(p))
        }
        return Array(out.values)
    }
}

/// Every seeded key present, all modified before the backups. Keys recorded as deleted are absent, as they are.
private func seededFS(changing: [String: Date] = [:], removing: Set<String> = [], adding: [String: Date] = [:]) -> FakeFS {
    var files: [String: Date] = [:]
    for key in KeysRegistry.seed.keys where !key.isDeleted {
        let full = KeyPaths.expand(key.path, home: home)
        if key.isPattern {
            let dir = (full as NSString).deletingLastPathComponent
            for id in ["AAA", "BBB", "CCC", "DDD", "EEE"] { files["\(dir)/AuthKey_\(id).p8"] = at("2026-09-10") }
        } else {
            files[full] = at("2026-10-03")
        }
    }
    for (k, v) in changing { files[k] = v }
    for k in removing { files.removeValue(forKey: k) }
    for (k, v) in adding { files[k] = v }
    return FakeFS(files: files)
}

private func input(_ fs: FakeFS, registry: KeysRegistry = .seed, now: String = "2026-10-09", access: KeyAccess = .all,
                   passphrase: KeychainPresence = .present) -> KeysCheckInput {
    let results = registry.keys.map { KeyChecker.check($0, home: home, access: access, fs: fs) }
    let scan = KeysScanner.scan(home: home, access: access, fs: fs)
    return KeysCheckInput(registry: registry, now: at(now), home: home, results: results, scan: scan,
                          passphrase: [KeysRegistry.passphraseService: passphrase], checkedAt: at(now), calendar: utc)
}

/// The registry as the revision 2 seed (2026-10-18) wrote it: none of the backups of 2026-11-03, no iteration counts,
/// the earlier App Store Connect texts, and the second-copy and new-keys gaps open.
private func revision2Seed() -> KeysRegistry {
    var r = KeysRegistry.seed
    r.seedRevision = 2
    r.backups.removeAll { KeysRegistry.revision3AddedBackupIDs.contains($0.id) }
    for i in r.backups.indices { r.backups[i].pbkdf2Iterations = nil }
    for i in r.keys.indices { r.keys[i].backupIDs.removeAll { KeysRegistry.revision3AddedBackupIDs.contains($0) } }
    for (id, note) in KeysRegistry.revision2KeyNotes {
        guard let i = r.keys.firstIndex(where: { $0.id == id }) else { continue }
        r.keys[i].note = note
        r.keys[i].source = "~/Keys/README.md (2026-10-09)"
        r.keys[i].recordedOn = day("2026-10-09")
    }
    for (id, detail) in KeysRegistry.revision2GapDetails {
        guard let i = r.gaps.firstIndex(where: { $0.id == id }) else { continue }
        r.gaps[i].title = "App Store Connect keys and the notarytool profile are not backed up"
        r.gaps[i].detail = detail
        r.gaps[i].source = "~/Keys/README.md (2026-10-09)"
        r.gaps[i].recordedOn = day("2026-10-09")
    }
    for id in KeysRegistry.revision3ClosedGapIDs {
        guard let i = r.gaps.firstIndex(where: { $0.id == id }) else { continue }
        r.gaps[i].closedOn = nil
        r.gaps[i].closedNote = nil
    }
    return r
}

@Suite("Keys & Backups")
struct KeysTests {
    // MARK: Registry

    @Test func seedHoldsTheVerifiedFacts() throws {
        let seed = KeysRegistry.seed
        #expect(seed.keys.count == 15)
        #expect(seed.seedRevision == KeysRegistry.currentSeedRevision)
        #expect(seed.backups.map(\.id) == [KeysRegistry.androidBundleID, KeysRegistry.licenceBundleID,
                                           KeysRegistry.signingKeysBundleID, KeysRegistry.khayatyarPfxBackupID])
        let android = try #require(seed.backup(KeysRegistry.androidBundleID))
        #expect(android.driveFileID == "1mBSWqt_JwvEU7BMSFcJ-FJucPGJeuS4q")
        #expect(android.sizeBytes == 22_336)
        #expect(android.createdOn == day("2026-10-09"))
        #expect(android.lastRestoreTest?.by == "Owner")
        #expect(android.lastRestoreTest?.on == day("2026-10-09"))
        let licence = try #require(seed.backup(KeysRegistry.licenceBundleID))
        #expect(licence.driveFileID == "13YZuIKfJrlgZFH98_DeqqBUb_ZXhrd5b")
        #expect(licence.archive == .tar)
        #expect(seed.passphraseServices == ["Linumic license backup passphrase"])
        #expect(seed.secondCopyGap?.isOpen == false)   // closed by the bundle of 2026-11-03
        // Every fact carries a source.
        #expect(seed.keys.allSatisfy { !$0.source.isEmpty })
        #expect(seed.backups.allSatisfy { !$0.source.isEmpty && $0.restoreTests.allSatisfy { !$0.source.isEmpty } })
        #expect(seed.gaps.allSatisfy { !$0.source.isEmpty })
        #expect(seed.keys.first { $0.id == "velro-from-downloads" }?.doNotDelete == true)
        #expect(seed.keys.first { $0.id == "asc-api-keys" }?.backupIDs == [KeysRegistry.signingKeysBundleID])
    }

    @Test func seedHasTheBackupsOf20261103() throws {
        let seed = KeysRegistry.seed
        let d3 = day("2026-11-03")
        let bundle = try #require(seed.backup(KeysRegistry.signingKeysBundleID))
        #expect(bundle.fileName == "linumic-signing-keys-2026-11-03.tgz.enc")
        #expect(bundle.sizeBytes == 61_472)
        #expect(bundle.archive == .tarGzip)
        #expect(bundle.createdOn == d3)
        #expect(bundle.verifiedOn == d3)
        #expect(bundle.pbkdf2Iterations == 600_000)
        #expect(bundle.driveFileID == nil)   // on two offline drives, not in Drive
        #expect(bundle.location.contains("“BACKUP”") && bundle.location.contains("“Projects-Archive”"))
        #expect(bundle.verification?.contains("49 files") == true)
        #expect(bundle.verification?.contains("notarytool") == true)
        #expect(bundle.lastRestoreTest?.by == "Owner")
        #expect(bundle.lastRestoreTest?.on == d3)
        #expect(bundle.lastRestoreTest?.note?.contains("49 of 49") == true)

        let pfx = try #require(seed.backup(KeysRegistry.khayatyarPfxBackupID))
        #expect(pfx.fileName == "KhayatYar-signing.pfx.enc")
        #expect(pfx.sizeBytes == 3_552)
        #expect(pfx.archive == .singleFile)
        #expect(pfx.createdOn == day("2026-10-23"))
        #expect(pfx.verifiedOn == d3)
        // OpenSSL's default count, not the 600000 of the bundles: said in the text and used by the restore command.
        #expect(pfx.pbkdf2Iterations == 10_000)
        #expect(pfx.encryption.contains("10000"))
        #expect(pfx.verification?.contains("not the 600000") == true)
        #expect(pfx.verification?.contains("only on the owner's Windows PC") == true)
        #expect(pfx.lastRestoreTest?.by == "Owner")
        #expect(pfx.lastRestoreTest?.on == d3)
        // Same passphrase item as the Drive bundles.
        #expect(seed.passphraseServices == [KeysRegistry.passphraseService])
        #expect(seed.lastRestoreTest?.test.on == d3)

        // The bundle holds every key on this Mac; the .pfx is not on this Mac, so no tracked key points to its backup.
        let inBundle = Set(seed.keys.filter { $0.backupIDs.contains(KeysRegistry.signingKeysBundleID) }.map(\.id))
        #expect(inBundle == Set(seed.keys.filter { !$0.isDeleted }.map(\.id)))
        #expect(!seed.keys.contains { $0.backupIDs.contains(KeysRegistry.khayatyarPfxBackupID) })
        #expect(seed.keys.first { $0.id == "asc-api-keys" }?.note == "In the signing-keys bundle of 2026-11-03 (5 files).")

        // Gaps: the second copy and the new keys are done; the notarytool profile is still in no backup.
        for id in ["second-copy", "future-keys"] {
            let gap = try #require(seed.gaps.first { $0.id == id })
            #expect(gap.closedOn == d3)
            #expect(gap.closedNote?.contains("linumic-signing-keys-2026-11-03.tgz.enc") == true)
        }
        let notary = try #require(seed.gaps.first { $0.id == "asc-notary-not-backed-up" })
        #expect(notary.isOpen)
        #expect(notary.title == "The notarytool profile is not backed up")
        #expect(notary.detail != KeysRegistry.revision2GapDetails["asc-notary-not-backed-up"])

        // A public repository: what the new backups say holds no path of a key, key id, address, volume path or hash.
        let hex = try Regex("[0-9a-fA-F]{32,}")
        for b in [bundle, pfx] {
            let texts = [b.title, b.location, b.verification ?? "", b.encryption, b.source]
                + b.restoreTests.flatMap { [$0.note ?? "", $0.source] }
            for t in texts {
                #expect(!t.contains("/Users") && !t.contains("/Volumes") && !t.contains("AuthKey_") && !t.contains(".jks"), "\(t)")
                #expect(!t.contains("@") && !t.contains("C:\\"), "\(t)")
                #expect(t.firstMatch(of: hex) == nil, "\(t)")
            }
        }
        let tests = seed.backups.flatMap(\.restoreTests).map(\.id)
        #expect(Set(tests).count == tests.count)
        #expect(Set(seed.backups.map(\.id)).count == seed.backups.count)
    }

    @Test func savedRegistryFromRevision2GetsThe20261103BackupsOnce() throws {
        // Untouched: exactly the current seed afterwards.
        var plain = revision2Seed()
        let changed = plain.applySeedCorrections()
        #expect(changed)
        #expect(plain == KeysRegistry.seed)

        // With the owner's own edits: a key he added, a note he wrote, the second copy he closed himself.
        var old = revision2Seed()
        old.keys.append(TrackedKey(id: "owner-added", title: "Owner key", kind: .androidSigning, path: "~/Keys/owner.jks",
                                   source: "Entered in Linumic OS", recordedOn: day("2026-10-20")))
        let asc = try #require(old.keys.firstIndex { $0.id == "asc-api-keys" })
        old.keys[asc].note = "Owner's own note"
        let second = try #require(old.gaps.firstIndex { $0.id == "second-copy" })
        old.gaps[second].closedOn = day("2026-11-01")
        old.gaps[second].closedNote = "USB drive at home"

        let dir = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeysRegistryStore(fileURL: dir.appending(path: "keys-registry.json"))
        try store.save(old)
        let loaded = try #require(store.load())
        let seed = KeysRegistry.seed
        #expect(loaded.seedRevision == 3)
        #expect(loaded.backups == seed.backups)
        for s in seed.keys {
            #expect(loaded.keys.first { $0.id == s.id }?.backupIDs == s.backupIDs, "\(s.id)")
        }
        let loadedASC = try #require(loaded.keys.first { $0.id == "asc-api-keys" })
        #expect(loadedASC.note == "Owner's own note")   // left alone; the link to the bundle is added all the same
        #expect(loadedASC.backupIDs == [KeysRegistry.signingKeysBundleID])
        #expect(loaded.keys.first { $0.id == "owner-added" }?.backupIDs.isEmpty == true)
        let loadedSecond = try #require(loaded.gaps.first { $0.id == "second-copy" })
        #expect(loadedSecond.closedOn == day("2026-11-01"))
        #expect(loadedSecond.closedNote == "USB drive at home")
        #expect(loaded.gaps.first { $0.id == "future-keys" } == seed.gaps.first { $0.id == "future-keys" })
        #expect(loaded.gaps.first { $0.id == "asc-notary-not-backed-up" } == seed.gaps.first { $0.id == "asc-notary-not-backed-up" })
        var again = loaded
        #expect(again.applySeedCorrections() == false)   // idempotent
    }

    @Test func seedHasTheCorrectionsOf20261018() throws {
        let seed = KeysRegistry.seed
        let icloud = "~/Library/Mobile Documents/com~apple~CloudDocs/importand"
        // VELRO: the Play upload key is the iCloud file; the one in ~/.velro-keys is not.
        let play = try #require(seed.keys.first { $0.id == "velro-play-upload" })
        #expect(play.path == "\(icloud)/velro-release.jks")
        #expect(play.backupIDs == [KeysRegistry.androidBundleID, KeysRegistry.signingKeysBundleID])
        #expect(play.doNotDelete)
        let other = try #require(seed.keys.first { $0.id == "velro-release" })
        #expect(other.path == "~/.velro-keys/velro-release.jks")
        #expect(other.note?.contains("Not the key Google Play expects") == true)
        let copy = try #require(seed.keys.first { $0.id == "velro-from-downloads" })
        #expect(copy.title == "VELRO Play upload key (copy from Downloads)")
        #expect(copy.note?.contains("origin unknown") == false)
        // Keys the first seed missed (in no backup on 2026-10-18; in the bundle of 2026-11-03).
        let added = ["khayatyar-release": "~/Documents/Khayatyar.jks", "talar-release": "\(icloud)/Untitled.jks",
                     "namazia-release": "\(icloud)/Namazia.jks"]
        for (id, path) in added {
            let key = try #require(seed.keys.first { $0.id == id })
            #expect(key.path == path)
            #expect(key.kind == .androidSigning)
            #expect(key.backupIDs == [KeysRegistry.signingKeysBundleID])
            #expect(key.doNotDelete)
            #expect(key.recordedOn == day("2026-10-18"))
        }
        // The registry holds no hash of any kind, not even a certificate fingerprint from a document.
        #expect(!seed.keys.contains { ($0.note ?? "").contains("SHA") || ($0.note ?? "").contains("33:23") })
        // Gaps: the Talar key exists now; NerkhTimes and DukanPro keys are not on this Mac; the iCloud disk image is unverified.
        let future = try #require(seed.gaps.first { $0.id == "future-keys" })
        #expect(future.detail?.contains("not created yet") == false)
        #expect(future.detail?.contains("Talar") == true)
        for id in ["nerkhtimes-upload-key", "dukanpro-upload-key", "icloud-dmg-unverified"] {
            let gap = try #require(seed.gaps.first { $0.id == id })
            #expect(gap.isOpen)
            #expect(!gap.source.isEmpty)
        }
        #expect(seed.gaps.count == 6)
        #expect(Set(seed.keys.map(\.id)).count == seed.keys.count)
        #expect(Set(seed.gaps.map(\.id)).count == seed.gaps.count)
    }

    @Test func savedRegistryFromTheFirstSeedGetsTheCorrectionsOnce() throws {
        // A registry as the 2026-10-09 seed wrote it: no revision, the old VELRO notes and the old gap text.
        var old = revision2Seed()
        old.seedRevision = nil
        old.keys.removeAll { KeysRegistry.revision2AddedKeyIDs.contains($0.id) }
        old.gaps.removeAll { KeysRegistry.revision2AddedGapIDs.contains($0.id) }
        for (id, note) in KeysRegistry.revision1KeyNotes {
            let i = try #require(old.keys.firstIndex { $0.id == id })
            old.keys[i].title = "old title"
            old.keys[i].note = note
        }
        let g = try #require(old.gaps.firstIndex { $0.id == "future-keys" })
        old.gaps[g].detail = KeysRegistry.revision1GapDetails["future-keys"]
        old.gaps[g].closedOn = day("2026-10-12")   // the owner closed it: stays closed
        // An owner-added key survives; an owner-edited note is left alone.
        old.keys.append(TrackedKey(id: "owner-added", title: "Owner key", kind: .androidSigning, path: "~/Keys/owner.jks",
                                   source: "Entered in Linumic OS", recordedOn: day("2026-10-10")))
        let fromDownloads = try #require(old.keys.firstIndex { $0.id == "velro-from-downloads" })
        old.keys[fromDownloads].note = "Owner's own note"

        let dir = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeysRegistryStore(fileURL: dir.appending(path: "keys-registry.json"))
        try store.save(old)
        let loaded = try #require(store.load())
        #expect(loaded.seedRevision == 3)
        for id in KeysRegistry.revision2AddedKeyIDs { #expect(loaded.keys.contains { $0.id == id }, "\(id)") }
        for id in KeysRegistry.revision2AddedGapIDs { #expect(loaded.gaps.contains { $0.id == id }, "\(id)") }
        let velro = try #require(loaded.keys.first { $0.id == "velro-release" })
        #expect(velro.title == "Other VELRO key (not the Play key)")
        #expect(velro.path == "~/.velro-keys/velro-release.jks")
        #expect(velro.backupIDs == [KeysRegistry.androidBundleID, KeysRegistry.signingKeysBundleID])
        #expect(loaded.keys.first { $0.id == "velro-from-downloads" }?.note == "Owner's own note")
        #expect(loaded.keys.first { $0.id == "velro-from-downloads" }?.title == "old title")
        let future = try #require(loaded.gaps.first { $0.id == "future-keys" })
        #expect(future.detail == KeysRegistry.seed.gaps.first { $0.id == "future-keys" }?.detail)
        #expect(future.closedOn == day("2026-10-12"))   // the owner's closing, not revision 3's
        #expect(loaded.keys.contains { $0.id == "owner-added" })
        var again = loaded
        #expect(again.applySeedCorrections() == false)   // idempotent

        // The owner removes an added key; it is not added back on the next load.
        var edited = loaded
        edited.removeKey("namazia-release", now: at("2026-10-19"))
        try store.save(edited)
        let reloaded = try #require(store.load())
        #expect(!reloaded.keys.contains { $0.id == "namazia-release" })
    }

    @Test func passphraseFileIsRecordedAsDeletedNotMissing() throws {
        let seed = KeysRegistry.seed
        let file = try #require(seed.keys.first { $0.id == "licence-passphrase-file" })
        #expect(file.deletedOn == day("2026-10-09"))
        #expect(file.deletedNote?.contains("Linumic license backup passphrase") == true)
        for b in seed.backups {
            #expect(b.passphraseKeptIn == ["macOS Keychain", "Private Notion page", "Paper"])
        }
        // Absent (as it should be): no reminder at all about it.
        let absent = KeysRules.reminders(input(seededFS()))
        #expect(!absent.contains { $0.keyID == "licence-passphrase-file" })
        #expect(KeysRules.backupState(file, registry: seed, result: nil) == .notApplicable)
        // Back on the Mac: one reminder that says so.
        let path = KeyPaths.expand(file.path, home: home)
        let back = KeysRules.reminders(input(seededFS(adding: [path: at("2026-10-12")]), now: "2026-10-12"))
        let r = try #require(back.first { $0.keyID == "licence-passphrase-file" })
        #expect(r.kind == .deletedFileBack)
        #expect(r.severity == .normal)
    }

    @Test func savedRegistryFromTheOlderSeedGetsTheDeletionFact() throws {
        var old = KeysRegistry.seed
        let i = try #require(old.keys.firstIndex { $0.id == "licence-passphrase-file" })
        old.keys[i].deletedOn = nil
        old.keys[i].deletedNote = nil
        for b in old.backups.indices { old.backups[b].passphraseKeptIn = ["macOS Keychain", "Private Notion page"] }
        // An owner-added key survives the correction.
        old.keys.append(TrackedKey(id: "owner-added", title: "Talar key", kind: .androidSigning, path: "~/Keys/talar.jks",
                                   source: "Entered in Linumic OS", recordedOn: day("2026-10-10")))
        let dir = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeysRegistryStore(fileURL: dir.appending(path: "keys-registry.json"))
        try store.save(old)
        let loaded = try #require(store.load())
        #expect(loaded.keys.first { $0.id == "licence-passphrase-file" }?.deletedOn == day("2026-10-09"))
        #expect(loaded.backups.allSatisfy { $0.passphraseKeptIn.contains("Paper") })
        #expect(loaded.keys.contains { $0.id == "owner-added" })
        var again = loaded
        #expect(again.applySeedCorrections() == false)   // idempotent
    }

    @Test func registryRoundTripsThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KeysRegistryStore(fileURL: dir.appending(path: "keys-registry.json"))
        #expect(store.load() == .seed)   // nothing saved: the seed
        var reg = KeysRegistry.seed
        let ok1 = reg.recordRestoreTest(backupID: KeysRegistry.licenceBundleID,
                                      RestoreTest(on: day("2026-10-09"), by: "Owner", source: "Entered in Linumic OS"), now: at("2026-10-09"), calendar: utc)
        #expect(ok1)
        try store.save(reg)
        #expect(store.load() == reg)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"2026-10-09\""))
        // A corrupt file is reported as nil, never replaced by the seed.
        try Data("{".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test func editingRefusesFutureDaysAndUnknownIDs() {
        var reg = KeysRegistry.seed
        let now = at("2026-10-09")
        let ok2 = reg.recordRestoreTest(backupID: "nope", RestoreTest(on: day("2026-10-01"), by: "Owner", source: "x"), now: now, calendar: utc)
        #expect(!ok2)
        let ok3 = reg.recordRestoreTest(backupID: KeysRegistry.androidBundleID, RestoreTest(on: day("2026-10-10"), by: "Owner", source: "x"),
                                       now: now, calendar: utc)
        #expect(!ok3)
        #expect(reg.updatedAt == nil)
        let ok4 = reg.closeGap("second-copy", on: day("2026-10-11"), note: nil, now: now, calendar: utc)
        #expect(!ok4)
        let ok5 = reg.closeGap("second-copy", on: day("2026-10-09"), note: "USB drive at home", now: now, calendar: utc)
        #expect(ok5)
        #expect(reg.secondCopyGap?.isOpen == false)
        #expect(reg.updatedAt == now)
        reg.reopenGap("second-copy", now: now)
        #expect(reg.secondCopyGap?.isOpen == true)
        var key = reg.keys[0]
        key.note = "edited"
        reg.upsert(key, now: now)
        #expect(reg.keys[0].note == "edited")
        #expect(reg.keys.count == 15)
        reg.removeKey(key.id, now: now)
        #expect(reg.keys.count == 14)
    }

    @Test func keyDayParsesComparesAndCounts() {
        #expect(KeyDay("2026-13-01") == nil)
        #expect(KeyDay("26-10-01") == nil)
        #expect(KeyDay("nope") == nil)
        #expect(day("2026-10-08") < day("2026-10-09"))
        #expect(day("2026-10-09").days(until: day("2027-01-07")) == 90)
        #expect(day("2026-10-09").description == "2026-10-09")
        #expect(KeyDay(at("2026-10-09", hour: 23), calendar: utc) == day("2026-10-09"))
    }

    // MARK: File names and paths

    @Test func fileNameRules() {
        for name in ["worktrack-release.jks", "x.keystore", "UPLOAD.JKS", "mediflow-private.pem", "AuthKey_ABC123.p8"] {
            #expect(KeyFileName.isKeyFile(name), "\(name)")
        }
        for name in ["debug.keystore", "Debug.keystore", "public.pem", "mediflow-public.pem", "AuthKey.p8", "AuthKey_X.p12",
                     "keystore.properties", ".storepass", "notes.jks.txt", ".jks", "-private.pem"] {
            #expect(!KeyFileName.isKeyFile(name), "\(name)")
        }
        #expect(KeyFileName.matches("AuthKey_*.p8", "AuthKey_4SKX.p8"))
        #expect(!KeyFileName.matches("AuthKey_*.p8", "AuthKey_4SKX.p8.bak"))
        #expect(!KeyFileName.matches("AuthKey_*.p8", "Key_4SKX.p8"))
        #expect(KeyFileName.matches("a*b*c", "a-x-b-y-c"))
        #expect(KeyFileName.matches("same.jks", "same.jks"))
        #expect(!KeyFileName.matches("same.jks", "other.jks"))
    }

    @Test func pathsExpandAndAbbreviate() {
        #expect(KeyPaths.expand("~/Keys/a.jks", home: home) == "/Users/owner/Keys/a.jks")
        #expect(KeyPaths.expand("/abs", home: home) == "/abs")
        #expect(KeyPaths.abbreviate("/Users/owner/Keys/a.jks", home: home + "/") == "~/Keys/a.jks")
        #expect(KeyPaths.abbreviate("/Users/ownerX/a", home: home) == "/Users/ownerX/a")
        #expect(KeyPaths.isInside("/Users/owner/Keys/a", root: "/Users/owner/Keys"))
        #expect(!KeyPaths.isInside("/Users/owner/KeysX/a", root: "/Users/owner/Keys"))
    }

    // MARK: Checks and scan

    @Test func everythingPresentAndBackedUpLeavesOnlyKnownGaps() {
        // Since 2026-11-03 every key is in a backup and the second copy exists: nothing to remind. Restore tests are recent.
        #expect(KeysRules.reminders(input(seededFS(), now: "2026-11-03")).isEmpty)
        // As the revision 2 registry had it: no second copy; the ASC keys and the KhayatYar, Talar and Namazia keys
        // not backed up.
        let reminders = KeysRules.reminders(input(seededFS(), registry: revision2Seed()))
        let kinds = Set(reminders.map(\.kind))
        #expect(kinds == [.secondCopyMissing, .keyNotBackedUp])
        #expect(Set(reminders.filter { $0.kind == .keyNotBackedUp }.compactMap(\.keyID))
            == ["asc-api-keys", "khayatyar-release", "talar-release", "namazia-release"])
        let check = KeyChecker.check(KeysRegistry.seed.keys.first { $0.id == "asc-api-keys" }!, home: home, access: .all, fs: seededFS())
        #expect(check.files.count == 5)
    }

    @Test func missingKeyIsHighAndNotAlsoUnbacked() {
        let path = "/Users/owner/.velro-keys/velro-release.jks"
        let reminders = KeysRules.reminders(input(seededFS(removing: [path])))
        let missing = reminders.filter { $0.kind == .keyMissing }
        #expect(missing.map(\.keyID) == ["velro-release"])
        #expect(missing.first?.severity == .high)
        #expect(reminders.first?.kind == .keyMissing)   // most urgent first
    }

    @Test func keyModifiedAfterTheBackupDayIsFlagged() {
        let wt = "/Users/owner/Projects/Multiplatform/WorkTrack/worktrack-release.jks"
        let pem = "/Users/owner/.linumic/license-keys/mediflow-private.pem"
        let kyPem = "/Users/owner/.linumic/license-keys/khayatyar-private.pem"
        // Same day as the backup: can't be told apart, not flagged. A later day: flagged against the newest backup.
        let fs = seededFS(changing: [wt: at("2026-10-09", hour: 23), pem: at("2026-10-12")])
        let old = revision2Seed()
        let reminders = KeysRules.reminders(input(fs, registry: old, now: "2026-10-12"))
        let changed = reminders.filter { $0.kind == .keyChangedAfterBackup }
        #expect(changed.map(\.keyID) == ["mediflow-licence"])
        #expect(changed.first?.backupID == KeysRegistry.licenceBundleID)
        #expect(changed.first?.severity == .high)
        let key = KeysRegistry.seed.keys.first { $0.id == "mediflow-licence" }!
        let state = KeysRules.backupState(key, registry: old, result: KeyChecker.check(key, home: home, access: .all, fs: fs), calendar: utc)
        #expect(state == .changedAfterBackup(backupID: KeysRegistry.licenceBundleID, modified: day("2026-10-12")))

        // The bundle of 2026-11-03 holds both: a change before it is covered; one after it is flagged against it.
        #expect(!KeysRules.reminders(input(fs, now: "2026-11-03")).contains { $0.kind == .keyChangedAfterBackup })
        let later = seededFS(changing: [pem: at("2026-11-05"), kyPem: at("2026-11-03", hour: 23)])
        let flagged = KeysRules.reminders(input(later, now: "2026-11-05")).filter { $0.kind == .keyChangedAfterBackup }
        #expect(flagged.map(\.keyID) == ["mediflow-licence"])
        #expect(flagged.first?.backupID == KeysRegistry.signingKeysBundleID)
        #expect(flagged.first?.detail?.contains("linumic-signing-keys-2026-11-03.tgz.enc") == true)
    }

    @Test func unregisteredKeyFileIsUncovered() {
        let talar = "/Users/owner/Projects/Multiplatform/Talar/android/talar-release.jks"
        let fs = seededFS(adding: [
            talar: at("2026-10-09"),
            "/Users/owner/Projects/Multiplatform/Talar/android/debug.keystore": at("2026-10-09"),
            "/Users/owner/Projects/Velro/node_modules/pkg/test.jks": at("2026-10-09"),
            "/Users/owner/Projects/Velro/build/out.keystore": at("2026-10-09"),
            "/Users/owner/Projects/Velro/.git/x.jks": at("2026-10-09"),
            "/Users/owner/Documents/elsewhere.jks": at("2026-10-09"),   // outside the scanned folders
        ])
        let reminders = KeysRules.reminders(input(fs))
        let uncovered = reminders.filter { $0.kind == .uncoveredFile }
        #expect(uncovered.map(\.detail) == ["~/Projects/Multiplatform/Talar/android/talar-release.jks"])
    }

    @Test func scanDoesNotFollowLinksAndReportsMissingRoots() {
        var fs = FakeFS(files: ["/Users/owner/Keys/a.jks": at("2026-10-01"), "/Users/owner/Elsewhere/b.jks": at("2026-10-01")],
                        links: ["/Users/owner/Keys/link"])
        fs.directories.insert("/Users/owner/Keys/link")   // a link to a folder
        let result = KeysScanner.scan(roots: ["~/Keys", "~/.velro-keys"], home: home, access: .all, fs: fs)
        #expect(result.files.map(\.name) == ["a.jks"])
        #expect(result.roots.map(\.status) == [.scanned, .missing])
    }

    @Test func ungrantedLocationsSayNotGrantedInsteadOfGuessing() {
        let fs = seededFS()
        let access = KeyAccess(roots: ["/Users/owner/Keys", "/Users/owner/Projects/Multiplatform"])
        let i = input(fs, access: access)
        #expect(i.results["velro-release"]?.status == .notGranted)
        #expect(i.results["worktrack-release-copy"]?.files.count == 1)
        #expect(i.results["worktrack-release"]?.files.count == 1)
        let roots = Dictionary(uniqueKeysWithValues: (i.scan?.roots ?? []).map { ($0.root, $0.status) })
        #expect(roots["~/Keys"] == .scanned)
        #expect(roots["~/Projects"] == .partly(["~/Projects/Multiplatform"]))
        #expect(roots["~/.velro-keys"] == .notGranted)
        // SODER-HAKEM is outside the granted part of ~/Projects: not checked, not flagged.
        #expect(i.results["soder-hakem-release"]?.status == .notGranted)
        let reminders = KeysRules.reminders(i)
        #expect(!reminders.contains { $0.kind == .keyMissing })
        #expect(!reminders.contains { $0.kind == .uncoveredFile })
    }

    // MARK: Reminders

    @Test func restoreTestReminderAfterNinetyDays() {
        let fs = seededFS()
        let at90 = KeysRules.reminders(input(fs, now: "2027-01-07"))   // 90 days after 2026-10-09
        #expect(!at90.contains { $0.kind == .restoreTestDue && $0.backupID == KeysRegistry.androidBundleID })
        let at91 = KeysRules.reminders(input(fs, now: "2027-01-08"))
        #expect(at91.contains { $0.kind == .restoreTestDue && $0.backupID == KeysRegistry.androidBundleID })
        // The licence backup's last test was 2026-10-08, so it is due a day earlier.
        #expect(at90.contains { $0.kind == .restoreTestDue && $0.backupID == KeysRegistry.licenceBundleID })
        // The backups of 2026-11-03: due from the 91st day.
        let new: Set<String> = [KeysRegistry.signingKeysBundleID, KeysRegistry.khayatyarPfxBackupID]
        #expect(!KeysRules.reminders(input(fs, now: "2027-02-01")).contains { $0.kind == .restoreTestDue && new.contains($0.backupID ?? "") })
        #expect(Set(KeysRules.reminders(input(fs, now: "2027-02-02")).filter { $0.kind == .restoreTestDue }.compactMap(\.backupID))
            .isSuperset(of: new))

        var reg = KeysRegistry.seed
        reg.backups[1].restoreTests = []
        let none = KeysRules.reminders(input(fs, registry: reg))
        #expect(none.contains { $0.kind == .noRestoreTest && $0.backupID == KeysRegistry.licenceBundleID })
        #expect(KeysRules.restoreTestAge(reg.backups[0], now: at("2026-10-19"), calendar: utc) == 10)
    }

    @Test func passphraseAndSecondCopyRules() {
        let fs = seededFS()
        let missing = KeysRules.reminders(input(fs, passphrase: .missing))
        #expect(missing.contains { $0.kind == .passphraseMissing && $0.severity == .high })
        let unknown = KeysRules.reminders(input(fs, passphrase: .unknown))
        #expect(!unknown.contains { $0.kind == .passphraseMissing })

        // Closed in the seed (2026-11-03): no reminder. Reopened: the reminder is back. Closed again: gone.
        var reg = KeysRegistry.seed
        #expect(!KeysRules.reminders(input(fs, registry: reg)).contains { $0.kind == .secondCopyMissing })
        reg.reopenGap("second-copy", now: at("2026-11-03"))
        #expect(KeysRules.reminders(input(fs, registry: reg)).contains { $0.kind == .secondCopyMissing })
        reg.closeGap("second-copy", on: day("2026-10-09"), note: "USB at home", now: at("2026-10-09"), calendar: utc)
        #expect(!KeysRules.reminders(input(fs, registry: reg)).contains { $0.kind == .secondCopyMissing })
    }

    @Test func registryOnlyRemindersWithoutLocalChecks() {
        // iOS: no checks at all. Only the registry facts count.
        #expect(KeysRules.reminders(KeysCheckInput(registry: .seed, now: at("2026-11-03"), calendar: utc)).isEmpty)
        let i = KeysCheckInput(registry: revision2Seed(), now: at("2026-10-09"), calendar: utc)
        let kinds = KeysRules.reminders(i).map(\.kind)
        #expect(Set(kinds) == [.secondCopyMissing, .keyNotBackedUp])
        #expect(KeysRules.reminders(i).allSatisfy { $0.readAt == nil })
    }

    // MARK: Brief and restore guide

    @Test func briefSectionFromKeys() {
        let base = BriefInput(now: at("2026-10-09"), monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                              licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                              worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                              operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []))
        guard case .neverRead = DailyBriefBuilder.keys(base).state else {
            Issue.record("no registry should be never read")
            return
        }
        var withKeys = base
        withKeys.keys = BriefKeysInput(check: input(seededFS(), passphrase: .missing), notGranted: ["~/.velro-keys"])
        let section = DailyBriefBuilder.keys(withKeys)
        #expect(section.state == .items)
        #expect(section.lines.allSatisfy { $0.destination == .keys && $0.kind == .keys })
        #expect(section.lines.first?.severity == .high)
        #expect(section.notes.count == 1)
        let brief = DailyBriefBuilder.build(withKeys, changes: [])
        #expect(brief.sections.map(\.kind) == BriefSourceKind.allCases)
    }

    @Test func restoreCommandsMatchTheArchiveType() {
        let seed = KeysRegistry.seed
        #expect(KeysRestoreGuide.decryptCommand(seed.backup(KeysRegistry.androidBundleID)!)
            == "openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in linumic-android-signing-keys.tgz.enc | tar -xz")
        #expect(KeysRestoreGuide.decryptCommand(seed.backup(KeysRegistry.licenceBundleID)!)
            == "openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in linumic-license-keys.tar.enc | tar -x")
        #expect(KeysRestoreGuide.decryptCommand(seed.backup(KeysRegistry.signingKeysBundleID)!)
            == "openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in linumic-signing-keys-2026-11-03.tgz.enc | tar -xz")
        // The .pfx: OpenSSL's default 10000 iterations, one file, no tar.
        #expect(KeysRestoreGuide.decryptCommand(seed.backup(KeysRegistry.khayatyarPfxBackupID)!)
            == "openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -in KhayatYar-signing.pfx.enc -out KhayatYar-signing.pfx")
        // A record saved before 2026-11-03 has no count: it is a Drive bundle, made with 600000.
        var saved = seed.backups[0]
        saved.pbkdf2Iterations = nil
        #expect(KeysRestoreGuide.decryptCommand(saved) == KeysRestoreGuide.decryptCommand(seed.backups[0]))
        #expect(KeysRestoreGuide.decryptedName("plain") == "plain.decrypted")
        // The passphrase is never put on the command line.
        #expect(seed.backups.allSatisfy { !KeysRestoreGuide.decryptCommand($0).contains("-pass") })
    }
}
