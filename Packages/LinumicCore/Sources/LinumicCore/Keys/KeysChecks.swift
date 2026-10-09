import Foundation

// MARK: - Local checks (existence, size and modification date only)
//
// The checks never open a key file. They read file-system attributes (exists, size, modification date) and directory
// listings, nothing else. All logic runs against `KeyFileSystem`, so tests use a fake file system and the App passes
// `LocalKeyFileSystem` (FileManager attributes) inside the security-scoped folders the owner granted.

/// Attributes of one file. No content, no hash.
public struct KeyFileInfo: Hashable, Sendable, Codable {
    /// Absolute path.
    public var path: String
    public var size: Int64
    public var modifiedAt: Date

    public init(path: String, size: Int64, modifiedAt: Date) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public struct KeyDirEntry: Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool

    public init(name: String, isDirectory: Bool, isSymbolicLink: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

/// What the checks may ask of a file system: attributes of a regular file, and a directory's entries.
public protocol KeyFileSystem: Sendable {
    /// Attributes of a regular file, or nil when there is none at `path`.
    func fileInfo(atPath path: String) -> KeyFileInfo?
    /// Whether a directory exists at `path`.
    func directoryExists(atPath path: String) -> Bool
    /// The entries of a directory, or nil when it can't be listed.
    func entries(ofDirectory path: String) -> [KeyDirEntry]?
}

/// FileManager attributes only: `attributesOfItem` (size, modification date, type) and `contentsOfDirectory`.
/// It never calls `contents(atPath:)` or opens a file handle.
public struct LocalKeyFileSystem: KeyFileSystem {
    public init() {}

    public func fileInfo(atPath path: String) -> KeyFileInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        return KeyFileInfo(path: path, size: size, modifiedAt: modified)
    }

    public func directoryExists(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func entries(ofDirectory path: String) -> [KeyDirEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.map { name in
            let full = (path as NSString).appendingPathComponent(name)
            let type = (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType
            return KeyDirEntry(name: name, isDirectory: type == .typeDirectory, isSymbolicLink: type == .typeSymbolicLink)
        }
    }
}

// MARK: Paths and file names

public enum KeyPaths {
    /// "~/x" → "<home>/x". Absolute paths are returned unchanged.
    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return trimmed(home) + "/" + path.dropFirst(2) }
        return path
    }

    /// "<home>/x" → "~/x", for display.
    public static func abbreviate(_ path: String, home: String) -> String {
        let h = trimmed(home)
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~/" + path.dropFirst(h.count + 1) }
        return path
    }

    /// Whether `path` is `root` or inside it.
    public static func isInside(_ path: String, root: String) -> Bool {
        let r = trimmed(root)
        return path == r || path.hasPrefix(r + "/") || r == "/"
    }

    static func trimmed(_ p: String) -> String {
        p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }
}

public enum KeyFileName {
    /// Directories never entered by the scan.
    public static let skippedDirectories: Set<String> = ["node_modules", "build", ".git"]

    /// The file-name patterns the scan looks for: `*.jks`, `*.keystore`, `*-private.pem`, `AuthKey_*.p8`.
    /// `debug.keystore` (the Android debug key, not for release) is ignored.
    public static func isKeyFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "debug.keystore" { return false }
        if lower.hasSuffix(".jks") || lower.hasSuffix(".keystore") { return lower.count > 4 }
        if name.hasSuffix("-private.pem") { return name.count > "-private.pem".count }
        if name.hasPrefix("AuthKey_") && name.hasSuffix(".p8") { return name.count > "AuthKey_.p8".count }
        return false
    }

    /// A shell-like match where `*` stands for any run of characters (no other wildcards).
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == name }
        guard name.hasPrefix(parts[0]) else { return false }
        var rest = Substring(name.dropFirst(parts[0].count))
        for (i, part) in parts.enumerated().dropFirst() {
            if i == parts.count - 1 {
                return part.isEmpty || (rest.count >= part.count && rest.hasSuffix(part))
            }
            guard !part.isEmpty else { continue }
            guard let r = rest.range(of: part) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }
}

