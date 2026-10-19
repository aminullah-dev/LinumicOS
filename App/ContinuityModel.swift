import Foundation
import LinumicCore
import Observation
#if os(macOS)
import AppKit
#endif

/// Continuity (تداوم): one encrypted copy of the company's records in a folder the owner chooses, off this Mac (a USB
/// stick, Google Drive for desktop). The export is an age file that opens with the standard `age` tool, without
/// Linumic OS (docs/continuity.md). It is read back from the folder, decrypted and compared before it counts; the log
/// (`continuity.json`) keeps that evidence. The passphrase is typed for each export and never stored. No network.
@MainActor
@Observable
final class ContinuityModel {
    private(set) var log = ContinuityLog()
    /// Set when `continuity.json` exists but can't be read; the file is then never overwritten.
    private(set) var loadError: String?
    private(set) var isWorking = false
    /// The chosen folder, as shown (home-relative, or the volume path), and where it is.
    private(set) var folderPath: String?
    private(set) var folderKind: ContinuityFolderKind?
    /// The record of the export just made (or checked again), shown until the next action.
    private(set) var lastResult: ContinuityExportRecord?
    var errorMessage: String?

    private let store: ContinuityStore?
    let home: String = KeysModel.realHome()

    init() {
        store = (try? ContinuityStore.defaultFileURL()).map(ContinuityStore.init(fileURL:))
        switch store?.load() {
        case .loaded(let l)?: log = l
        case .unreadable(let why)?:
            loadError = String(localized: "continuity.json could not be read (\(why)). Exports can still be made, but nothing is recorded until the file is fixed or removed.")
        case .empty?, nil: break
        }
        refreshFolder()
    }

    /// Exports are made on the Mac, where the folder can be chosen and kept.
    var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: The folder

    func refreshFolder() {
        guard let url = ContinuityFolderStore.resolve() else {
            folderPath = nil
            folderKind = nil
            return
        }
        folderPath = Self.display(url.path, home: home)
        let internalVolume = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal
        folderKind = ContinuityFolderKind.classify(path: url.path, volumeIsInternal: internalVolume)
    }

    static func display(_ path: String, home: String) -> String {
        KeyPaths.abbreviate(path, home: home)
    }

    #if os(macOS)
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use this folder")
        panel.message = String(localized: "Choose a folder off this Mac: a USB stick or a Google Drive for desktop folder. Linumic OS writes only its encrypted export files there and reads them back to check them.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ContinuityFolderStore.save(url)
            refreshFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func forgetFolder() {
        ContinuityFolderStore.remove()
        refreshFolder()
    }

    // MARK: Export and checks

    /// Builds the bundle from what the app holds now: the inventory, the obligations and accounts, the licence ledger
    /// (without key text) and the keys registry.
    func bundle(inventory: InventoryModel, obligations: ObligationsModel, licences: LicenceModel, keys: KeysModel,
                now: Date = .now) -> ContinuityBundle {
        let register = obligations.register(now: now)
        let info = Bundle.main.infoDictionary
        let version = "Linumic OS \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return ContinuityBundle(createdAt: now, app: version, inventory: inventory.current, obligationEntries: obligations.file,
                                obligations: register.obligations, accounts: register.accounts, licences: licences.records,
                                licencesSyncedAt: licences.lastSyncedAt, keysRegistry: keys.loadError == nil ? keys.registry : nil)
    }

    /// Encrypts, writes, reads back and checks; records the evidence only when every step held. The passphrase lives
    /// only for this call.
    func export(_ bundle: ContinuityBundle, passphrase: String) async {
        guard !isWorking else { return }
        guard let url = ContinuityFolderStore.resolve(), let folderPath else {
            errorMessage = String(localized: "Choose a folder first.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        lastResult = nil
        let kind = folderKind ?? .unknown
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ContinuityExportRecord, Error> in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return Result {
                try ContinuityExporter.export(bundle, passphrase: passphrase, to: url, folderName: folderPath, folderKind: kind, now: .now)
            }
        }.value
        switch result {
        case .success(let made):
            lastResult = made
            update { $0.add(made) }
        case .failure(let error):
            errorMessage = String(localized: "The export was not recorded: \(error.localizedDescription)")
        }
    }

    /// Reads an earlier export back from the folder and checks it again with the passphrase.
    func reverify(_ record: ContinuityExportRecord, passphrase: String) async {
        guard !isWorking else { return }
        guard let url = ContinuityFolderStore.resolve() else {
            errorMessage = String(localized: "Choose the folder that holds the export first.")
            return
        }
        isWorking = true
        defer { isWorking = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Date, Error> in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            return Result { try ContinuityExporter.reverify(record, in: url, passphrase: passphrase, now: .now) }
        }.value
        switch result {
        case .success(let at):
            update { $0.markReverified(record.id, at: at) }
            lastResult = log.exports.first { $0.id == record.id }
        case .failure(let error):
            errorMessage = String(localized: "\(record.fileName) did not pass the check: \(error.localizedDescription)")
        }
    }

    /// The owner opened an export on another computer: recorded with what proves it.
    @discardableResult
    func recordOutsideCheck(_ record: ContinuityExportRecord, on day: KeyDay, evidence: String) -> Bool {
        var ok = false
        update { log in
            do {
                try log.recordOutsideCheck(record.id, on: day, evidence: evidence, now: .now)
                ok = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return ok
    }

    private func update(_ change: (inout ContinuityLog) -> Void) {
        guard loadError == nil else {
            errorMessage = loadError
            return
        }
        var copy = log
        change(&copy)
        guard copy != log else { return }
        do {
            try store?.save(copy)
            log = copy
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The export folder as a read-write security-scoped bookmark (UserDefaults `LCCContinuityFolder`), chosen by the
/// owner in an open panel (the user-selected read-write entitlement). Only export files are written there.
enum ContinuityFolderStore {
    private static let key = "LCCContinuityFolder"

    static func save(_ url: URL) throws {
        #if os(macOS)
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
        #endif
    }

    static func remove() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func resolve() -> URL? {
        #if os(macOS)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return url
        #else
        return nil
        #endif
    }
}
