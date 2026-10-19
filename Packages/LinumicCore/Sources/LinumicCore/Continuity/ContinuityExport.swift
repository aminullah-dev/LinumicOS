import CryptoKit
import Foundation

// MARK: - Continuity (تداوم): one encrypted copy of the company's records off this Mac
//
// The export is one JSON document (`ContinuityBundle`, format "linumic-os-continuity" v1) encrypted as an age file with
// a passphrase (`AgeFile`), so it opens with the standard `age` tool on any computer, without Linumic OS
// (docs/continuity.md). It holds the inventory, the obligations and accounts, the licence ledger (without licence key
// text) and the keys registry (paths, dates and sources only). Never a password, token, key, keystore or key file:
// those live in the Keychain and in the separate key backups. It is refused while the inventory or obligations.json is
// not read. After writing, the file is forced onto the device, read back from the folder, decrypted and compared with
// what was written; only then is the export recorded as verified. No network.

/// What the export holds, decrypted. Plain JSON, documented in docs/continuity.md.
public struct ContinuityBundle: Codable, Hashable, Sendable {
    public static let formatName = "linumic-os-continuity"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var createdAt: Date
    /// "Linumic OS 0.2.0 (2)".
    public var app: String
    /// What is never in the file, in words, so whoever opens it knows where those things are.
    public var excluded: [String]
    /// The inventory. Nil when it was not read (still loading, or its load failed): the export is then refused, since
    /// a copy without it would count as the copy off this Mac while it holds nothing.
    public var inventory: Inventory?
    /// The owner's own entries (dates, Done with evidence, accounts and their facts), as in obligations.json. Nil when
    /// that file could not be read: the export is then refused too.
    public var obligationEntries: ObligationsFile?
    /// Every obligation as the register showed it when exported: the seed, the owner's, accounts' renewals and the live
    /// dates, each with its source.
    public var obligations: [Obligation]
    /// Every account with whose name it is in and its renewal, each with its source.
    public var accounts: [VendorAccount]
    /// The licence ledger, without each licence's key text (`keyText` is always nil here). Absent (nil) when the ledger
    /// was not loaded when the export was made: not read, which is not the same as no licences.
    public var licences: [LicenceRecord]?
    public var licencesSyncedAt: Date?
    /// The Keys & Backups registry: which keys and backups exist, where, since when, with sources. No key material.
    /// Absent (nil) when the registry could not be read.
    public var keysRegistry: KeysRegistry?

    public init(createdAt: Date, app: String, inventory: Inventory?, obligationEntries: ObligationsFile?, obligations: [Obligation],
                accounts: [VendorAccount], licences: [LicenceRecord]?, licencesSyncedAt: Date?, keysRegistry: KeysRegistry?) {
        format = Self.formatName
        formatVersion = Self.currentFormatVersion
        self.createdAt = createdAt
        self.app = app
        excluded = Self.excludedText
        self.inventory = inventory
        self.obligationEntries = obligationEntries
        self.obligations = obligations
        self.accounts = accounts
        // A licence key is what a customer installs; it stays in the ledger on Supabase and in the customer's file.
        self.licences = licences?.map { var r = $0; r.keyText = nil; return r }
        self.licencesSyncedAt = licencesSyncedAt
        self.keysRegistry = keysRegistry
    }

    /// English on purpose: the file is read with other tools, by whoever restores it.
    public static let excludedText = [
        "Passwords, tokens, API keys and sessions: they are in the Keychain of the Mac (and the owner's Vault), never in this file.",
        "Signing keys, keystores, .p8 and .pem files and their passwords: see the keys registry below for where their own encrypted backups are.",
        "Licence key text: each licence's key is in the licence ledger on Supabase and in the customer's .lnmlic file.",
        "The run log, the Desk marks and cached readings of stores, GitHub and the Monitor: they are read again from their sources.",
    ]

    /// How many of each record it holds (shown with the export and kept in its record). A part that was not read has
    /// no count at all, never a zero. Without obligations.json the register lacks the owner's rows and accounts, so
    /// neither is counted then.
    public var counts: [String: Int] {
        var c: [String: Int] = [:]
        if let inventory { c["products"] = inventory.products.count }
        if obligationEntries != nil {
            c["obligations"] = obligations.count
            c["accounts"] = accounts.count
        }
        if let licences { c["licences"] = licences.count }
        if let keysRegistry {
            c["keys"] = keysRegistry.keys.count
            c["keyBackups"] = keysRegistry.backups.count
        }
        return c
    }