// MARK: Access (security-scoped grants)

/// Which folders the app may read. On the Mac (sandboxed) these are the folders the owner chose; in tests,
/// `unrestricted`.
public struct KeyAccess: Sendable, Hashable {
    public var roots: [String]
    public var unrestricted: Bool

    public init(roots: [String], unrestricted: Bool = false) {
        self.roots = roots.map(KeyPaths.trimmed)
        self.unrestricted = unrestricted
    }

    public static let all = KeyAccess(roots: [], unrestricted: true)

    public func isGranted(_ path: String) -> Bool {
        unrestricted || roots.contains { KeyPaths.isInside(path, root: $0) }
    }

    /// Granted roots that lie strictly inside `path` (a partly granted scan location).
    public func grantedInside(_ path: String) -> [String] {
        roots.filter { $0 != KeyPaths.trimmed(path) && KeyPaths.isInside($0, root: path) }.sorted()
    }
}

// MARK: Per-key check

public enum KeyCheckStatus: Hashable, Sendable {
    /// Found: one file, or every file a pattern matched.
    case present([KeyFileInfo])
    /// The location is granted and nothing is there.
    case missing
    /// The app may not read the location; choose the folder to check it.
    case notGranted
}

public struct KeyCheckResult: Hashable, Sendable, Identifiable {
    public var keyID: String
    public var status: KeyCheckStatus
    public var id: String { keyID }

    public init(keyID: String, status: KeyCheckStatus) {
        self.keyID = keyID
        self.status = status
    }

    public var files: [KeyFileInfo] {
        if case .present(let f) = status { f } else { [] }
    }
}

public enum KeyChecker {
    /// Checks one registry key: its file (or the files its pattern matches) and their attributes.
    public static func check(_ key: TrackedKey, home: String, access: KeyAccess, fs: KeyFileSystem) -> KeyCheckResult {
        let full = KeyPaths.expand(key.path, home: home)
        guard access.isGranted(full) else { return KeyCheckResult(keyID: key.id, status: .notGranted) }
        if key.isPattern {
            let dir = (full as NSString).deletingLastPathComponent
            let pattern = (full as NSString).lastPathComponent
            let files = (fs.entries(ofDirectory: dir) ?? [])
                .filter { !$0.isDirectory && !$0.isSymbolicLink && KeyFileName.matches(pattern, $0.name) }
                .compactMap { fs.fileInfo(atPath: (dir as NSString).appendingPathComponent($0.name)) }
                .sorted { $0.path < $1.path }
            return KeyCheckResult(keyID: key.id, status: files.isEmpty ? .missing : .present(files))
        }
        if let info = fs.fileInfo(atPath: full) {
            return KeyCheckResult(keyID: key.id, status: .present([info]))
        }
        return KeyCheckResult(keyID: key.id, status: .missing)
    }
}

// MARK: Scan for key files

public enum ScanRootStatus: Hashable, Sendable {
    case scanned
    /// Only these granted sub-folders were scanned.
    case partly([String])
    case notGranted
    /// Granted, but there is no such folder.
    case missing
}

public struct ScanRootState: Hashable, Sendable, Identifiable {
    /// Home-relative, as configured ("~/Projects").
    public var root: String
    public var status: ScanRootStatus
    public var id: String { root }

    public init(root: String, status: ScanRootStatus) {
        self.root = root
        self.status = status
    }
}

public struct KeysScanResult: Hashable, Sendable {
    public var files: [KeyFileInfo]
    public var roots: [ScanRootState]

    public init(files: [KeyFileInfo] = [], roots: [ScanRootState] = []) {
        self.files = files
        self.roots = roots
    }
}

public enum KeysScanner {
    /// Where the scan looks, and nowhere else.
    public static let defaultRoots = ["~/Projects", "~/Keys", "~/.velro-keys", "~/.linumic/license-keys", "~/.appstoreconnect"]
    /// A safety limit on folder depth below a root.
    public static let maxDepth = 14

