import Foundation
import LinumicCore
import Observation
#if os(macOS)
import AppKit
#endif

/// Marketing queue (صف بازاریابی), read-only, never posts: each brand's marketing obligations (queue ends, the clock
/// change) from the obligations register, beside the brand's own ledger. Of a ledger the app reads only the file's
/// modification date (metadata, which the sandbox allows without a grant) and never its text. Verify opens the ledger in
/// its own app, inside a read-only grant of that ledger's folder (`LCCMarketingBookmarks`; only the ledgers' own folders
/// are kept), so the owner checks the date there and corrects it, or records Done, on the Obligations screen.
@MainActor
@Observable
final class MarketingQueueModel {
    /// Each ledger's modification date, by ledger id; empty before the first check.
    private(set) var files: [String: MarketingLedgerFile] = [:]
    private(set) var checkedAt: Date?
    /// The ledger folders granted for Verify, home-relative.
    private(set) var grantedFolders: [String] = []
    var errorMessage: String?

    let home: String = KeysModel.realHome()

    init() {
        grantedFolders = MarketingAccessStore.storedPaths().map { KeyPaths.abbreviate($0, home: home) }
    }

    static var readsLedgers: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The brands with their obligations, as the register holds them now.
    func brands(obligations: ObligationsModel, now: Date = .now) -> [MarketingQueueBrand] {
        let calendar = KeyDay.calendar
        var entered: [String: KeyDay] = [:]
        for d in obligations.file.dates.sorted(by: { $0.enteredAt < $1.enteredAt }) {
            entered[d.obligationID] = KeyDay(d.enteredAt, calendar: calendar)
        }
        return MarketingQueue.build(register: obligations.register(now: now), files: files, dateEnteredOn: entered, calendar: calendar)
    }

    /// The ledgers' modification dates (metadata only; no grant needed, nothing opened).
    func refresh() async {
        #if os(macOS)
        let home = home
        files = await Task.detached(priority: .utility) { () -> [String: MarketingLedgerFile] in
            let fs = LocalLegalFileSystem()
            var out: [String: MarketingLedgerFile] = [:]
            for ledger in MarketingLedgers.all {
                let path = KeyPaths.expand(ledger.displayFile, home: home)
                do {
                    guard let entry = try fs.entry(atPath: path) else {
                        out[ledger.id] = .missing
                        continue
                    }
                    out[ledger.id] = entry.kind == .file ? .modified(entry.modifiedAt) : .unknown(String(localized: "It is not a regular file."))
                } catch {
                    out[ledger.id] = .unknown(error.localizedDescription)
                }
            }
            return out
        }.value
        checkedAt = .now
        grantedFolders = MarketingAccessStore.storedPaths().map { KeyPaths.abbreviate($0, home: home) }
        #endif
    }

    #if os(macOS)
    /// Opens the ledger in its own app so the owner can check the dates there. Without a grant of its folder, asks for
    /// one first (that folder only). The app reads nothing of the file.
    func verify(_ ledger: MarketingLedger) {
        let folder = KeyPaths.expand(ledger.displayFolder, home: home)
        let home = home
        func stored() -> URL? {
            MarketingAccessStore.resolved(home: home).first { LegalAccessRules.standardized($0.path) == LegalAccessRules.standardized(folder) }
        }
        var url = stored()
        if url == nil {
            switch MarketingAccessStore.choose(suggested: folder, home: home) {
            case .cancelled: return
            case .refused(let why), .failed(let why):
                errorMessage = why
                return
            case .granted(let granted):
                grantedFolders = MarketingAccessStore.storedPaths().map { KeyPaths.abbreviate($0, home: home) }
                guard LegalAccessRules.standardized(granted.path) == LegalAccessRules.standardized(folder) else {
                    errorMessage = String(localized: "That is another ledger's folder. Press Verify again and choose \(ledger.displayFolder).")
                    return
                }
                // The stored bookmark, not the panel's URL: the same path every later Verify takes.
                url = stored()
            }
        }
        guard let url, url.startAccessingSecurityScopedResource() else {
            errorMessage = String(localized: "macOS refused the grant of \(ledger.displayFolder). Remove access and grant it again.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let file = KeyPaths.expand(ledger.displayFile, home: home)
        // A regular file with one name, really inside the folder: a link would hand its target to the other app.
        guard let entry = try? LocalLegalFileSystem().entry(atPath: file), entry.kind == .file, entry.links <= 1,
              let real = DeskModel.realPath(file), KeyPaths.isInside(real, root: DeskModel.realPath(folder) ?? folder) else {
            errorMessage = String(localized: "\(ledger.displayFile) is not a regular file inside its folder, so it is not opened.")
            return
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: real)) {
            errorMessage = String(localized: "Could not open \(ledger.displayFile).")
        }
    }

    func revokeAll() {
        MarketingAccessStore.removeAll()
        grantedFolders = []
    }
    #endif
}

/// Read-only security-scoped bookmarks to the marketing ledgers' folders (`LCCMarketingBookmarks`). Only a ledger's own
/// folder is kept (`MarketingLedgers.decide`): ~/Desktop/1 as a whole also holds the Asasnama drafts and much else.
enum MarketingAccessStore {
    private static let defaultsKey = "LCCMarketingBookmarks"

    enum ChooseResult {
        case granted(URL)
        case refused(String)
        case failed(String)
        case cancelled
    }

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func storedPaths() -> [String] { bookmarks.keys.sorted() }

    static func removeAll() { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    #if os(macOS)
    @MainActor
    static func choose(suggested: String, home: String) -> ChooseResult {
        let message = String(localized: "Choose this brand's marketing folder. Linumic OS opens its ledger in the ledger's own app when you press Verify, and reads nothing of it itself. It never writes or posts.")
        guard let url = FolderGrant.choose(suggested: suggested, message: message) else { return .cancelled }
        if case .refuse(let why) = MarketingLedgers.decide(url.path, home: home) { return .refused(why) }
        do {
            var all = bookmarks
            all[url.path] = try FolderGrant.bookmark(url)
            bookmarks = all
            return .granted(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The stored grants that resolve to a ledger folder (stale ones remade); any other is dropped.
    static func resolved(home: String) -> [URL] {
        var out: [URL] = []
        var all = bookmarks
        for (path, data) in all {
            guard MarketingLedgers.decide(path, home: home) == .accept, let (url, stale) = try? FolderGrant.resolve(data) else {
                // Not a ledger folder: dropped. One that can't be resolved now is kept for the next try.
                if MarketingLedgers.decide(path, home: home) != .accept { all[path] = nil }
                continue
            }
            guard LegalAccessRules.standardized(url.path) == LegalAccessRules.standardized(path) else {
                all[path] = nil
                continue
            }
            if stale, let fresh = try? FolderGrant.bookmark(url) { all[path] = fresh }
            out.append(url)
        }
        bookmarks = all
        return out
    }
    #endif
}
