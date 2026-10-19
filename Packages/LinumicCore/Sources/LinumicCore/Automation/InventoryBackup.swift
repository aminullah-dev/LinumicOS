import CryptoKit
import Foundation

/// Daily copies of the inventory file on this device (`Backups/inventory-YYYY-MM-DD.json`), each read back and
/// decoded after writing, so a backup is only counted when it is proven to restore. A copy identical to the
/// newest one is not written again. The newest `keep` copies are kept; older ones are removed.
public struct InventoryBackup: Sendable {
    public struct Result: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case written, unchanged }
        public var kind: Kind
        public var file: URL
        public var products: Int
        public var bytes: Int
        public var removed: [URL]
    }

    public enum BackupError: LocalizedError, Equatable {
        case noInventory
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .noInventory: "There is no inventory file to back up yet."
            case .unreadable(let message): "The backup was written but could not be read back: \(message)"
            }
        }
    }

    public static let keep = 30

    public let source: URL
    public let folder: URL
    public let keep: Int

    public init(source: URL, folder: URL, keep: Int = InventoryBackup.keep) {
        self.source = source
        self.folder = folder
        self.keep = keep
    }

    /// Next to the inventory: `Application Support/LinumicCommandCenter/Backups`.
    public static func `default`() throws -> InventoryBackup {
        let source = try JSONFileInventoryStore.defaultFileURL()
        return InventoryBackup(source: source, folder: source.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory))
    }

    /// Gregorian dates in the local time zone, whatever calendar the Mac uses, so the names sort by date.
    public static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    public static func fileName(for date: Date, calendar: Calendar = InventoryBackup.gregorian) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ n: Int?, _ width: Int) -> String {
            let digits = String(n ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "inventory-\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2)).json"
    }

    /// Backups on disk, newest first (the names sort by date).
    public func existing() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("inventory-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func run(now: Date = .now, calendar: Calendar = InventoryBackup.gregorian) throws -> Result {
        guard let data = try? Data(contentsOf: source) else { throw BackupError.noInventory }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let newest = existing().first, let previous = try? Data(contentsOf: newest), Self.digest(previous) == Self.digest(data) {
            let inventory = try verify(newest)
            return Result(kind: .unchanged, file: newest, products: inventory.products.count, bytes: previous.count, removed: [])
        }
        let target = folder.appending(path: Self.fileName(for: now, calendar: calendar))
        try data.write(to: target, options: [.atomic])
        let inventory = try verify(target)
        var removed: [URL] = []
        for old in existing().dropFirst(keep) {
            if (try? fm.removeItem(at: old)) != nil { removed.append(old) }
        }
        return Result(kind: .written, file: target, products: inventory.products.count, bytes: data.count, removed: removed)
    }

    /// Reads a backup back and decodes it as the app would on restore.
    public func verify(_ file: URL) throws -> Inventory {
        do { return try InventoryCoding.decode(Data(contentsOf: file)) } catch {
            throw BackupError.unreadable(error.localizedDescription)
        }
    }

    private static func digest(_ data: Data) -> SHA256.Digest { SHA256.hash(data: data) }
}

// MARK: - What Backups/ really holds

/// One backup file as it is on disk now.
public struct BackupFile: Sendable, Hashable {
    public var name: String
    /// The day in its name ("inventory-2026-10-19.json"), in the Mac's local time zone when it was written.
    public var day: KeyDay?
    public var bytes: Int?
    public var modifiedAt: Date?

    public init(name: String, day: KeyDay?, bytes: Int? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.day = day
        self.bytes = bytes
        self.modifiedAt = modifiedAt
    }
}

/// The state of `Backups/` as read from the disk at `checkedAt`, never from the run log: how many copies, the newest,
/// and whether it restores (read back and decoded, as on a restore).
public struct BackupFolderStatus: Sendable, Hashable {
    public enum Check: Sendable, Hashable {
        /// Read back and decoded as the app would on restore.
        case restores(products: Int)
        /// It is there but does not restore.
        case fails(String)
    }

