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
    /// A read was asked for while one was running (a grant changed, the job came round): one more read follows, so the
    /// Desk never keeps lines from a grant that was just removed.
    private var readAgain = false
    /// The granted ledger folders, home-relative, for display.
    private(set) var grantedFolders: [String] = []
    /// Stored grants whose bookmark could not be resolved at the last read, home-relative. They are kept (the failure
    /// may pass) and skipped for that read; Settings says so.
    private(set) var unresolvedFolders: [String] = []
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
        grantedFolders = LedgerAccessStore.grantedPaths(home: home).map { KeyPaths.abbreviate($0, home: home) }
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
        guard !isReading else {
            readAgain = true
            return
        }
        isReading = true
        defer { isReading = false }
        repeat {
            readAgain = false
            let home = home
            let resolved = LedgerAccessStore.resolveAll(home: home)
            let urls = resolved.urls
            let entitled = LedgerAccessStore.entitledFolders(home: home)
            grantedFolders = Array(Set(urls.map(\.path) + entitled)).sorted().map { KeyPaths.abbreviate($0, home: home) }
            unresolvedFolders = resolved.unresolved.filter { !entitled.contains($0) }.map { KeyPaths.abbreviate($0, home: home) }
            let result = await Task.detached(priority: .utility) { () -> LedgerReading in
                let started = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
                let roots = Array(Set(started.map(\.path) + entitled)).sorted()
                return LedgerReader.read(home: home, granted: roots, fs: LocalLedgerFileSystem(), now: .now)
            }.value
            // A read that started before a grant changed is replaced by the next one, never shown.
            if !readAgain { reading = result }
        } while readAgain
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
    /// Opens a ledger file in its default app, inside the granted folder's scope. Nothing is written by the app. Only a
    /// file on the ledger allow-list is opened, whatever path the item carries.
    func openFile(_ path: String) {
        let absolute = KeyPaths.expand(path, home: home)
        let relative = KeyPaths.abbreviate(absolute, home: home)
        guard relative.hasPrefix("~/"), LedgerAllowList.allows(String(relative.dropFirst(2))) else {
            errorMessage = String(localized: "\(path) is not a ledger on the allow-list, so it is not opened.")
            return
        }
        let urls = LedgerAccessStore.resolveAll(home: home).urls
        let started = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        let roots = started.map(\.path) + LedgerAccessStore.entitledFolders(home: home)
        guard roots.contains(where: { KeyPaths.isInside(absolute, root: $0) }) else {
            errorMessage = String(localized: "The folder of \(path) is not granted. Grant it in Settings → Integrations → Ledger access.")
            return
        }
        // The same rules as reading: a regular file with one name, really inside a granted folder. A link (at the file
        // or a folder on the way) would hand its target, e.g. a file under ~/Keys, to the default app.
        let info = try? LocalLedgerFileSystem().info(atPath: absolute)
        guard let info, info.isRegularFile, !info.isSymbolicLink, info.links <= 1,
              let real = Self.realPath(absolute),
              roots.contains(where: { root in KeyPaths.isInside(real, root: Self.realPath(root) ?? root) }) else {
            errorMessage = String(localized: "\(path) is not a regular ledger file inside the granted folder, so it is not opened.")
            return
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: real)) {
            errorMessage = String(localized: "Could not open \(path).")
        }
    }

    /// Asks the owner to grant read-only access to a ledger folder, then reads at once. Only the ledger folders
    /// themselves are accepted: a wider one (the home folder, ~/Projects) would also cover keys and `.env` files.
    func chooseFolder(suggested: String) {
        switch LedgerAccessStore.choose(suggested: KeyPaths.expand(suggested, home: home), home: home) {
        case .cancelled:
            return
        case .refused(let path):
            let allowed = LedgerAllowList.folders.map { "~/\($0)" }.joined(separator: ", ")
            errorMessage = String(localized: "\(KeyPaths.abbreviate(path, home: home)) is not a ledger folder, so it was not granted. Choose exactly one of: \(allowed).")
        case .failed(let why):
            errorMessage = why
        case .granted:
            grantedFolders = LedgerAccessStore.grantedPaths(home: home).map { KeyPaths.abbreviate($0, home: home) }
            Task { await refreshLedgers() }
        }
    }

    func revokeFolders() {
        LedgerAccessStore.removeAll()
        grantedFolders = []
        unresolvedFolders = []
        // Lines read through the removed grant leave the screen now, not at the next read.
        reading = nil
        Task { await refreshLedgers() }
    }

    /// The path with every link resolved, or nil when it can't be resolved.
    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
    #endif
}

