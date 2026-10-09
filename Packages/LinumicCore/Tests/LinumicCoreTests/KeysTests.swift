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

/// Every seeded key present, all modified before the backups.
private func seededFS(changing: [String: Date] = [:], removing: Set<String> = [], adding: [String: Date] = [:]) -> FakeFS {
    var files: [String: Date] = [:]
    for key in KeysRegistry.seed.keys {
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

@Suite("Keys & Backups")
struct KeysTests {
    // MARK: Registry

    @Test func seedHoldsTheVerifiedFacts() throws {
        let seed = KeysRegistry.seed
        #expect(seed.keys.count == 11)
        #expect(seed.backups.map(\.id) == [KeysRegistry.androidBundleID, KeysRegistry.licenceBundleID])
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
        #expect(seed.secondCopyGap?.isOpen == true)
        // Every fact carries a source.
        #expect(seed.keys.allSatisfy { !$0.source.isEmpty })
        #expect(seed.backups.allSatisfy { !$0.source.isEmpty && $0.restoreTests.allSatisfy { !$0.source.isEmpty } })
        #expect(seed.gaps.allSatisfy { !$0.source.isEmpty })
        #expect(seed.keys.first { $0.id == "velro-from-downloads" }?.doNotDelete == true)
        #expect(seed.keys.first { $0.id == "asc-api-keys" }?.backupIDs.isEmpty == true)
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
        #expect(reg.keys.count == 11)
        reg.removeKey(key.id, now: now)
        #expect(reg.keys.count == 10)
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
        let reminders = KeysRules.reminders(input(seededFS()))
        let kinds = Set(reminders.map(\.kind))
        // Known open gaps only: no second copy, ASC keys not backed up. Restore tests are recent.
        #expect(kinds == [.secondCopyMissing, .keyNotBackedUp])
        #expect(reminders.filter { $0.kind == .keyNotBackedUp }.map(\.keyID) == ["asc-api-keys"])
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
        // Same day as the backup: can't be told apart, not flagged. A later day: flagged against the newest backup.
        let fs = seededFS(changing: [wt: at("2026-10-09", hour: 23), pem: at("2026-10-12")])
        let reminders = KeysRules.reminders(input(fs, now: "2026-10-12"))
        let changed = reminders.filter { $0.kind == .keyChangedAfterBackup }
        #expect(changed.map(\.keyID) == ["mediflow-licence"])
        #expect(changed.first?.backupID == KeysRegistry.licenceBundleID)
        #expect(changed.first?.severity == .high)
        let key = KeysRegistry.seed.keys.first { $0.id == "mediflow-licence" }!
        let state = KeysRules.backupState(key, registry: .seed, result: KeyChecker.check(key, home: home, access: .all, fs: fs), calendar: utc)
        #expect(state == .changedAfterBackup(backupID: KeysRegistry.licenceBundleID, modified: day("2026-10-12")))
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

        var reg = KeysRegistry.seed
        reg.closeGap("second-copy", on: day("2026-10-09"), note: "USB at home", now: at("2026-10-09"), calendar: utc)
        #expect(!KeysRules.reminders(input(fs, registry: reg)).contains { $0.kind == .secondCopyMissing })
    }

    @Test func registryOnlyRemindersWithoutLocalChecks() {
        // iOS: no checks at all. Only the registry facts count.
        let i = KeysCheckInput(registry: .seed, now: at("2026-10-09"), calendar: utc)
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
        // The passphrase is never put on the command line.
        #expect(!KeysRestoreGuide.decryptCommand(seed.backups[0]).contains("-pass"))
    }
}