    public var checkedAt: Date
    public var files: Int
    /// Every backup file's name, newest first.
    public var names: [String]
    public var newest: BackupFile?
    /// The newest copy, read back. Nil when there is none.
    public var newestCheck: Check?
    /// The newest copy holds exactly the inventory as it is now; nil when either could not be read.
    public var matchesInventory: Bool?
    /// The folder could not be listed, which is not the same as empty.
    public var listError: String?

    public init(checkedAt: Date, files: Int, names: [String] = [], newest: BackupFile? = nil, newestCheck: Check? = nil,
                matchesInventory: Bool? = nil, listError: String? = nil) {
        self.checkedAt = checkedAt
        self.files = files
        self.names = names
        self.newest = newest
        self.newestCheck = newestCheck
        self.matchesInventory = matchesInventory
        self.listError = listError
    }

    public var isEmpty: Bool { listError == nil && files == 0 }
    public var restores: Bool { if case .restores = newestCheck { true } else { false } }
}

public extension InventoryBackup {
    /// The day in "inventory-YYYY-MM-DD.json", or nil for any other name.
    static func day(fromFileName name: String) -> KeyDay? {
        guard let m = name.wholeMatch(of: #/inventory-(\d{4}-\d{2}-\d{2})\.json/#) else { return nil }
        return KeyDay(String(m.1))
    }

    /// The backup files, newest first. Nil when the folder is not there (no backup yet); throws when it can't be listed.
    func files() throws -> [BackupFile]? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        return names.filter { $0.hasPrefix("inventory-") && $0.hasSuffix(".json") }.sorted(by: >).map { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path(percentEncoded: false))
            return BackupFile(name: name, day: Self.day(fromFileName: name), bytes: (attributes?[.size] as? NSNumber)?.intValue,
                              modifiedAt: attributes?[.modificationDate] as? Date)
        }
    }

    /// Reads the folder and the newest copy now. Never throws: what could not be read is said in the status.
    func status(now: Date = .now) -> BackupFolderStatus {
        let list: [BackupFile]
        do {
            list = try files() ?? []
        } catch {
            return BackupFolderStatus(checkedAt: now, files: 0, listError: error.localizedDescription)
        }
        guard let newest = list.first else { return BackupFolderStatus(checkedAt: now, files: 0) }
        let file = folder.appending(path: newest.name)
        let check: BackupFolderStatus.Check
        do {
            check = .restores(products: try verify(file).products.count)
        } catch {
            check = .fails(error.localizedDescription)
        }
        var matches: Bool?
        if let current = try? Data(contentsOf: source), let copy = try? Data(contentsOf: file) {
            matches = SHA256.hash(data: current) == SHA256.hash(data: copy)
        }
        return BackupFolderStatus(checkedAt: now, files: list.count, names: list.map(\.name), newest: newest, newestCheck: check,
                                  matchesInventory: matches)
    }

    /// Whether the file the last successful run vouched for is gone, so the job must run again now. A ledger written
    /// before artifacts were recorded has none: then it counts as gone when no file in the folder is named for the day
    /// that run ran (local Gregorian, its start or its end). A run that found the inventory unchanged confirmed an older
    /// file; that costs one extra run, which records the file it vouches for.
    static func artifactMissing(_ state: AutomationJobState?, fileNames: [String],
                                calendar: Calendar = InventoryBackup.gregorian) -> Bool {
        guard let state, state.lastRunDidTheWork, let run = state.lastRun else { return false }
        if let artifact = state.artifact { return !fileNames.contains(artifact) }
        let names = Set(fileNames)
        return !names.contains(fileName(for: run.startedAt, calendar: calendar))
            && !names.contains(fileName(for: run.finishedAt, calendar: calendar))
    }
}

// MARK: - What the Brief and the Desk say about it