/// Read-only security-scoped bookmarks to the folders that hold the owner's ledgers (UserDefaults `LCCLedgerBookmarks`).
/// Separate from `LCCKeysBookmarks`: the Keys grant promises that files are never read (KeysModel), while this one
/// reads the allow-listed ledgers, and nothing else, in the folders it covers. Only the folders named in
/// `LedgerAllowList.folders` are kept: a grant of a wider folder would be a lasting read bookmark over keys and `.env`.
enum LedgerAccessStore {
    private static let defaultsKey = "LCCLedgerBookmarks"

    enum ChooseResult {
        case granted(URL)
        /// Not one of the ledger folders; nothing was saved.
        case refused(String)
        case failed(String)
        case cancelled
    }

    private static var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// The ledger folders as absolute paths under the real home.
    static func allowedFolders(home: String) -> Set<String> {
        Set(LedgerAllowList.folders.map { KeyPaths.expand("~/\($0)", home: home) })
    }

    static func isAllowed(_ path: String, home: String) -> Bool {
        allowedFolders(home: home).contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// Ledger folders the app can read through its read-only sandbox exception (project.yml,
    /// `temporary-exception.files.home-relative-path.read-only`), so no bookmark is needed for them.
    static func entitledFolders(home: String) -> [String] {
        allowedFolders(home: home).filter { FileManager.default.isReadableFile(atPath: $0) }.sorted()
    }

    /// Paths of the ledger folders that can be read: stored grants and the entitled folders (for display and the job).
    static func grantedPaths(home: String = KeysModel.realHome()) -> [String] {
        Array(Set(bookmarks.keys.filter { isAllowed($0, home: home) }).union(entitledFolders(home: home))).sorted()
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    #if os(macOS)
    @MainActor
    static func choose(suggested: String, home: String) -> ChooseResult {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: suggested)
        panel.prompt = String(localized: "Grant read access")
        panel.message = String(localized: "Choose a folder that holds your ledgers. Linumic OS reads only the PRIORITIES.md files and the newest NEXT-ACTIONS in it, never anything else, and never writes.")
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        // Checked before any bookmark is made: nothing is saved for a folder that is not a ledger folder.
        guard isAllowed(url.path, home: home) else { return .refused(url.path) }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            var all = bookmarks
            all[url.path] = data
            bookmarks = all
            return .granted(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Resolves every stored grant of a ledger folder, refreshing stale bookmarks. A stored grant of any other folder
    /// (none can be made any more), or one that resolves somewhere else, is dropped, not used. One that can't be
    /// resolved right now (the call throws) is kept and skipped for this read: the failure may pass, and dropping it
    /// would make the owner grant it again. Its path is returned in `unresolved`, for Settings to say so.
    static func resolveAll(home: String) -> (urls: [URL], unresolved: [String]) {
        var out: [URL] = []
        var unresolved: [String] = []
        var all = bookmarks
        for (path, data) in all {
            guard isAllowed(path, home: home) else {
                all[path] = nil
                continue
            }
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                unresolved.append(path)
                continue
            }
            guard isAllowed(url.path, home: home) else {
                // It resolves to another folder (moved or renamed): drop it, so Settings doesn't say "Granted" for a
                // grant that reads nothing.
                all[path] = nil
                continue
            }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                all[path] = fresh
            }
            out.append(url)
        }
        bookmarks = all
        return (out, unresolved.sorted())
    }
    #else
    static func resolveAll(home: String) -> (urls: [URL], unresolved: [String]) { ([], []) }
    #endif
}
