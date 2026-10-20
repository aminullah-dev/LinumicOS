import Foundation
import LinumicCore
import Observation
#if os(macOS)
import AppKit
#endif

/// Legal & company (حقوقی و شرکت): the company's status card (registration, the seller per store, DSA) from what the app
/// already holds, and on the Mac the legal folder, read-only: marker counts with file and line, never the text, and the
/// names and dates of Asasnama files, which are never opened. The sandbox check runs first (can the folder be listed
/// without a grant?); when the sandbox refuses, the owner grants the folder once in a picker and the app keeps a
/// read-only security-scoped bookmark (`LCCLegalBookmarks`, its own key: the Keys grant promises never to read a file,
/// the ledgers' grant reads only the ledgers). Nothing is written anywhere, and nothing is kept on disk but the grants.
@MainActor
@Observable
final class LegalModel {
    private(set) var reading: LegalReading?
    private(set) var access: LegalAccessState?
    private(set) var isReading = false
    /// The Asasnama folders granted, home-relative.
    private(set) var asasnamaFolders: [String] = []
    /// Stored Asasnama grants that could not be resolved at the last read, home-relative (kept, tried again).
    private(set) var unresolvedAsasnama: [String] = []
    /// What the sandbox said about the legal folder before any grant, at the last read.
    private(set) var probe: LegalProbe?
    var errorMessage: String?
    private var readAgain = false

    private let inventory: InventoryModel
    let home: String = KeysModel.realHome()

    init(inventory: InventoryModel) {
        self.inventory = inventory
        asasnamaFolders = LegalAccessStore.storedPaths(.asasnama).map { KeyPaths.abbreviate($0, home: home) }
    }

    /// The legal folder is read on the Mac only: the owner's drafts are not on an iPhone or iPad.
    static var readsFolder: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var company: CompanyStatus { CompanyStatusBuilder.build(products: inventory.products) }

    var briefInput: LegalInput {
        LegalInput(reading: reading, access: access, readsFolder: Self.readsFolder, company: company)
    }

    var legalFolderDisplay: String { "~/\(LegalReader.folder)" }

    // MARK: Reading

    /// The sandbox check, then the grants, then the folder: off the main actor, inside the granted scopes only.
    func refresh() async {
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
            let legal = LegalAccessStore.resolve(.legalFolder, home: home)
            let asasnama = LegalAccessStore.resolve(.asasnama, home: home)
            unresolvedAsasnama = asasnama.resolution.unresolved.map { KeyPaths.abbreviate($0, home: home) }
            asasnamaFolders = LegalAccessStore.storedPaths(.asasnama).map { KeyPaths.abbreviate($0, home: home) }
            if !legal.resolution.dropped.isEmpty || !asasnama.resolution.dropped.isEmpty {
                let names = (legal.resolution.dropped + asasnama.resolution.dropped).map { KeyPaths.abbreviate($0.path, home: home) }
                errorMessage = String(localized: "These grants were removed because they no longer lead to the folder they were made for: \(names.joined(separator: ", ")). Grant them again.")
            }
            let legalURLs = legal.urls
            let asasnamaURLs = asasnama.urls
            let outcome = await Task.detached(priority: .utility) { () -> (LegalProbe, Set<String>, LegalReading) in
                let fs = LocalLegalFileSystem()
                let folder = LegalAccessRules.legalFolder(home: home)
                // First, before any scope is started: what the sandbox allows on its own.
                let probe = LegalAccessRules.probe(folder, fs: fs)
                let started = (legalURLs + asasnamaURLs).filter { $0.startAccessingSecurityScopedResource() }
                defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
                // The legal folder's text is read only through its own grant (or the sandbox's leave): an Asasnama grant
                // covers names and dates only.
                var roots = legalURLs.filter { started.contains($0) }.map(\.path)
                if probe == .readable { roots.append(folder) }
                let reading = LegalReader.read(home: home, granted: roots,
                                               asasnamaFolders: asasnamaURLs.filter { started.contains($0) }.map(\.path),
                                               fs: fs, now: .now)
                return (probe, Set(started.map(\.path)), reading)
            }.value
            guard !readAgain else { continue }
            probe = outcome.0
            reading = outcome.2
            access = LegalAccessRules.state(home: home, probe: outcome.0, resolution: legal.resolution, started: outcome.1,
                                            read: outcome.2.state)
        } while readAgain
        #endif
    }

    #if os(macOS)
    // MARK: Grants (read-only, chosen once)

    func chooseLegalFolder() {
        switch LegalAccessStore.choose(.legalFolder, suggested: LegalAccessRules.legalFolder(home: home), home: home) {
        case .cancelled: return
        case .refused(let why), .failed(let why): errorMessage = why
        case .granted: Task { await refresh() }
        }
    }

    func addAsasnamaFolder() {
        switch LegalAccessStore.choose(.asasnama, suggested: KeyPaths.expand("~/Documents", home: home), home: home) {
        case .cancelled: return
        case .refused(let why), .failed(let why): errorMessage = why
        case .granted: Task { await refresh() }
        }
    }

    func removeAsasnamaFolder(_ display: String) {
        LegalAccessStore.remove(.asasnama, path: KeyPaths.expand(display, home: home))
        Task { await refresh() }
    }

    /// Removes every legal grant. What was read through them leaves the screen now, not at the next read.
    func revokeAll() {
        LegalAccessStore.removeAll(.legalFolder)
        LegalAccessStore.removeAll(.asasnama)
        reading = nil
        access = nil
        Task { await refresh() }
    }
    #endif
}