/// Lines about the daily backup, from what `Backups/` holds now and what the run log says. The log alone never makes a
/// backup: an empty folder after a "succeeded" run is the first thing said, not hidden behind the green run.
public enum BackupRules {
    /// The job runs daily; a newest copy older than this means it has not been running (or not been able to write).
    public static let staleDays = 2

    public static var sourceText: String { L("Backups/ on this device (inventory-YYYY-MM-DD.json), read back") }

    /// `jobOff`: the backup job is turned off. `pausedUntil`: automation is paused until then. Both change what can be
    /// promised about the next run.
    public static func lines(_ status: BackupFolderStatus?, state: AutomationJobState?, now: Date,
                             calendar: Calendar = InventoryBackup.gregorian, jobOff: Bool = false,
                             pausedUntil: Date? = nil) -> [BriefLine] {
        guard let status else { return [] }
        let source = sourceText
        func line(_ kind: String, _ severity: BriefSeverity, _ text: String, _ detail: String?) -> BriefLine {
            BriefLine(id: "automation.backup.\(kind)", kind: .automation, severity: severity, text: text, detail: detail,
                      source: source, readAt: status.checkedAt, destination: .automation, product: "Linumic OS")
        }
        if let error = status.listError {
            return [line("unreadable", .high, LF("Backups/ could not be read: %@", error), nil)]
        }
        let vouched = state?.lastRunDidTheWork == true ? state?.lastRun?.finishedAt : nil
        guard let newest = status.newest else {
            if let vouched {
                let next: String
                if jobOff {
                    next = L("The file that run wrote is no longer there, and the backup job is turned off, so it does not run again until you turn it on. Until a copy is read back from Backups/, there is no local backup.")
                } else if let until = pausedUntil, until > now {
                    next = LF("The file that run wrote is no longer there. Automation is paused until %@; the backup job runs again after that. Until a copy is read back from Backups/, there is no local backup.",
                              until.formatted(date: .abbreviated, time: .shortened))
                } else {
                    next = L("The file that run wrote is no longer there. The backup job runs again at automation's next look, within 5 minutes; until a copy is read back from Backups/, there is no local backup.")
                }
                return [line("empty", .high,
                             LF("Backups/ is empty, although the run log says the backup of %@ succeeded",
                                vouched.formatted(date: .abbreviated, time: .shortened)),
                             next)]
            }
            return [line("none", .normal, L("No daily backup in Backups/ yet"),
                         L("The backup job writes one when the inventory has loaded, and reads it back."))]
        }
        var out: [BriefLine] = []
        if case .fails(let why) = status.newestCheck {
            out.append(line("restore", .high, LF("The newest backup, %@, does not restore", newest.name), why))
        }
        if let day = newest.day {
            let today = KeyDay(now, calendar: calendar)
            // A run that found the inventory unchanged writes no new file: it confirms the newest one. Its day counts,
            // when it vouched for this very file and the file still holds the inventory as it is now.
            let confirmed = vouched.flatMap { at -> KeyDay? in
                guard state?.artifact == newest.name, status.matchesInventory == true else { return nil }
                return KeyDay(at, calendar: calendar)
            }
            let since = max(day, confirmed ?? day)
            let age = since.days(until: today)
            if age > staleDays {
                let text = since == day
                    ? LF("The newest backup is from %@ (%d days ago)", day.description, age)
                    : LF("The newest backup, %1$@, was last confirmed on %2$@ (%3$d days ago)", newest.name, since.description, age)
                out.append(line("old", .normal, text, L("The backup job has not written or confirmed a copy since then.")))
            }
        }
        if let artifact = state?.artifact, state?.lastRunDidTheWork == true, !status.names.contains(artifact) {
            out.append(line("gone", .normal, LF("%@, which the run log recorded, is gone from Backups/", artifact),
                            LF("The newest copy there now is %@.", newest.name)))
        }
        return out
    }
}