    /// A part read from its own file or store.
    public enum Part: String, CaseIterable, Sendable, Hashable {
        case inventory, obligationEntries, licences, keysRegistry

        public var title: String {
            switch self {
            case .inventory: L("the inventory")
            case .obligationEntries: L("your obligations file (obligations.json)")
            case .licences: L("the licence ledger")
            case .keysRegistry: L("the keys registry")
            }
        }

        /// Without it an export is refused: the inventory and the owner's obligations are what the copy off this Mac
        /// is for. The ledger and the registry are left out, and named, when they were not read.
        public var isRequired: Bool { self == .inventory || self == .obligationEntries }
    }

    /// The parts that were not read when the bundle was built (absent from it, not empty).
    public var missingParts: [Part] {
        Part.allCases.filter { part in
            switch part {
            case .inventory: inventory == nil
            case .obligationEntries: obligationEntries == nil
            case .licences: licences == nil
            case .keysRegistry: keysRegistry == nil
            }
        }
    }

    /// The parts not read without which nothing is written.
    public var requiredPartsNotRead: [Part] { missingParts.filter(\.isRequired) }

    /// The parts that were not read when the export was made (so they are absent from it, not empty), in words.
    public var partsNotRead: [String] { missingParts.map(\.title) }

    public func encoded() throws -> Data { try InventoryCoding.encoder().encode(self) }

    public static func decode(_ data: Data) throws -> ContinuityBundle {
        try InventoryCoding.decoder().decode(ContinuityBundle.self, from: data)
    }

