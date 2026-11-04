import Foundation

// MARK: - Keys & Backups (کلیدها و پشتیبان‌ها)
//
// A registry of facts about every signing key, licence key and backup: where each key lives on this Mac, which
// encrypted backup holds it, when that backup was made and verified, and when a restore was last tested. Every fact
// carries its source and the day it was recorded. The registry never holds key material, a passphrase, a hash or any
// part of a key file: only paths, titles, dates, sizes and identifiers (a Google Drive file id is a pointer, not a
// secret).

/// A calendar day, "yyyy-MM-dd", with no time and no time zone. Used for facts known to the day (a backup made on
/// 2026-10-09), so a date never shifts with the device's time zone.
public struct KeyDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// "yyyy-MM-dd", a day that exists in the Gregorian calendar: "2026-02-30" is refused, not read as 2 March (it
    /// would show as that day but sort and count as another).
    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let date = utc.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = utc.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        year = y
        month = m
        day = d
    }

    /// Gregorian, in this device's time zone. A `KeyDay` is a Gregorian day whatever calendar the device shows: the app
    /// runs with the fa_AF locale on the owner's Mac, whose `Calendar.current` is the Persian one, which would turn
    /// 2026-10-19 into 1405-07-27 (or read "2026-10-31" as a Persian year).
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = KeyDay.calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 1970
        month = c.month ?? 1
        day = c.day ?? 1
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Midnight at the start of the day in `calendar`'s time zone.
    public func start(calendar: Calendar = KeyDay.calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// Whole days from this day to `other` (positive when `other` is later).
    public func days(until other: KeyDay) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.dateComponents([.day], from: start(calendar: utc), to: other.start(calendar: utc)).day ?? 0
    }

    public static func < (a: KeyDay, b: KeyDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = KeyDay(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a yyyy-MM-dd day: \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public enum KeyKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// An Android release / upload keystore (.jks, .keystore).
    case androidSigning
    /// A licence signing private key (LNM1, MediFlow and KhayatYar).
    case licenceSigning
    /// An App Store Connect API key (.p8).
    case appStoreConnectAPI
    /// A file that holds a keystore password (e.g. VELRO's .storepass).
    case passwordFile
    /// A plain-text copy of a backup passphrase. Tracked for existence only; it is not a key to back up.
    case passphraseCopy
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .androidSigning: L("Android signing key")
        case .licenceSigning: L("Licence signing key")
        case .appStoreConnectAPI: L("App Store Connect API key")
        case .passwordFile: L("Keystore password file")
        case .passphraseCopy: L("Passphrase copy")
        case .other: L("Other key")
        }
    }

    public var symbol: String {
        switch self {
        case .androidSigning: "key.fill"
        case .licenceSigning: "signature"
        case .appStoreConnectAPI: "applelogo"
        case .passwordFile: "key.viewfinder"
        case .passphraseCopy: "text.badge.xmark"
        case .other: "key"
        }
    }

    /// Whether a backup is expected for this kind. A passphrase copy is not backed up into the bundle it opens.
    public var needsBackup: Bool { self != .passphraseCopy }
}

/// One key (or a group of keys matched by a pattern) on this Mac.
public struct TrackedKey: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var product: String?
    public var kind: KeyKind
    /// Home-relative path ("~/Keys/…"). The last component may hold `*` (e.g. "AuthKey_*.p8") to match a group.
    public var path: String
    /// For a pattern: how many files the source says there are.
    public var expectedCount: Int?
    /// Ids of the `BackupRecord`s that contain this key. Empty means not backed up.
    public var backupIDs: [String]
    public var note: String?
    /// The source says not to delete it (origin unknown, the only copy, …).
    public var doNotDelete: Bool
    public var source: String
    public var recordedOn: KeyDay
    /// The day the file was deliberately deleted. A deleted key is expected to be absent: no "missing" reminder, and a
    /// reminder only if it shows up on this Mac again. Nil for a key that should exist.
    public var deletedOn: KeyDay?
    /// Why and how it was deleted, e.g. "its hash matched the Keychain item first".
    public var deletedNote: String?

    public init(id: String, title: String, product: String? = nil, kind: KeyKind, path: String, expectedCount: Int? = nil,
                backupIDs: [String] = [], note: String? = nil, doNotDelete: Bool = false, source: String, recordedOn: KeyDay,
                deletedOn: KeyDay? = nil, deletedNote: String? = nil) {
        self.id = id
        self.title = title
        self.product = product
        self.kind = kind
        self.path = path
        self.expectedCount = expectedCount
        self.backupIDs = backupIDs
        self.note = note
        self.doNotDelete = doNotDelete
        self.source = source
        self.recordedOn = recordedOn
        self.deletedOn = deletedOn
        self.deletedNote = deletedNote
    }

    public var isDeleted: Bool { deletedOn != nil }

    public var isPattern: Bool { (path as NSString).lastPathComponent.contains("*") }
}