    public static func scan(roots: [String] = defaultRoots, home: String, access: KeyAccess, fs: KeyFileSystem) -> KeysScanResult {
        var found: [String: KeyFileInfo] = [:]
        var states: [ScanRootState] = []
        for root in roots {
            let full = KeyPaths.expand(root, home: home)
            let starts: [String]
            let status: ScanRootStatus
            if access.isGranted(full) {
                guard fs.directoryExists(atPath: full) else {
                    states.append(ScanRootState(root: root, status: .missing))
                    continue
                }
                starts = [full]
                status = .scanned
            } else {
                let inside = access.grantedInside(full).filter { fs.directoryExists(atPath: $0) }
                if inside.isEmpty {
                    states.append(ScanRootState(root: root, status: .notGranted))
                    continue
                }
                starts = inside
                status = .partly(inside.map { KeyPaths.abbreviate($0, home: home) })
            }
            for start in starts {
                walk(start, depth: 0, fs: fs) { found[$0.path] = $0 }
            }
            states.append(ScanRootState(root: root, status: status))
        }
        return KeysScanResult(files: found.values.sorted { $0.path < $1.path }, roots: states)
    }

    static func walk(_ dir: String, depth: Int, fs: KeyFileSystem, found: (KeyFileInfo) -> Void) {
        guard depth <= maxDepth, let entries = fs.entries(ofDirectory: dir) else { return }
        for e in entries.sorted(by: { $0.name < $1.name }) {
            // Never follow links: no loops, and nothing outside the granted folders.
            if e.isSymbolicLink { continue }
            let path = (dir as NSString).appendingPathComponent(e.name)
            if e.isDirectory {
                if KeyFileName.skippedDirectories.contains(e.name) { continue }
                walk(path, depth: depth + 1, fs: fs, found: found)
            } else if KeyFileName.isKeyFile(e.name), let info = fs.fileInfo(atPath: path) {
                found(info)
            }
        }
    }
}

// MARK: - Evaluation: findings and reminders

/// Whether a Keychain item exists. The app asks for attributes only, never the item's data.
public enum KeychainPresence: String, Codable, Hashable, Sendable {
    case present, missing
    /// Not checked (iOS, or the query failed for another reason).
    case unknown
}

/// Everything the rules look at. `checkedAt == nil` means no local check ran (iOS, or not yet).
public struct KeysCheckInput: Sendable {
    public var registry: KeysRegistry
    public var now: Date
    public var home: String
    public var results: [String: KeyCheckResult]
    public var scan: KeysScanResult?
    public var passphrase: [String: KeychainPresence]
    public var checkedAt: Date?
    public var calendar: Calendar

    public init(registry: KeysRegistry, now: Date, home: String = "", results: [KeyCheckResult] = [], scan: KeysScanResult? = nil,
                passphrase: [String: KeychainPresence] = [:], checkedAt: Date? = nil, calendar: Calendar = .current) {
        self.registry = registry
        self.now = now
        self.home = home
        self.results = Dictionary(results.map { ($0.keyID, $0) }, uniquingKeysWith: { a, _ in a })
        self.scan = scan
        self.passphrase = passphrase
        self.checkedAt = checkedAt
        self.calendar = calendar
    }
}

public enum KeysReminderKind: String, Codable, Sendable, CaseIterable {
    case restoreTestDue
    case noRestoreTest
    case secondCopyMissing
    case keyMissing
    case keyChangedAfterBackup
    case keyNotBackedUp
    case uncoveredFile
    case passphraseMissing
    /// A file recorded as deliberately deleted is on this Mac again.
    case deletedFileBack
}

public struct KeysReminder: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: KeysReminderKind
    public var severity: BriefSeverity
    public var text: String
    public var detail: String?
    public var source: String
    /// When the underlying fact was read (a local check) or nil for registry facts.
    public var readAt: Date?
    public var backupID: String?
    public var keyID: String?

    public init(id: String, kind: KeysReminderKind, severity: BriefSeverity, text: String, detail: String? = nil, source: String,
                readAt: Date? = nil, backupID: String? = nil, keyID: String? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.text = text
        self.detail = detail
        self.source = source
        self.readAt = readAt
        self.backupID = backupID
        self.keyID = keyID
    }
}