/// Read-only security-scoped bookmarks for Legal & company: the legal folder (`LCCLegalBookmarks`, only
/// ~/Documents/Linumic-Legal is kept) and the folders that hold Asasnama files (`LCCAsasnamaBookmarks`, names and dates
/// only). The rules for what is kept and how a stored grant fails are `LegalAccessRules` (LinumicCore, tested).
enum LegalAccessStore {
    enum ChooseResult {
        case granted(URL)
        /// Not a folder this grant accepts; nothing was saved. The reason as shown.
        case refused(String)
        case failed(String)
        case cancelled
    }

    private static func key(_ role: LegalGrantRole) -> String {
        switch role {
        case .legalFolder: "LCCLegalBookmarks"
        case .asasnama: "LCCAsasnamaBookmarks"
        }
    }

    private static func bookmarks(_ role: LegalGrantRole) -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key(role)) as? [String: Data] ?? [:]
    }

    private static func set(_ role: LegalGrantRole, _ value: [String: Data]) {
        UserDefaults.standard.set(value, forKey: key(role))
    }

    static func storedPaths(_ role: LegalGrantRole) -> [String] { bookmarks(role).keys.sorted() }

    static func remove(_ role: LegalGrantRole, path: String) {
        var all = bookmarks(role)
        all[path] = nil
        set(role, all)
    }

    static func removeAll(_ role: LegalGrantRole) {
        UserDefaults.standard.removeObject(forKey: key(role))
    }

    #if os(macOS)
    @MainActor
    static func choose(_ role: LegalGrantRole, suggested: String, home: String) -> ChooseResult {
        let message = switch role {
        case .legalFolder: String(localized: "Choose ~/Documents/Linumic-Legal. Linumic OS counts the [TO FILL], [LAWYER] and [TO DECIDE] markers in its text files with their file and line, lists Asasnama files by name and date, and never shows, keeps or sends any text. It never writes.")
        case .asasnama: String(localized: "Choose a folder that holds Asasnama files. Linumic OS reads only the names and dates of files whose name says Asasnama, never opens them, and never writes.")
        }
        guard let url = FolderGrant.choose(suggested: suggested, message: message) else { return .cancelled }
        if case .refuse(let why) = LegalAccessRules.decide(url.path, role: role, home: home) { return .refused(why) }
        do {
            var all = bookmarks(role)
            all[url.path] = try FolderGrant.bookmark(url)
            set(role, all)
            return .granted(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Resolves the stored grants of one role (`LegalAccessRules.resolve`), stores back what is kept (stale ones
    /// remade), and returns the URLs to open scopes on.
    static func resolve(_ role: LegalGrantRole, home: String) -> (resolution: LegalBookmarkResolution, urls: [URL]) {
        var urls: [String: URL] = [:]
        let resolution = LegalAccessRules.resolve(stored: bookmarks(role), role: role, home: home, resolve: { data in
            let (url, stale) = try FolderGrant.resolve(data)
            urls[LegalAccessRules.standardized(url.path)] = url
            return (url.path, stale)
        }, rebookmark: { path in
            urls[LegalAccessRules.standardized(path)].flatMap { try? FolderGrant.bookmark($0) }
        })
        set(role, resolution.store)
        return (resolution, resolution.resolved.compactMap { urls[LegalAccessRules.standardized($0)] })
    }
    #else
    static func resolve(_ role: LegalGrantRole, home: String) -> (resolution: LegalBookmarkResolution, urls: [URL]) {
        (LegalBookmarkResolution(), [])
    }
    #endif
}

#if os(macOS)
/// The folder picker and the read-only security-scoped bookmark, shared by Legal & company and the Marketing queue.
enum FolderGrant {
    @MainActor
    static func choose(suggested: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: suggested)
        panel.prompt = String(localized: "Grant read access")
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) throws -> (URL, Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}
#endif