/// A restore (or test decryption) that was actually done, by whom and when.
public struct RestoreTest: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var on: KeyDay
    /// Who did it: "Owner", or the session that did a test decryption.
    public var by: String
    public var note: String?
    public var source: String
    /// When it was entered in this app (nil for seeded facts).
    public var enteredAt: Date?

    public init(id: UUID = UUID(), on: KeyDay, by: String, note: String? = nil, source: String, enteredAt: Date? = nil) {
        self.id = id
        self.on = on
        self.by = by
        self.note = note
        self.source = source
        self.enteredAt = enteredAt
    }
}

/// How the backup file is unpacked after decryption.
public enum BackupArchive: String, Codable, CaseIterable, Sendable {
    /// `.tgz.enc`: decrypt, then `tar -xz`.
    case tarGzip
    /// `.tar.enc`: decrypt, then `tar -x`.
    case tar
    /// One encrypted file (e.g. `.pfx.enc`): decrypt only, to the name without `.enc`.
    case singleFile
}

/// One encrypted backup kept off this Mac.
public struct BackupRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Where it lives, e.g. "Google Drive > Mohem".
    public var location: String
    public var fileName: String
    public var driveFileID: String?
    public var sizeBytes: Int?
    public var archive: BackupArchive
    /// The day the backup file was made (or uploaded).
    public var createdOn: KeyDay
    /// The day the uploaded copy was last checked against the original.
    public var verifiedOn: KeyDay?
    public var verification: String?
    /// e.g. "AES-256-CBC, PBKDF2 600000 iterations".
    public var encryption: String
    /// The PBKDF2 iteration count the file was encrypted with; the restore guide's command uses it. Nil in a record
    /// saved before 2026-11-03: those are the two Drive bundles, both made with 600000 (`KeysRestoreGuide`).
    public var pbkdf2Iterations: Int?
    /// The Keychain service whose existence (never its value) the app checks.
    public var passphraseKeychainService: String?
    /// Where the owner keeps the passphrase, as words ("macOS Keychain", "private Notion page").
    public var passphraseKeptIn: [String]
    public var restoreTests: [RestoreTest]
    public var source: String
    public var recordedOn: KeyDay

    public init(id: String, title: String, location: String, fileName: String, driveFileID: String? = nil, sizeBytes: Int? = nil,
                archive: BackupArchive, createdOn: KeyDay, verifiedOn: KeyDay? = nil, verification: String? = nil,
                encryption: String, pbkdf2Iterations: Int? = nil, passphraseKeychainService: String? = nil, passphraseKeptIn: [String] = [],
                restoreTests: [RestoreTest] = [], source: String, recordedOn: KeyDay) {
        self.id = id
        self.title = title
        self.location = location
        self.fileName = fileName
        self.driveFileID = driveFileID
        self.sizeBytes = sizeBytes
        self.archive = archive
        self.createdOn = createdOn
        self.verifiedOn = verifiedOn
        self.verification = verification
        self.encryption = encryption
        self.pbkdf2Iterations = pbkdf2Iterations
        self.passphraseKeychainService = passphraseKeychainService
        self.passphraseKeptIn = passphraseKeptIn
        self.restoreTests = restoreTests
        self.source = source
        self.recordedOn = recordedOn
    }

    /// The most recent restore test, if any.
    public var lastRestoreTest: RestoreTest? { restoreTests.max { $0.on < $1.on } }

    public var driveURL: URL? {
        driveFileID.flatMap { URL(string: "https://drive.google.com/file/d/\($0)/view") }
    }
}

public enum KeyGapKind: String, Codable, CaseIterable, Sendable {
    /// No second copy of the backups off this Mac.
    case secondCopy
    /// Something is not in any backup.
    case notBackedUp
    /// A key that will exist later must be added to the bundle.
    case futureKey
    case other
}

/// A known gap in the backups. Closing it records the day and how.
public struct KeyGap: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: KeyGapKind
    public var title: String
    public var detail: String?
    public var closedOn: KeyDay?
    public var closedNote: String?
    public var source: String
    public var recordedOn: KeyDay

    public init(id: String, kind: KeyGapKind, title: String, detail: String? = nil, closedOn: KeyDay? = nil, closedNote: String? = nil,
                source: String, recordedOn: KeyDay) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.closedOn = closedOn
        self.closedNote = closedNote
        self.source = source
        self.recordedOn = recordedOn
    }

    public var isOpen: Bool { closedOn == nil }
}

