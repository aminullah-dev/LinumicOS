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
