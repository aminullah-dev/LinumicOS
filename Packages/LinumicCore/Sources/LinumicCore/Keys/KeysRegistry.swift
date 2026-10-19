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

    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
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
    /// The Keychain service whose existence (never its value) the app checks.
    public var passphraseKeychainService: String?
    /// Where the owner keeps the passphrase, as words ("macOS Keychain", "private Notion page").
    public var passphraseKeptIn: [String]
    public var restoreTests: [RestoreTest]
    public var source: String
    public var recordedOn: KeyDay

    public init(id: String, title: String, location: String, fileName: String, driveFileID: String? = nil, sizeBytes: Int? = nil,
                archive: BackupArchive, createdOn: KeyDay, verifiedOn: KeyDay? = nil, verification: String? = nil,
                encryption: String, passphraseKeychainService: String? = nil, passphraseKeptIn: [String] = [],
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

// MARK: - Seed (verified facts, 2026-10-09; corrected 2026-10-18)

public extension KeysRegistry {
    static let androidBundleID = "android-signing-keys"
    static let licenceBundleID = "licence-keys"
    static let passphraseService = "Linumic license backup passphrase"
    /// Where the backup passphrase is kept (session record 2026-10-09). The plain-text file is not one of them any more.
    static let passphraseLocations = ["macOS Keychain", "Private Notion page", "Paper"]
    static let deletedPassphraseNote = "Deleted on purpose on 2026-10-09 after its hash matched the Keychain item “Linumic license backup passphrase”. The passphrase is kept in that Keychain item, the owner's private Notion page and on paper."
    /// The seed's revision. 1: the facts of 2026-10-09. 2: the corrections of 2026-10-18 (the VELRO Play key; the
    /// KhayatYar, Talar and Namazia keys; the NerkhTimes, DukanPro and disk-image gaps).
    static let currentSeedRevision = 2
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

    /// Applies facts recorded after a registry was first saved, so a `keys-registry.json` written from an older seed
    /// does not keep warning about them, or keep a wrong fact: a key the seed records as deleted is marked deleted (if
    /// the saved one isn't), backups that use the seed's passphrase item list every place the passphrase is kept, and
    /// a registry from before revision 2 gets that revision's keys, gaps and corrections once. Returns true when
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

    /// The facts as recorded on 2026-10-09 and corrected on 2026-10-18. Sources: `~/Keys/README.md` (written
    /// 2026-10-09, corrected 2026-10-18), the licensing map (`Linumic/licensing/MAP.md`), the session records of the
    /// backups and of VELRO's Play key, and a check of file names, sizes and dates on 2026-10-18 (no key opened).
    static var seed: KeysRegistry {
        let d9 = KeyDay("2026-10-09")!
        let d8 = KeyDay("2026-10-08")!
        let d18 = KeyDay("2026-10-18")!
        let readme = "~/Keys/README.md (2026-10-09)"
        let readme18 = "~/Keys/README.md (corrected 2026-10-18)"
        let session = "Session record 2026-10-09"
        let velroSession = "Session record 2026-10-17 (velro-play-launch.md)"
        let audit = "Audit of 2026-10-18 (Projects/Multiplatform/NEXT-ACTIONS-2026-10-19.md)"
        let check18 = "File names, sizes and dates on this Mac, 2026-10-18"
        let map = "Linumic/licensing/MAP.md (2026-10-08)"
        let android = androidBundleID
        let licence = licenceBundleID
        let icloud = iCloudImportand

        let keys: [TrackedKey] = [
            TrackedKey(id: "worktrack-release", title: "WorkTrack upload key", product: "WorkTrack", kind: .androidSigning,
                       path: "~/Projects/Multiplatform/WorkTrack/worktrack-release.jks", backupIDs: [android],
                       note: "~/.gradle/gradle.properties points to this path.", source: readme, recordedOn: d9),
            TrackedKey(id: "worktrack-release-copy", title: "WorkTrack upload key (backup copy)", product: "WorkTrack", kind: .androidSigning,
                       path: "~/Keys/worktrack/worktrack-release-BACKUP-copy.jks", backupIDs: [android],
                       note: "Identical to the WorkTrack key in the repository, which is in the bundle.", source: readme, recordedOn: d9),
            TrackedKey(id: "velro-play-upload", title: "VELRO Play upload key", product: "VELRO", kind: .androidSigning,
                       path: "\(icloud)/velro-release.jks", backupIDs: [android],
                       note: "The key Google Play expects (iCloud Drive > importand, 2,742 bytes, 2026-08-31). Velro/mobile/keystore.properties points to it since 2026-10-17. In the bundle as the copy from Downloads: same name and size, the same file according to the audit.",
                       doNotDelete: true, source: "\(velroSession); \(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "velro-release", title: "Other VELRO key (not the Play key)", product: "VELRO", kind: .androidSigning,
                       path: "~/.velro-keys/velro-release.jks", backupIDs: [android],
                       note: "Not the key Google Play expects: its password does not match and bundleRelease failed with it. Origin unknown; do not delete until it is known.",
                       doNotDelete: true, source: "\(readme18); \(velroSession)", recordedOn: d18),
            TrackedKey(id: "velro-storepass", title: "VELRO keystore password file", product: "VELRO", kind: .passwordFile,
                       path: "~/.velro-keys/.storepass", backupIDs: [android],
                       note: "Holds the keystore password as plain text. The app reads its date and size only.", source: readme, recordedOn: d9),
            TrackedKey(id: "velro-from-downloads", title: "VELRO Play upload key (copy from Downloads)", product: "VELRO", kind: .androidSigning,
                       path: "~/Keys/velro/velro-release-FROM-DOWNLOADS-2026-10-03-differs-from-.velro-keys.jks", backupIDs: [android],
                       note: "Same name and size (2,742 bytes) as the VELRO Play upload key in iCloud Drive > importand; the same file according to the audit. It differs from the key in ~/.velro-keys, which is not the Play key. Do not delete.",
                       doNotDelete: true, source: "\(readme18); \(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "safebeauty-release", title: "SafeBeauty signing key", product: "SafeBeauty", kind: .androidSigning,
                       path: "~/Projects/Multiplatform/Safe beauty/app/safebeauty-release.jks", backupIDs: [android],
                       source: readme, recordedOn: d9),
            TrackedKey(id: "soder-hakem-release", title: "SODER-HAKEM signing key", product: "SODER-HAKEM", kind: .androidSigning,
                       path: "~/Projects/Android/SODER-HAKEM/soder-hakim-release.jks", backupIDs: [android],
                       source: readme, recordedOn: d9),
            TrackedKey(id: "khayatyar-release", title: "KhayatYar signing key", product: "KhayatYar", kind: .androidSigning,
                       path: "~/Documents/Khayatyar.jks",
                       note: "Alias khayatyar; signs 1.8.0 and later. The repository's signing guide names ~/Khayatyar.jks, ~/Documents/Secure/Khayatyar.jks and ~/Documents/Secure/afghanjama-keystore.properties; none of them exists. The audit found no other recorded place for the keystore passwords.",
                       doNotDelete: true, source: "AfghanJama tools/android-signing/README.md (2026-09-20); \(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "talar-release", title: "Talar signing key", product: "Talar", kind: .androidSigning,
                       path: "\(icloud)/Untitled.jks",
                       note: "Untitled.jks in iCloud Drive > importand. The audit identifies it as alias talar2000, the key of the public APK v1.0.0; not re-checked with keytool. Do not create a new key.",
                       doNotDelete: true, source: "\(audit); \(check18)", recordedOn: d18),
            TrackedKey(id: "namazia-release", title: "Namazia signing key", product: "Namazia", kind: .androidSigning,
                       path: "\(icloud)/Namazia.jks",
                       note: "The only Namazia key file on this Mac. The Namazia repository has no Gradle signing config, so whether it is the Play upload key is not verified.",
                       doNotDelete: true, source: check18, recordedOn: d18),
            TrackedKey(id: "mediflow-licence", title: "MediFlow licence signing key", product: "MediFlow", kind: .licenceSigning,
                       path: "~/.linumic/license-keys/mediflow-private.pem", backupIDs: [licence], source: map, recordedOn: d8),
            TrackedKey(id: "khayatyar-licence", title: "KhayatYar licence signing key", product: "KhayatYar", kind: .licenceSigning,
                       path: "~/.linumic/license-keys/khayatyar-private.pem", backupIDs: [licence], source: map, recordedOn: d8),
            TrackedKey(id: "asc-api-keys", title: "App Store Connect API keys", kind: .appStoreConnectAPI,
                       path: "~/.appstoreconnect/private_keys/AuthKey_*.p8", expectedCount: 5,
                       note: "Not in any backup yet.", source: readme, recordedOn: d9),
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
                         encryption: "AES-256-CBC, PBKDF2 600000 iterations", passphraseKeychainService: passphraseService,
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
                         encryption: "AES-256-CBC, PBKDF2 600000 iterations", passphraseKeychainService: passphraseService,
                         passphraseKeptIn: passphraseLocations,
                         restoreTests: [
                             RestoreTest(id: UUID(uuidString: "5B0E7C2A-4D1F-4C6E-9A3B-2F8D1E0A9C02")!, on: d8, by: "Claude session (test decryption)",
                                         note: "Test decryption when the backup was made. No restore by the owner is recorded.",
                                         source: "Session record 2026-10-08"),
                         ],
                         source: "\(map); session records 2026-10-08 and 2026-10-09", recordedOn: d9),
        ]

        let gaps: [KeyGap] = [
            KeyGap(id: "second-copy", kind: .secondCopy, title: "No second copy off this Mac",
                   detail: "Both backups are only in Google Drive. Keep a second copy elsewhere, e.g. a USB drive at home.",
                   source: readme, recordedOn: d9),
            KeyGap(id: "asc-notary-not-backed-up", kind: .notBackedUp, title: "App Store Connect keys and the notarytool profile are not backed up",
                   detail: "The 5 AuthKey .p8 files and the notarytool keychain profile are in no backup.",
                   source: readme, recordedOn: d9),
            KeyGap(id: "future-keys", kind: .futureKey, title: "New keys must be added to the bundle",
                   detail: "The KhayatYar, Talar and Namazia keys and VELRO's keystore.properties of 2026-10-17 are not in the encrypted bundle. Rebuild it with them.",
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