/// The whole registry, stored on this device as `keys-registry.json`.
public struct KeysRegistry: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var keys: [TrackedKey]
    public var backups: [BackupRecord]
    public var gaps: [KeyGap]
    /// When the owner last changed it in the app (nil for the seed).
    public var updatedAt: Date?
    /// The seed revision whose facts this registry already has. Nil: saved from the first seed (2026-10-09).
    public var seedRevision: Int?

    public init(version: Int = KeysRegistry.currentVersion, keys: [TrackedKey] = [], backups: [BackupRecord] = [], gaps: [KeyGap] = [],
                updatedAt: Date? = nil, seedRevision: Int? = nil) {
        self.version = version
        self.keys = keys
        self.backups = backups
        self.gaps = gaps
        self.updatedAt = updatedAt
        self.seedRevision = seedRevision
    }

    public func backup(_ id: String) -> BackupRecord? { backups.first { $0.id == id } }

    /// The most recent restore test across all backups.
    public var lastRestoreTest: (backup: BackupRecord, test: RestoreTest)? {
        backups.compactMap { b in b.lastRestoreTest.map { (b, $0) } }.max { $0.1.on < $1.1.on }
    }

    public var secondCopyGap: KeyGap? { gaps.first { $0.kind == .secondCopy } }

    /// Keychain services of backup passphrases to check for existence.
    public var passphraseServices: [String] {
        var seen = Set<String>()
        return backups.compactMap(\.passphraseKeychainService).filter { seen.insert($0).inserted }
    }

    // MARK: Editing (pure; the App saves the result)

    public mutating func upsert(_ key: TrackedKey, now: Date) {
        if let i = keys.firstIndex(where: { $0.id == key.id }) { keys[i] = key } else { keys.append(key) }
        updatedAt = now
    }

    public mutating func removeKey(_ id: String, now: Date) {
        keys.removeAll { $0.id == id }
        updatedAt = now
    }

    public mutating func upsert(_ backup: BackupRecord, now: Date) {
        if let i = backups.firstIndex(where: { $0.id == backup.id }) { backups[i] = backup } else { backups.append(backup) }
        updatedAt = now
    }

    /// Records a restore test for one backup. Returns false when the backup does not exist or the day is in the future.
    @discardableResult
    public mutating func recordRestoreTest(backupID: String, _ test: RestoreTest, now: Date, calendar: Calendar = KeyDay.calendar) -> Bool {
        guard let i = backups.firstIndex(where: { $0.id == backupID }), test.on <= KeyDay(now, calendar: calendar) else { return false }
        backups[i].restoreTests.append(test)
        updatedAt = now
        return true
    }

    /// Closes a gap with the day and how. Returns false for an unknown gap or a future day.
    @discardableResult
    public mutating func closeGap(_ id: String, on day: KeyDay, note: String?, now: Date, calendar: Calendar = KeyDay.calendar) -> Bool {
        guard let i = gaps.firstIndex(where: { $0.id == id }), day <= KeyDay(now, calendar: calendar) else { return false }
        gaps[i].closedOn = day
        gaps[i].closedNote = note
        updatedAt = now
        return true
    }

    public mutating func reopenGap(_ id: String, now: Date) {
        guard let i = gaps.firstIndex(where: { $0.id == id }) else { return }
        gaps[i].closedOn = nil
        gaps[i].closedNote = nil
        updatedAt = now
    }

    public mutating func upsert(_ gap: KeyGap, now: Date) {
        if let i = gaps.firstIndex(where: { $0.id == gap.id }) { gaps[i] = gap } else { gaps.append(gap) }
        updatedAt = now
    }
}

// MARK: - Seed (verified facts, 2026-10-09; corrected 2026-10-18; the backups of 2026-11-03)

public extension KeysRegistry {
    static let androidBundleID = "android-signing-keys"
    static let licenceBundleID = "licence-keys"
    /// The bundle of all signing keys on the two offline drives (2026-11-03).
    static let signingKeysBundleID = "signing-keys-2026-11-03"
    /// The encrypted KhayatYar Windows .pfx on the two offline drives (2026-10-23, second copy 2026-11-03).
    static let khayatyarPfxBackupID = "khayatyar-windows-pfx"
    static let passphraseService = "Linumic license backup passphrase"
    /// Where the backup passphrase is kept (session record 2026-10-09). The plain-text file is not one of them any more.
    static let passphraseLocations = ["macOS Keychain", "Private Notion page", "Paper"]
    static let deletedPassphraseNote = "Deleted on purpose on 2026-10-09 after its hash matched the Keychain item “Linumic license backup passphrase”. The passphrase is kept in that Keychain item, the owner's private Notion page and on paper."
    /// The seed's revision. 1: the facts of 2026-10-09. 2: the corrections of 2026-10-18 (the VELRO Play key; the
    /// KhayatYar, Talar and Namazia keys; the NerkhTimes, DukanPro and disk-image gaps). 3: the backups of 2026-11-03
    /// (all signing keys on two offline drives; the KhayatYar Windows .pfx) and the gaps they closed.
    static let currentSeedRevision = 3
    /// iCloud Drive > importand, where the owner keeps several keystores.
    static let iCloudImportand = "~/Library/Mobile Documents/com~apple~CloudDocs/importand"

