import Foundation
import LinumicCore
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Desk (میز کار): one list of what needs the owner, built on this device from the Daily Brief and the owner's
/// ledgers (the PRIORITIES.md files and the newest NEXT-ACTIONS). It reads the ledgers read-only, on the Mac, inside
/// the folders the owner granted for them (`LCCLedgerBookmarks`, separate from Keys & Backups, whose grant promises
/// never to read a file). It writes only the owner's marks to `desk-state.json` on this device. No network.
@MainActor
@Observable
final class DeskModel {
    private(set) var state = DeskState()
    /// Set when `desk-state.json` exists but can't be read; the file is then never overwritten.
    private(set) var loadError: String?
    private(set) var reading: LedgerReading?
    private(set) var isReading = false
    /// The granted ledger folders, home-relative, for display.
    private(set) var grantedFolders: [String] = []
    var errorMessage: String?

    private let store: DeskStateStore?
    private let brief: BriefModel
    /// The real home folder (in the sandbox `NSHomeDirectory()` is the app's container).
    let home: String = KeysModel.realHome()

    init(brief: BriefModel) {
        self.brief = brief
        store = (try? DeskStateStore.defaultFileURL()).map(DeskStateStore.init(fileURL:))
        switch store?.load() {
        case .loaded(let s)?: state = s
        case .unreadable(let why)?:
            loadError = String(localized: "desk-state.json could not be read (\(why)). Nothing is saved until the file is fixed or removed.")
        case .empty?, nil: break
        }
        grantedFolders = LedgerAccessStore.grantedPaths().map { KeyPaths.abbreviate($0, home: home) }
    }

    /// Ledgers are read on the Mac only: the owner's folders are not on an iPhone or iPad.
    static var supportsLedgers: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var ledgerInput: DeskLedgerInput {
        guard Self.supportsLedgers else { return .unsupported }
        return reading.map { .read($0) } ?? .notRead
    }

    /// The Desk right now.
    func desk(now: Date = .now) -> Desk {
        DeskBuilder.build(brief: brief.brief(now: now), ledgers: ledgerInput, state: state, now: now)
    }

    // MARK: Reading the ledgers

    /// Reads every allow-listed ledger inside the granted folders, off the main actor. Without any grant it still
    /// records each ledger as "not granted", so the Desk says so instead of showing nothing.
    func refreshLedgers() async {
        #if os(macOS)
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        let home = home
        let urls = LedgerAccessStore.resolveAll()
        grantedFolders = urls.map { KeyPaths.abbreviate($0.path, home: home) }
        reading = await Task.detached(priority: .utility) { () -> LedgerReading in
            let started = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
            return LedgerReader.read(home: home, granted: started.map(\.path), fs: LocalLedgerFileSystem(), now: .now)
        }.value
        #endif
        pruneObsoleteMarks()
    }

    // MARK: Marks (saved at once)

    func markDone(_ item: DeskItem) { mutate { $0.markDone(item, now: .now) } }
    func markWaiting(_ item: DeskItem) { mutate { $0.markWaiting(item, now: .now) } }
    func restore(_ id: String) { mutate { $0.restore(id) } }

    func snooze(_ item: DeskItem, days: Int) {
        let until = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: .now))
            ?? .now.addingTimeInterval(Double(days) * 86_400)
        mutate { $0.snooze(item, until: until, now: .now) }
    }

    /// Dismisses with a reason; false (and nothing saved) when the reason is empty.
    @discardableResult
    func dismiss(_ item: DeskItem, reason: String) -> Bool {
        var ok = false
        mutate { ok = $0.dismiss(item, reason: reason, now: .now) }
        return ok
    }

    /// Drops marks that no longer apply (a snooze that ended, a fact that changed, an item gone from a source read).
    func pruneObsoleteMarks() {
        let obsolete = desk().obsoleteMarks
        guard !obsolete.isEmpty else { return }
        mutate { $0.remove(obsolete) }
    }

    private func mutate(_ change: (inout DeskState) -> Void) {
        guard loadError == nil else {
            errorMessage = loadError
            return
        }
        var copy = state
        change(&copy)
        guard copy != state else { return }
        do {
            try store?.save(copy)
            state = copy
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Actions

    /// The Dari text for an agent, on the clipboard.
    func copyAgentBrief(_ item: DeskItem) {
        let text = DeskAgentBrief.text(for: item, now: .now)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    #if os(macOS)
    /// Opens a ledger file in its default app, inside the granted folder's scope. Nothing is written by the app.
    func openFile(_ path: String) {
        let absolute = KeyPaths.expand(path, home: home)
        let urls = LedgerAccessStore.resolveAll()
        let started = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        guard started.contains(where: { KeyPaths.isInside(absolute, root: $0.path) }) else {
            errorMessage = String(localized: "The folder of \(path) is not granted. Grant it in Settings → Integrations → Ledger access.")
            return
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: absolute)) {
            errorMessage = String(localized: "Could not open \(path).")
        }
    }

    /// Asks the owner to grant read-only access to a ledger folder, then reads at once.
    func chooseFolder(suggested: String) {
        guard LedgerAccessStore.choose(suggested: KeyPaths.expand(suggested, home: home)) != nil else { return }
        grantedFolders = LedgerAccessStore.grantedPaths().map { KeyPaths.abbreviate($0, home: home) }
        Task { await refreshLedgers() }
    }

    func revokeFolders() {
        LedgerAccessStore.removeAll()
        grantedFolders = []
        Task { await refreshLedgers() }
    }
    #endif
}

/// Read-only security-scoped bookmarks to the folders that hold the owner's ledgers (UserDefaults `LCCLedgerBookmarks`).
/// Separate from `LCCKeysBookmarks`: the Keys grant promises that files are never read (KeysModel), while this one
/// reads the allow-listed ledgers, and nothing else, in the folders it covers.
enum LedgerAccessStore {
    private static let defaultsKey = "LCCLedgerBookmarks"

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Paths of the stored grants (for display before they are resolved).
    static func grantedPaths() -> [String] { bookmarks.keys.sorted() }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    #if os(macOS)
    @MainActor
    static func choose(suggested: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: suggested)
        panel.prompt = String(localized: "Grant read access")
        panel.message = String(localized: "Choose a folder that holds your ledgers. Linumic OS reads only the PRIORITIES.md files and the newest NEXT-ACTIONS in it, never anything else, and never writes.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            var all = bookmarks
            all[url.path] = data
            bookmarks = all
            return url
        } catch {
            return nil
        }
    }

    /// Resolves every stored grant, refreshing stale bookmarks.
    static func resolveAll() -> [URL] {
        var out: [URL] = []
        var all = bookmarks
        for (path, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue
            }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                all[path] = fresh
            }
            out.append(url)
        }
        bookmarks = all
        return out
    }
    #else
    static func resolveAll() -> [URL] { [] }
    #endif
}