    /// Patterns of secrets that must never be in an export: the key and token formats the company uses. Checked on the
    /// plain JSON before anything is encrypted or written; a match stops the export and says which kind was found
    /// (never the text itself).
    public static let forbiddenPatterns: [(pattern: String, kind: String)] = [
        (#"-----BEGIN [A-Z0-9 ]+-----"#, "a PEM key or certificate block"),
        (#"LNM1\.[A-Za-z0-9_\-]{20,}"#, "a licence key"),
        (#"github_pat_[A-Za-z0-9_]{20,}"#, "a GitHub token"),
        (#"gh[pousr]_[A-Za-z0-9]{30,}"#, "a GitHub token"),
        (#"sk-ant-[A-Za-z0-9_\-]{20,}"#, "an Anthropic API key"),
        (#"sb_secret_[A-Za-z0-9_\-]{10,}"#, "a Supabase secret key"),
        (#"AIza[0-9A-Za-z_\-]{35}"#, "a Google API key"),
        (#"AGE-SECRET-KEY-1[0-9A-Z]{50,}"#, "an age secret key"),
        // Three base64url parts, the first two JSON objects: a JWT, such as Supabase's legacy service_role key. LNM1
        // licence keys carry one too, but their key text is taken out before this check.
        (#"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{16,}"#, "a JSON Web Token"),
        (#"[sr]k_live_[0-9A-Za-z]{16,}"#, "a Stripe live key"),
        (#"AKIA[0-9A-Z]{16}"#, "an AWS access key"),
        // The other services the owner's products and tools use (Notion, OpenAI, ElevenLabs, Slack, Google sign-in,
        // Meta). Each needs a long run after its prefix, so a word that only starts the same way is not one.
        (#"\bntn_[A-Za-z0-9]{40,}"#, "a Notion token"),
        (#"\bsecret_[A-Za-z0-9]{40,}"#, "a Notion token"),
        (#"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_\-]{20,}"#, "an OpenAI API key"),
        (#"\bsk_[0-9a-f]{40,}"#, "an ElevenLabs API key"),
        (#"\bxox[abpr]-[0-9A-Za-z\-]{10,}"#, "a Slack token"),
        (#"\bya29\.[0-9A-Za-z_\-]{20,}"#, "a Google OAuth token"),
        (#"\bGOCSPX-[0-9A-Za-z_\-]{20,}"#, "a Google OAuth client secret"),
        (#"\bEAA[A-Za-z0-9]{60,}"#, "a Meta access token"),
    ]

    /// The kinds of secret found in `plaintext` (empty when it is clean).
    public static func forbiddenKinds(in plaintext: Data) -> [String] {
        let text = String(decoding: plaintext, as: UTF8.self)
        var kinds: [String] = []
        for (pattern, kind) in forbiddenPatterns where !kinds.contains(kind) {
            if let regex = try? Regex(pattern), text.contains(regex) { kinds.append(kind) }
        }
        return kinds
    }
}

// MARK: - The log (continuity.json, this device)

/// The owner opened an export on another computer and checked it (the roadmap's "opened outside this Mac").
public struct ContinuityOutsideCheck: Codable, Hashable, Sendable {
    public var on: KeyDay
    /// What was done and seen ("age -d on the office PC, SHA-256 matched"). Never empty.
    public var evidence: String
    public var enteredAt: Date

    public init(on: KeyDay, evidence: String, enteredAt: Date) {
        self.on = on
        self.evidence = evidence
        self.enteredAt = enteredAt
    }
}

/// One export, with the evidence that it was read back and opened.
public struct ContinuityExportRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var fileName: String
    /// Where it was written, home-relative or as the volume names it.
    public var folder: String
    public var folderKind: ContinuityFolderKind
    public var createdAt: Date
    /// When the file was read back from the folder, decrypted and found identical. Nil: not verified.
    public var verifiedAt: Date?
    /// Later checks of the same file with the passphrase (read back again from the folder).
    public var reverifiedAt: [Date]
    public var fileBytes: Int
    /// SHA-256 of the encrypted file as written.
    public var fileSHA256: String
    public var plaintextBytes: Int
    /// SHA-256 of the decrypted JSON: `shasum -a 256` of what `age -d` writes must print this.
    public var plaintextSHA256: String
    public var workFactor: Int
    public var formatVersion: Int
    public var counts: [String: Int]
    public var outsideChecks: [ContinuityOutsideCheck]

    public init(id: UUID = UUID(), fileName: String, folder: String, folderKind: ContinuityFolderKind, createdAt: Date,
                verifiedAt: Date?, reverifiedAt: [Date] = [], fileBytes: Int, fileSHA256: String, plaintextBytes: Int,
                plaintextSHA256: String, workFactor: Int, formatVersion: Int, counts: [String: Int],
                outsideChecks: [ContinuityOutsideCheck] = []) {
        self.id = id
        self.fileName = fileName
        self.folder = folder
        self.folderKind = folderKind
        self.createdAt = createdAt
        self.verifiedAt = verifiedAt
        self.reverifiedAt = reverifiedAt
        self.fileBytes = fileBytes
        self.fileSHA256 = fileSHA256
        self.plaintextBytes = plaintextBytes
        self.plaintextSHA256 = plaintextSHA256
        self.workFactor = workFactor
        self.formatVersion = formatVersion
        self.counts = counts
        self.outsideChecks = outsideChecks
    }

    public var isVerified: Bool { verifiedAt != nil }

    /// Known to be off this Mac: written to an external drive or a network volume, or written to a cloud folder and then
    /// opened on another computer. A cloud folder's copy on this Mac reads back whether or not it was uploaded (sync
    /// paused, signed out, storage full), so only an outside check shows that it left this Mac.
    public var isKnownOffThisMac: Bool {
        switch folderKind {
        case .external, .network: true
        case .cloud: !outsideChecks.isEmpty
        case .thisMac, .unknown: false
        }
    }

    /// Written to a cloud folder and not yet opened outside this Mac: whether it was uploaded is not known.
    public var uploadNotChecked: Bool { folderKind == .cloud && outsideChecks.isEmpty }

    /// The newest time the file was read back and found identical.
    public var lastVerifiedAt: Date? { (reverifiedAt + [verifiedAt].compactMap { $0 }).max() }
}

/// Where the chosen folder is, as the system reports its volume. Only a removable, external or network volume, or a
/// cloud folder, can be off this Mac; a folder on the Mac's own disk is said to be so, and one whose place the system
/// does not report is not counted as off this Mac. An export in a cloud folder counts once it was opened outside this
/// Mac (`ContinuityExportRecord.isKnownOffThisMac`).
public enum ContinuityFolderKind: String, Codable, Sendable, Hashable {
    /// A USB stick or an external disk.
    case external
    /// A folder synced by Google Drive for desktop, iCloud Drive or another File Provider.
    case cloud
    /// A volume served by another computer (a file share).
    case network
    /// The Mac's own disk: not off this Mac.
    case thisMac
    case unknown

    public var isOffThisMac: Bool { self == .external || self == .cloud || self == .network }

    public var title: String {
        switch self {
        case .external: L("External drive")
        case .cloud: L("Cloud folder")
        case .network: L("Network volume")
        case .thisMac: L("This Mac's own disk")
        case .unknown: L("Location not known")
        }
    }

    /// Cloud folders by path, under the user's real home only (a folder elsewhere whose path merely holds those names
    /// is not one); then a volume that is not local (a file share); the volume's own "internal" flag decides the rest.
    public static func classify(path: String, home: String, volumeIsInternal: Bool?, volumeIsLocal: Bool? = nil) -> ContinuityFolderKind {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !base.isEmpty, ["/Library/CloudStorage/", "/Library/Mobile Documents/"].contains(where: { path.hasPrefix(base + $0) }) {
            return .cloud
        }
        if volumeIsLocal == false { return .network }
        switch volumeIsInternal {
        case false?: return .external
        case true?: return .thisMac
        case nil: return .unknown
        }
    }
}

public struct ContinuityLog: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Newest first.
    public var exports: [ContinuityExportRecord]

    public init(exports: [ContinuityExportRecord] = []) {
        version = Self.currentVersion
        self.exports = exports
    }

    /// The newest export that was read back and found identical.
    public var lastVerified: ContinuityExportRecord? { exports.filter(\.isVerified).max { $0.createdAt < $1.createdAt } }

    /// The newest verified export known to be off this Mac (`ContinuityExportRecord.isKnownOffThisMac`).
    public var lastVerifiedOffMac: ContinuityExportRecord? {
        exports.filter { $0.isVerified && $0.isKnownOffThisMac }.max { $0.createdAt < $1.createdAt }
    }

    /// When the next export is due: `ObligationsBuilder.exportEveryDays` after the last verified export off this Mac.
    /// Nil while there is none (it is due now). An export on this Mac's own disk does not move it.
    public func nextExportDue(calendar: Calendar = KeyDay.calendar) -> Date? {
        guard let last = lastVerifiedOffMac else { return nil }
        return calendar.date(byAdding: .day, value: ObligationsBuilder.exportEveryDays, to: last.createdAt)
    }

    public mutating func add(_ record: ContinuityExportRecord) {
        exports.insert(record, at: 0)
    }

    public mutating func markReverified(_ id: UUID, at: Date) {
        guard let i = exports.firstIndex(where: { $0.id == id }) else { return }
        exports[i].reverifiedAt.append(at)
    }

    /// Records that the owner opened an export on another computer; refused without evidence or with a future day.
    public mutating func recordOutsideCheck(_ id: UUID, on day: KeyDay, evidence: String, now: Date,
                                            calendar: Calendar = KeyDay.calendar) throws {
        guard let text = ObligationsFile.clean(evidence) else { throw ObligationError.missingEvidence }
        guard day <= KeyDay(now, calendar: calendar) else { throw ObligationError.futureDay }
        guard let i = exports.firstIndex(where: { $0.id == id }) else { throw ObligationError.unknownID(id.uuidString) }
        exports[i].outsideChecks.append(ContinuityOutsideCheck(on: day, evidence: text, enteredAt: now))
    }
}

/// `continuity.json` next to the inventory. A file that can't be read is reported and never overwritten.
public struct ContinuityStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "continuity.json")
    }

    public enum LoadResult: Sendable {
        case empty
        case loaded(ContinuityLog)
        case unreadable(String)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .empty }
        do {
            return .loaded(try InventoryCoding.decoder().decode(ContinuityLog.self, from: Data(contentsOf: fileURL)))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    public func save(_ log: ContinuityLog) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InventoryCoding.encoder().encode(log).write(to: fileURL, options: [.atomic])
    }
}

// MARK: - The passphrase

/// The passphrase is typed for each export and never stored: not in a file, not in the Keychain, not in the log.
public enum ContinuityPassphrase {
    public static let minimumLength = 16

    /// Printable ASCII only (letters, digits, space and punctuation). age uses the passphrase's bytes as typed, with no
    /// normalisation, and a Dari passphrase can hold letters that look the same on paper but are different characters
    /// on another keyboard (ي and ی, ك and ک, the half-space): typed elsewhere, it would not open the export.
    public static func isTypableAnywhere(_ passphrase: String) -> Bool {
        passphrase.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    /// Why it can't be used, or nil when it can.
    public static func problem(_ passphrase: String, confirmation: String) -> String? {
        if !isTypableAnywhere(passphrase) {
            return L("Use only Latin letters, digits, spaces and punctuation. A Dari letter can be typed as a different character on another keyboard, and the export would then not open. “Suggest a passphrase” gives one that can be typed anywhere.")
        }
        // age reads the passphrase exactly as typed, with no trimming: a space that can't be seen on paper would be
        // missing when it is typed from the paper elsewhere.
        if passphrase.hasPrefix(" ") || passphrase.hasSuffix(" ") || passphrase.contains("  ") {
            return L("Don't start or end it with a space, or put two spaces together: they can't be seen on paper, and age reads the passphrase exactly as typed, so a copy typed from the paper would not open the export.")
        }
        if passphrase.count < minimumLength { return LF("Use at least %d characters. A line of several words is easy to write on paper.", minimumLength) }
        if Set(passphrase).count < 6 { return L("Use more different characters.") }
        if passphrase != confirmation { return L("The two passphrases are not the same.") }
        return nil
    }

    /// A random passphrase to write on paper: six groups of four from letters and digits that can't be mistaken for one
    /// another (about 119 bits). Shown once, never stored.
    public static func suggestion() -> String {
        let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")
        var rng = SystemRandomNumberGenerator()
        return (0..<6).map { _ in String((0..<4).map { _ in alphabet.randomElement(using: &rng)! }) }.joined(separator: "-")
    }
}

// MARK: - Writing and verifying

public enum ContinuityExporter {
    public enum Failure: LocalizedError, Equatable {
        case requiredPartsNotRead([ContinuityBundle.Part])
        case forbiddenContent([String])
        case readBackDiffers
        case decryptedDiffers
        case notABundle(String)

        public var errorDescription: String? {
            switch self {
            case .requiredPartsNotRead(let parts):
                LF("Nothing was written: %@ could not be read, or has not loaded yet. An export without it would count as the copy off this Mac while it does not hold it. Wait until it has loaded, or fix what its screen reports, then export again.",
                   parts.map(\.title).joined(separator: ", "))
            case .forbiddenContent(let kinds):
                LF("Nothing was written: the export would contain %@. Remove it from the record that holds it, then export again.",
                   kinds.map { L($0) }.joined(separator: ", "))
            case .readBackDiffers: L("The file read back from the folder is not the file that was written.")
            case .decryptedDiffers: L("The file read back decrypts to something other than what was written.")
            case .notABundle(let why): LF("The decrypted file is not a Linumic OS continuity export (%@).", why)
            }
        }
    }

    /// "linumic-os-continuity-2026-10-19-1405.json.age" (local time, Gregorian, so the names sort by date).
    public static func fileName(for date: Date, calendar: Calendar = InventoryBackup.gregorian) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "linumic-os-continuity-%04d-%02d-%02d-%02d%02d.json.age",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Refuses a bundle without the inventory or obligations.json, then encrypts it, writes it into `folder` (never over
    /// an existing file), forces it onto the device, reads it back from the disk, decrypts it with the same passphrase
    /// and compares it with what was written. Throws, records nothing and removes the file it wrote when any step fails
    /// (a write that stops halfway included); the record it returns is the evidence that the export was verified.
    /// `write` and `afterWrite` are test seams: the disk write, and a step between writing and reading back.
    public static func export(_ bundle: ContinuityBundle, passphrase: String, to folder: URL, folderName: String,
                              folderKind: ContinuityFolderKind, now: Date, workFactor: Int = AgeFile.defaultWorkFactor,
                              calendar: Calendar = InventoryBackup.gregorian) throws -> ContinuityExportRecord {
        try export(bundle, passphrase: passphrase, to: folder, folderName: folderName, folderKind: folderKind, now: now,
                   workFactor: workFactor, calendar: calendar, write: { try $0.write(to: $1, options: [.withoutOverwriting]) },
                   afterWrite: { _ in })
    }

    static func export(_ bundle: ContinuityBundle, passphrase: String, to folder: URL, folderName: String,
                       folderKind: ContinuityFolderKind, now: Date, workFactor: Int, calendar: Calendar,
                       write: (Data, URL) throws -> Void, afterWrite: (URL) throws -> Void) throws -> ContinuityExportRecord {
        let missing = bundle.requiredPartsNotRead
        guard missing.isEmpty else { throw Failure.requiredPartsNotRead(missing) }
        let plaintext = try bundle.encoded()
        let forbidden = ContinuityBundle.forbiddenKinds(in: plaintext)
        guard forbidden.isEmpty else { throw Failure.forbiddenContent(forbidden) }
        let ciphertext = try AgeFile.encrypt(plaintext, passphrase: passphrase, workFactor: workFactor)

        var name = fileName(for: now, calendar: calendar)
        var target = folder.appending(path: name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            name = fileName(for: now, calendar: calendar).replacingOccurrences(of: ".json.age", with: "-\(n).json.age")
            target = folder.appending(path: name)
            n += 1
        }
        do {
            try write(ciphertext, target)
            try flushToDevice(target)
        } catch {
            // A file that was already there (made between the check above and the write) is someone else's and stays.
            // Anything else (a full or pulled USB stick, a cloud folder's error) may have left part of this file.
            if !isFileExists(error) { try? FileManager.default.removeItem(at: target) }
            throw error
        }

        let verifiedAt: Date
        do {
            try afterWrite(target)
            verifiedAt = try verify(file: target, passphrase: passphrase, fileSHA256: hex(SHA256.hash(data: ciphertext)),
                                    plaintextSHA256: hex(SHA256.hash(data: plaintext)), now: now)
        } catch {
            // A file that did not pass is not left behind to be mistaken for an export later.
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return ContinuityExportRecord(fileName: name, folder: folderName, folderKind: folderKind, createdAt: now,
                                      verifiedAt: verifiedAt, fileBytes: ciphertext.count,
                                      fileSHA256: hex(SHA256.hash(data: ciphertext)), plaintextBytes: plaintext.count,
                                      plaintextSHA256: hex(SHA256.hash(data: plaintext)), workFactor: workFactor,
                                      formatVersion: bundle.formatVersion, counts: bundle.counts)
    }

    /// Forces what was written onto the device before it is read back: F_FULLFSYNC, or fsync where the volume does not
    /// support it. Without it the read back can come from memory, and a USB stick pulled without ejecting could hold a
    /// short file that was recorded as verified. (That the device still holds it later is shown only by "Check again"
    /// or by opening it outside this Mac.)
    static func flushToDevice(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { try handle.synchronize() }
    }

    /// The write failed because the file already existed (`.withoutOverwriting`): it is not ours to remove.
    static func isFileExists(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteFileExists { return true }
        if let posix = error as? POSIXError, posix.code == .EEXIST { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EEXIST) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EEXIST)
        }
        return false
    }

    /// Reads the file back from the disk, checks it is the file that was written, decrypts it and checks the JSON is
    /// what was written and still decodes as a bundle. Returns the time of the check.
    @discardableResult
    public static func verify(file: URL, passphrase: String, fileSHA256: String, plaintextSHA256: String, now: Date) throws -> Date {
        let readBack = try Data(contentsOf: file, options: [.uncached])
        guard hex(SHA256.hash(data: readBack)) == fileSHA256 else { throw Failure.readBackDiffers }
        let decrypted = try AgeFile.decrypt(readBack, passphrase: passphrase)
        guard hex(SHA256.hash(data: decrypted)) == plaintextSHA256 else { throw Failure.decryptedDiffers }
        do {
            let bundle = try ContinuityBundle.decode(decrypted)
            guard bundle.format == ContinuityBundle.formatName else { throw Failure.notABundle(bundle.format) }
        } catch let f as Failure {
            throw f
        } catch {
            throw Failure.notABundle(error.localizedDescription)
        }
        return now
    }

    /// Checks an earlier export again, from its record.
    public static func reverify(_ record: ContinuityExportRecord, in folder: URL, passphrase: String, now: Date) throws -> Date {
        try verify(file: folder.appending(path: record.fileName), passphrase: passphrase, fileSHA256: record.fileSHA256,
                   plaintextSHA256: record.plaintextSHA256, now: now)
    }
}