    /// Keys and gaps that revision 2 added.
    static let revision2AddedKeyIDs: Set<String> = ["velro-play-upload", "khayatyar-release", "talar-release", "namazia-release"]
    static let revision2AddedGapIDs: Set<String> = ["nerkhtimes-upload-key", "dukanpro-upload-key", "icloud-dmg-unverified"]
    /// The first seed's text of the entries revision 2 corrected. A saved entry is corrected only while it still holds
    /// this text, so an entry the owner edited is left alone.
    static let revision1KeyNotes: [String: String] = [
        "velro-release": "Velro/mobile/keystore.properties points to this path.",
        "velro-from-downloads": "Differs from the main VELRO key; origin unknown. Do not delete until it is known.",
    ]
    static let revision1GapDetails: [String: String] = [
        "future-keys": "Any new key (the Talar release key is not created yet) must go into the encrypted bundle.",
    ]

    /// Backups that revision 3 added.
    static let revision3AddedBackupIDs: Set<String> = [signingKeysBundleID, khayatyarPfxBackupID]
    /// Gaps the bundle of 2026-11-03 closed. Revision 3 closes them only while they are open, so one the owner closed
    /// keeps his day and note.
    static let revision3ClosedGapIDs: Set<String> = ["second-copy", "future-keys"]
    /// The earlier seeds' text of the entries revision 3 corrected (the App Store Connect keys are in the new bundle).
    static let revision2KeyNotes: [String: String] = [
        "asc-api-keys": "Not in any backup yet.",
    ]
    static let revision2GapDetails: [String: String] = [
        "asc-notary-not-backed-up": "The 5 AuthKey .p8 files and the notarytool keychain profile are in no backup.",
    ]

    /// Applies facts recorded after a registry was first saved, so a `keys-registry.json` written from an older seed
    /// does not keep warning about them, or keep a wrong fact: a key the seed records as deleted is marked deleted (if
    /// the saved one isn't), backups that use the seed's passphrase item list every place the passphrase is kept, and
    /// a registry from before revision 2 or 3 gets that revision's additions and corrections once. Returns true when
    /// something changed. It never removes anything the owner added.
    @discardableResult
    mutating func applySeedCorrections() -> Bool {
        let seed = KeysRegistry.seed
        var changed = false
        for s in seed.keys where s.deletedOn != nil {
            guard let i = keys.firstIndex(where: { $0.id == s.id }), keys[i].deletedOn == nil else { continue }
            keys[i].deletedOn = s.deletedOn
            keys[i].deletedNote = s.deletedNote
            keys[i].note = s.note
            keys[i].source = s.source
            changed = true
        }
        for i in backups.indices where backups[i].passphraseKeychainService == KeysRegistry.passphraseService {
            for place in KeysRegistry.passphraseLocations where !backups[i].passphraseKeptIn.contains(place) {
                backups[i].passphraseKeptIn.append(place)
                changed = true
            }
        }
        if (seedRevision ?? 1) < 2 {
            applyRevision2(from: seed)
            changed = true
        }
        if (seedRevision ?? 1) < 3 {
            applyRevision3(from: seed)
            changed = true
        }
        return changed
    }

    /// Revision 2 (2026-10-18). Added keys and gaps are added once: one the owner removes afterwards stays removed,
    /// because the registry then records revision 2. A corrected entry keeps its path, backups and closing.
    private mutating func applyRevision2(from seed: KeysRegistry) {
        for s in seed.keys where KeysRegistry.revision2AddedKeyIDs.contains(s.id) && !keys.contains(where: { $0.id == s.id }) {
            keys.append(s)
        }
        for (id, oldNote) in KeysRegistry.revision1KeyNotes {
            guard let i = keys.firstIndex(where: { $0.id == id }), keys[i].note == oldNote,
                  let s = seed.keys.first(where: { $0.id == id }) else { continue }
            keys[i].title = s.title
            keys[i].note = s.note
            keys[i].doNotDelete = s.doNotDelete
            keys[i].source = s.source
            keys[i].recordedOn = s.recordedOn
        }
        for g in seed.gaps where KeysRegistry.revision2AddedGapIDs.contains(g.id) && !gaps.contains(where: { $0.id == g.id }) {
            gaps.append(g)
        }
        for (id, oldDetail) in KeysRegistry.revision1GapDetails {
            guard let i = gaps.firstIndex(where: { $0.id == id }), gaps[i].detail == oldDetail,
                  let g = seed.gaps.first(where: { $0.id == id }) else { continue }
            gaps[i].title = g.title
            gaps[i].detail = g.detail
            gaps[i].source = g.source
            gaps[i].recordedOn = g.recordedOn
        }
        seedRevision = 2
    }