/// The state of one registry key after the rules.
public enum KeyBackupState: Hashable, Sendable {
    /// In a backup, and not changed since it.
    case covered
    /// In a backup, but modified on a later day than the backup was made.
    case changedAfterBackup(backupID: String, modified: KeyDay)
    /// Needs a backup and has none (or names a backup that isn't in the registry).
    case notBackedUp
    /// Not something to back up (a passphrase copy).
    case notApplicable
}

public enum KeysRules {
    /// A restore test older than this is due again.
    public static let restoreTestMaxDays = 90

    /// Backup state of a registry key, from the registry and (when checked) the files' modification days.
    public static func backupState(_ key: TrackedKey, registry: KeysRegistry, result: KeyCheckResult?, calendar: Calendar = .current) -> KeyBackupState {
        guard key.kind.needsBackup, !key.isDeleted else { return .notApplicable }
        let backups = key.backupIDs.compactMap(registry.backup)
        guard !backups.isEmpty else { return .notBackedUp }
        // The newest backup that holds it. A file changed on a LATER day than that may be newer than the backup.
        // Facts are known to the day, so a change later on the backup's own day can't be told apart and is not flagged.
        let newest = backups.max { $0.createdOn < $1.createdOn }!
        for file in result?.files ?? [] {
            let modified = KeyDay(file.modifiedAt, calendar: calendar)
            if modified > newest.createdOn { return .changedAfterBackup(backupID: newest.id, modified: modified) }
        }
        return .covered
    }

    /// Scanned key files that no registry key path or pattern covers.
    public static func unregisteredFiles(_ input: KeysCheckInput) -> [KeyFileInfo] {
        guard let scan = input.scan else { return [] }
        let patterns = input.registry.keys.map { KeyPaths.expand($0.path, home: input.home) }
        return scan.files.filter { file in
            !patterns.contains { p in
                let dir = (p as NSString).deletingLastPathComponent
                let last = (p as NSString).lastPathComponent
                return (file.path as NSString).deletingLastPathComponent == dir && KeyFileName.matches(last, file.name)
            }
        }
    }

    /// Days since a backup's last restore test, or nil when none is recorded.
    public static func restoreTestAge(_ backup: BackupRecord, now: Date, calendar: Calendar = .current) -> Int? {
        backup.lastRestoreTest.map { $0.on.days(until: KeyDay(now, calendar: calendar)) }
    }