    /// Revision 3 (2026-11-03). The two backups are added once, like revision 2's keys. A saved key the seed lists in
    /// a new backup gets that backup among its own; the gaps the new bundle closed are closed while still open; the App
    /// Store Connect key note and gap are corrected only while they hold the earlier text; the Drive bundles get their
    /// iteration count.
    private mutating func applyRevision3(from seed: KeysRegistry) {
        for b in seed.backups where KeysRegistry.revision3AddedBackupIDs.contains(b.id) && !backups.contains(where: { $0.id == b.id }) {
            backups.append(b)
        }
        for i in backups.indices where backups[i].pbkdf2Iterations == nil {
            backups[i].pbkdf2Iterations = seed.backup(backups[i].id)?.pbkdf2Iterations
        }
        for s in seed.keys {
            guard let i = keys.firstIndex(where: { $0.id == s.id }) else { continue }
            for id in s.backupIDs where KeysRegistry.revision3AddedBackupIDs.contains(id) && !keys[i].backupIDs.contains(id) {
                keys[i].backupIDs.append(id)
            }
        }
        for (id, oldNote) in KeysRegistry.revision2KeyNotes {
            guard let i = keys.firstIndex(where: { $0.id == id }), keys[i].note == oldNote,
                  let s = seed.keys.first(where: { $0.id == id }) else { continue }
            keys[i].note = s.note
            keys[i].source = s.source
            keys[i].recordedOn = s.recordedOn
        }
        for id in KeysRegistry.revision3ClosedGapIDs {
            guard let i = gaps.firstIndex(where: { $0.id == id }), gaps[i].isOpen,
                  let g = seed.gaps.first(where: { $0.id == id }) else { continue }
            gaps[i].closedOn = g.closedOn
            gaps[i].closedNote = g.closedNote
        }
        for (id, oldDetail) in KeysRegistry.revision2GapDetails {
            guard let i = gaps.firstIndex(where: { $0.id == id }), gaps[i].detail == oldDetail,
                  let g = seed.gaps.first(where: { $0.id == id }) else { continue }
            gaps[i].title = g.title
            gaps[i].detail = g.detail
            gaps[i].source = g.source
            gaps[i].recordedOn = g.recordedOn
        }
        seedRevision = 3
    }