    public static func reminders(_ input: KeysCheckInput) -> [KeysReminder] {
        let reg = input.registry
        let registrySource = L("Keys & Backups registry (keys-registry.json)")
        let checkSource = L("File check on this Mac (date and size only)")
        var out: [KeysReminder] = []

        for b in reg.backups {
            if let test = b.lastRestoreTest {
                let age = test.on.days(until: KeyDay(input.now, calendar: input.calendar))
                if age > restoreTestMaxDays {
                    out.append(KeysReminder(id: "keys.restore.\(b.id)", kind: .restoreTestDue, severity: .normal,
                                            text: LF("%@: last restore test was %d days ago (%@)", L(b.title), age, test.on.description),
                                            detail: LF("Test a restore at least every %d days.", restoreTestMaxDays),
                                            source: test.source, backupID: b.id))
                }
            } else {
                out.append(KeysReminder(id: "keys.restore.\(b.id)", kind: .noRestoreTest, severity: .normal,
                                        text: LF("%@: no restore test recorded", L(b.title)), source: b.source, backupID: b.id))
            }
        }

        if let gap = reg.secondCopyGap, gap.isOpen {
            out.append(KeysReminder(id: "keys.secondcopy", kind: .secondCopyMissing, severity: .normal,
                                    text: L("No second copy of the backups off this Mac"), detail: gap.detail.map(L), source: gap.source))
        }

        for key in reg.keys {
            let result = input.results[key.id]
            // Deleted on purpose: absence is the expected state. Only its return is worth saying.
            if let deleted = key.deletedOn {
                if case .present = result?.status {
                    out.append(KeysReminder(id: "keys.deletedback.\(key.id)", kind: .deletedFileBack, severity: .normal,
                                            text: LF("%@ was deleted on %@ but is on this Mac again", L(key.title), deleted.description),
                                            detail: key.path, source: checkSource, readAt: input.checkedAt, keyID: key.id))
                }
                continue
            }
            if case .missing = result?.status {
                out.append(KeysReminder(id: "keys.missing.\(key.id)", kind: .keyMissing, severity: key.kind == .passphraseCopy ? .info : .high,
                                        text: key.kind == .passphraseCopy ? LF("%@ is no longer on this Mac", L(key.title))
                                                                         : LF("%@ is missing at %@", L(key.title), key.path),
                                        source: checkSource, readAt: input.checkedAt, keyID: key.id))
                continue
            }
            switch backupState(key, registry: reg, result: result, calendar: input.calendar) {
            case .changedAfterBackup(let backupID, let modified):
                let backup = reg.backup(backupID)
                out.append(KeysReminder(id: "keys.changed.\(key.id)", kind: .keyChangedAfterBackup, severity: .high,
                                        text: LF("%@ changed on %@, after the backup of %@", L(key.title), modified.description,
                                                 backup?.createdOn.description ?? "?"),
                                        detail: LF("The backup %@ may be stale. Make a new one.", backup?.fileName ?? backupID),
                                        source: checkSource, readAt: input.checkedAt, backupID: backupID, keyID: key.id))
            case .notBackedUp:
                // A key that was checked and isn't there is reported above; one not checked yet still has no backup.
                out.append(KeysReminder(id: "keys.unbacked.\(key.id)", kind: .keyNotBackedUp, severity: .normal,
                                        text: LF("%@ is not in any backup", L(key.title)), detail: key.path,
                                        source: result == nil ? registrySource : checkSource,
                                        readAt: result == nil ? nil : input.checkedAt, keyID: key.id))
            case .covered, .notApplicable:
                break
            }
        }

        for file in unregisteredFiles(input) {
            let shown = KeyPaths.abbreviate(file.path, home: input.home)
            out.append(KeysReminder(id: "keys.uncovered.\(file.path)", kind: .uncoveredFile, severity: .normal,
                                    text: LF("Key file not covered by any backup: %@", file.name), detail: shown,
                                    source: L("Scan of key folders on this Mac (file names only)"), readAt: input.checkedAt))
        }

        for (service, presence) in input.passphrase.sorted(by: { $0.key < $1.key }) where presence == .missing {
            out.append(KeysReminder(id: "keys.passphrase.\(service)", kind: .passphraseMissing, severity: .high,
                                    text: LF("Keychain item “%@” was not found", service),
                                    detail: L("Without the passphrase the backups can't be opened. Check the Keychain and the private Notion page."),
                                    source: L("Keychain lookup (attributes only, never the passphrase)"), readAt: input.checkedAt))
        }
        return out.sorted { ($0.severity, $0.text) < ($1.severity, $1.text) }
    }
}

// MARK: - Restore guide

public enum KeysRestoreGuide {
    /// The folder the guide restores into. Empty and private, deleted afterwards.
    public static let folder = "$HOME/keys-restore-test"

    /// The decryption command for one backup. openssl asks for the passphrase itself; it is never on the command line.
    public static func decryptCommand(_ backup: BackupRecord) -> String {
        let untar = backup.archive == .tarGzip ? "tar -xz" : "tar -x"
        return "openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in \(backup.fileName) | \(untar)"
    }

    public static func makeFolderCommand() -> String {
        "mkdir -m 700 \"\(folder)\" && cd \"\(folder)\""
    }

    public static func cleanupCommand() -> String {
        "cd ~ && rm -rf \"\(folder)\""
    }
}