    /// The facts as recorded on 2026-10-09, corrected on 2026-10-18 and extended on 2026-11-03. Sources:
    /// `~/Keys/README.md` (written 2026-10-09, corrected 2026-10-18), the licensing map (`Linumic/licensing/MAP.md`),
    /// the session records of the backups and of VELRO's Play key, a check of file names, sizes and dates on
    /// 2026-10-18 (no key opened), and the restore-test record of 2026-11-03 (file names only, no key opened here).
    static var seed: KeysRegistry {
        let d9 = KeyDay("2026-10-09")!
        let d8 = KeyDay("2026-10-08")!
        let d18 = KeyDay("2026-10-18")!
        let d23 = KeyDay("2026-10-23")!
        let d3 = KeyDay("2026-11-03")!
        let readme = "~/Keys/README.md (2026-10-09)"
        let readme18 = "~/Keys/README.md (corrected 2026-10-18)"
        let session = "Session record 2026-10-09"
        let velroSession = "Session record 2026-10-17 (velro-play-launch.md)"
        let audit = "Audit of 2026-10-18 (Projects/Multiplatform/NEXT-ACTIONS-2026-10-19.md)"
        let check18 = "File names, sizes and dates on this Mac, 2026-10-18"
        let map = "Linumic/licensing/MAP.md (2026-10-08)"
        let keysTest = "~/Documents/Admin/Backup-Home-Day-2026-11-03/restore-test-keys-2026-11-03.txt (2026-11-03)"
        let pfxSession = "Session records 2026-10-23 and 2026-11-03 (the .pfx backup, its SSD copy and its restore test)"
        let android = androidBundleID
        let licence = licenceBundleID
        let signing = signingKeysBundleID
        let icloud = iCloudImportand

        let keys: [TrackedKey] = [
            TrackedKey(id: "worktrack-release", title: "WorkTrack upload key", product: "WorkTrack", kind: .androidSigning,
                       path: "~/Projects/Multiplatform/WorkTrack/worktrack-release.jks", backupIDs: [android, signing],
                       note: "~/.gradle/gradle.properties points to this path.", source: readme, recordedOn: d9),
            TrackedKey(id: "worktrack-release-copy", title: "WorkTrack upload key (backup copy)", product: "WorkTrack", kind: .androidSigning,
                       path: "~/Keys/worktrack/worktrack-release-BACKUP-copy.jks", backupIDs: [android, signing],
                       note: "Identical to the WorkTrack key in the repository, which is in the bundle.", source: readme, recordedOn: d9),
            TrackedKey(id: "velro-play-upload", title: "VELRO Play upload key", product: "VELRO", kind: .androidSigning,
                       path: "\(icloud)/velro-release.jks", backupIDs: [android, signing],
                       note: "The key Google Play expects (iCloud Drive > importand, 2,742 bytes, 2026-08-31). Velro/mobile/keystore.properties points to it since 2026-10-17. In the bundle as the copy from Downloads: same name and size, the same file according to the audit.",
                       doNotDelete: true, source: "\(velroSession); \(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "velro-release", title: "Other VELRO key (not the Play key)", product: "VELRO", kind: .androidSigning,
                       path: "~/.velro-keys/velro-release.jks", backupIDs: [android, signing],
                       note: "Not the key Google Play expects: its password does not match and bundleRelease failed with it. Origin unknown; do not delete until it is known.",
                       doNotDelete: true, source: "\(readme18); \(velroSession)", recordedOn: d18),
            TrackedKey(id: "velro-storepass", title: "VELRO keystore password file", product: "VELRO", kind: .passwordFile,
                       path: "~/.velro-keys/.storepass", backupIDs: [android, signing],
                       note: "Holds the keystore password as plain text. The app reads its date and size only.", source: readme, recordedOn: d9),
            TrackedKey(id: "velro-from-downloads", title: "VELRO Play upload key (copy from Downloads)", product: "VELRO", kind: .androidSigning,
                       path: "~/Keys/velro/velro-release-FROM-DOWNLOADS-2026-10-03-differs-from-.velro-keys.jks", backupIDs: [android, signing],
                       note: "Same name and size (2,742 bytes) as the VELRO Play upload key in iCloud Drive > importand; the same file according to the audit. It differs from the key in ~/.velro-keys, which is not the Play key. Do not delete.",
                       doNotDelete: true, source: "\(readme18); \(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "safebeauty-release", title: "SafeBeauty signing key", product: "SafeBeauty", kind: .androidSigning,
                       path: "~/Projects/Multiplatform/Safe beauty/app/safebeauty-release.jks", backupIDs: [android, signing],
                       source: readme, recordedOn: d9),
            TrackedKey(id: "soder-hakem-release", title: "SODER-HAKEM signing key", product: "SODER-HAKEM", kind: .androidSigning,
                       path: "~/Projects/Android/SODER-HAKEM/soder-hakim-release.jks", backupIDs: [android, signing],
                       source: readme, recordedOn: d9),
            TrackedKey(id: "khayatyar-release", title: "KhayatYar signing key", product: "KhayatYar", kind: .androidSigning,
                       path: "~/Documents/Khayatyar.jks", backupIDs: [signing],
                       note: "Alias khayatyar; signs 1.8.0 and later. The repository's signing guide names ~/Khayatyar.jks, ~/Documents/Secure/Khayatyar.jks and ~/Documents/Secure/afghanjama-keystore.properties; none of them exists. The audit found no other recorded place for the keystore passwords.",
                       doNotDelete: true, source: "AfghanJama tools/android-signing/README.md (2026-09-20); \(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "talar-release", title: "Talar signing key", product: "Talar", kind: .androidSigning,
                       path: "\(icloud)/Untitled.jks", backupIDs: [signing],
                       note: "Untitled.jks in iCloud Drive > importand. The audit identifies it as alias talar2000, the key of the public APK v1.0.0; not re-checked with keytool. Do not create a new key.",
                       doNotDelete: true, source: "\(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "namazia-release", title: "Namazia signing key", product: "Namazia", kind: .androidSigning,
                       path: "\(icloud)/Namazia.jks", backupIDs: [signing],
                       note: "The only Namazia key file on this Mac. The Namazia repository has no Gradle signing config, so whether it is the Play upload key is not verified.",
                       doNotDelete: true, source: check18, recordedOn: d18),
            TrackedKey(id: "mediflow-licence", title: "MediFlow licence signing key", product: "MediFlow", kind: .licenceSigning,
                       path: "~/.linumic/license-keys/mediflow-private.pem", backupIDs: [licence, signing], source: map, recordedOn: d8),
            TrackedKey(id: "khayatyar-licence", title: "KhayatYar licence signing key", product: "KhayatYar", kind: .licenceSigning,
                       path: "~/.linumic/license-keys/khayatyar-private.pem", backupIDs: [licence, signing], source: map, recordedOn: d8),
            TrackedKey(id: "asc-api-keys", title: "App Store Connect API keys", kind: .appStoreConnectAPI,
                       path: "~/.appstoreconnect/private_keys/AuthKey_*.p8", expectedCount: 5, backupIDs: [signing],
                       note: "In the signing-keys bundle of 2026-11-03 (5 files).", source: "\(readme); \(keysTest)", recordedOn: d3),
            // Deleted on purpose on 2026-10-09 after its hash matched the Keychain item. Kept in the registry so the
            // deletion is on record; it is expected to be absent.
            TrackedKey(id: "licence-passphrase-file", title: "Backup passphrase as a plain-text file", kind: .passphraseCopy,
                       path: "~/.linumic/license-backup-passphrase.txt",
                       note: "Was a plain-text copy of the backup passphrase on this Mac. The app never opened it.",
                       source: "\(map); \(session)", recordedOn: d8, deletedOn: d9,
                       deletedNote: deletedPassphraseNote),
        ]

        let backups: [BackupRecord] = [
            BackupRecord(id: android, title: "Android signing keys", location: "Google Drive > Mohem",
                         fileName: "linumic-android-signing-keys.tgz.enc", driveFileID: "1mBSWqt_JwvEU7BMSFcJ-FJucPGJeuS4q",
                         sizeBytes: 22_336, archive: .tarGzip, createdOn: d9, verifiedOn: d9,
                         verification: "Downloaded from Drive and compared byte-identical with the original; test-decrypted.",
                         encryption: "AES-256-CBC, PBKDF2 600000 iterations", pbkdf2Iterations: 600_000, passphraseKeychainService: passphraseService,
                         passphraseKeptIn: passphraseLocations,
                         restoreTests: [
                             RestoreTest(id: UUID(uuidString: "5B0E7C2A-4D1F-4C6E-9A3B-2F8D1E0A9C01")!, on: d9, by: "Owner",
                                         note: "Downloaded and restored by the owner himself.", source: session),
                         ],
                         source: "\(readme); \(session)", recordedOn: d9),
            BackupRecord(id: licence, title: "Licence signing keys", location: "Google Drive > Mohem",
                         fileName: "linumic-license-keys.tar.enc", driveFileID: "13YZuIKfJrlgZFH98_DeqqBUb_ZXhrd5b",
                         archive: .tar, createdOn: d8, verifiedOn: d9,
                         verification: "Verified on 2026-10-08 and 2026-10-09: byte-identical with the original and decryptable.",
                         encryption: "AES-256-CBC, PBKDF2 600000 iterations", pbkdf2Iterations: 600_000, passphraseKeychainService: passphraseService,
                         passphraseKeptIn: passphraseLocations,
                         restoreTests: [
                             RestoreTest(id: UUID(uuidString: "5B0E7C2A-4D1F-4C6E-9A3B-2F8D1E0A9C02")!, on: d8, by: "Claude session (test decryption)",
                                         note: "Test decryption when the backup was made. No restore by the owner is recorded.",
                                         source: "Session record 2026-10-08"),
                         ],
                         source: "\(map); session records 2026-10-08 and 2026-10-09", recordedOn: d9),
            // Revision 3. File names and paths of what is inside stay out of this public repository: counts and
            // products only.
            BackupRecord(id: signing, title: "All signing keys, second and third copy",
                         location: "USB flash drive “BACKUP” and external SSD “Projects-Archive” (offline, not on this Mac)",
                         fileName: "linumic-signing-keys-2026-11-03.tgz.enc", sizeBytes: 61_472, archive: .tarGzip,
                         createdOn: d3, verifiedOn: d3,
                         verification: "49 files, among them the Android keystores of KhayatYar, Namazia, Afghan jama, WorkTrack, VELRO, SafeBeauty and SODER-HAKEM, the file this registry tracks as the Talar key, the KhayatYar and MediFlow licence private keys, the App Store Connect API keys and the keystore.properties files. The copies on the two drives are byte-identical. Not in it: the notarytool profile (a Keychain item) and the KhayatYar Windows .pfx (its own backup). The NerkhTimes and DukanPro keys are not on this Mac.",
                         encryption: "AES-256-CBC, PBKDF2 600000 iterations", pbkdf2Iterations: 600_000, passphraseKeychainService: passphraseService,
                         passphraseKeptIn: passphraseLocations,
                         restoreTests: [
                             RestoreTest(id: UUID(uuidString: "5B0E7C2A-4D1F-4C6E-9A3B-2F8D1E0A9C03")!, on: d3, by: "Owner",
                                         note: "Decrypted from both copies (flash drive and SSD): 49 of 49 files identical to the originals.",
                                         source: keysTest),
                         ],
                         source: keysTest, recordedOn: d3),
            BackupRecord(id: khayatyarPfxBackupID, title: "KhayatYar Windows signing key (encrypted .pfx)",
                         location: "USB flash drive “BACKUP” and external SSD “Projects-Archive” (offline, not on this Mac)",
                         fileName: "KhayatYar-signing.pfx.enc", sizeBytes: 3_552, archive: .singleFile,
                         createdOn: d23, verifiedOn: d3,
                         verification: "Made on the flash drive on 2026-10-23; an identical second copy went on the SSD on 2026-11-03. The original .pfx exists only on the owner's Windows PC. Encrypted with PBKDF2 at OpenSSL's default of 10000 iterations, not the 600000 of the other bundles, so its restore command differs (-iter 10000).",
                         encryption: "AES-256-CBC, PBKDF2 10000 iterations (the OpenSSL default)", pbkdf2Iterations: 10_000,
                         passphraseKeychainService: passphraseService, passphraseKeptIn: passphraseLocations,
                         restoreTests: [
                             RestoreTest(id: UUID(uuidString: "5B0E7C2A-4D1F-4C6E-9A3B-2F8D1E0A9C04")!, on: d3, by: "Owner",
                                         note: "Decrypted with the backup passphrase; the SHA-256 of the result matched the original .pfx.",
                                         source: pfxSession),
                         ],
                         source: pfxSession, recordedOn: d3),
        ]

        let gaps: [KeyGap] = [
            KeyGap(id: "second-copy", kind: .secondCopy, title: "No second copy off this Mac",
                   detail: "Both backups are only in Google Drive. Keep a second copy elsewhere, e.g. a USB drive at home.",
                   closedOn: d3,
                   closedNote: "Second and third copy: linumic-signing-keys-2026-11-03.tgz.enc on two offline drives, the USB flash drive “BACKUP” and the external SSD “Projects-Archive”, byte-identical and restore-tested from both on 2026-11-03 (restore-test-keys-2026-11-03.txt).",
                   source: readme, recordedOn: d9),
            KeyGap(id: "asc-notary-not-backed-up", kind: .notBackedUp, title: "The notarytool profile is not backed up",
                   detail: "The notarytool profile is a Keychain item, not a file, and is in no backup. The 5 App Store Connect .p8 files are in the signing-keys bundle of 2026-11-03.",
                   source: "\(readme); \(keysTest)", recordedOn: d3),
            KeyGap(id: "future-keys", kind: .futureKey, title: "New keys must be added to the bundle",
                   detail: "The KhayatYar, Talar and Namazia keys and VELRO's keystore.properties of 2026-10-17 are not in the encrypted bundle. Rebuild it with them.",
                   closedOn: d3,
                   closedNote: "All four are in linumic-signing-keys-2026-11-03.tgz.enc (for Talar, the file this registry tracks as its key), according to the file list of its restore test on 2026-11-03.",
                   source: readme18, recordedOn: d18),
            KeyGap(id: "nerkhtimes-upload-key", kind: .other, title: "NerkhTimes upload key is not on this Mac",
                   detail: "No NerkhTimes .jks or .keystore file was found by name. A keystore.jks seen in Downloads on 2026-09-07 is gone; it may be in Signing-Keys-Backup-2026-09-22.dmg (not verified).",
                   source: "\(readme18); \(audit)", recordedOn: d18),
            KeyGap(id: "dukanpro-upload-key", kind: .other, title: "DukanPro upload key is no longer on this Mac",
                   detail: "~/dukanpro-upload.jks, named in DukanPro's release guide, is not on this Mac. Release APKs dated 2026-09-18 exist, and release builds never fall back to the debug key.",
                   source: "DukanPro docs/release-android.md; \(check18)", recordedOn: d18),
            KeyGap(id: "icloud-dmg-unverified", kind: .other, title: "Disk image backup not verified",
                   detail: "Signing-Keys-Backup-2026-09-22.dmg in iCloud Drive (52,551,168 bytes, made 2026-09-22) has not been opened: what it holds and whether it has a password are unknown. Open it once and record its contents.",
                   source: check18, recordedOn: d18),
        ]
        return KeysRegistry(keys: keys, backups: backups, gaps: gaps, seedRevision: currentSeedRevision)
    }
}

// MARK: - Store

/// `keys-registry.json` next to the inventory in the app's container. Holds facts only, no key material.
public struct KeysRegistryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "keys-registry.json")
    }

    /// The saved registry; the seed when nothing is saved yet. A file that can't be decoded returns nil, so the
    /// caller never overwrites it with the seed by accident.
    public func load() -> KeysRegistry? {
        guard let data = try? Data(contentsOf: fileURL) else { return .seed }
        guard var registry = try? Self.decoder.decode(KeysRegistry.self, from: data) else { return nil }
        registry.applySeedCorrections()
        return registry
    }

    public func save(_ registry: KeysRegistry) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(registry).write(to: fileURL, options: .atomic)
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
}
