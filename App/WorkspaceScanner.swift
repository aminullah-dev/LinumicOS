import Foundation
import LinumicCore
#if os(macOS)
import AppKit
#endif

/// Stores and resolves a security-scoped bookmark to the folder that holds the owner's local
/// repositories, and scans it read-only. The app is sandboxed, so it can only read a folder the
/// user explicitly granted; the bookmark lets that grant persist across launches.
enum WorkspaceStore {
    private static let defaultsKey = "LCCWorkspaceBookmark"
    private static let pathKey = "LCCWorkspacePath"

    /// The display path of the chosen workspace, if any.
    static var displayPath: String? { UserDefaults.standard.string(forKey: pathKey) }
    static var hasWorkspace: Bool { UserDefaults.standard.data(forKey: defaultsKey) != nil }

    #if os(macOS)
    /// Presents a read-only folder picker and stores a security-scoped bookmark to the choice.
    /// Returns the chosen URL, or `nil` if the user cancelled.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder that contains your repositories (read-only).")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
            UserDefaults.standard.set(url.path, forKey: pathKey)
            return url
        } catch {
            return nil
        }
    }
    #endif

    /// Resolves the stored bookmark to a URL, refreshing it if it went stale. `nil` when none is set.
    static func resolvedURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        #if os(macOS)
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: defaultsKey)
        }
        return url
        #else
        return nil
        #endif
    }

    /// Scans the workspace read-only. Returns the per-repository local statuses, or `nil` when no
    /// workspace is set or access could not be started. Runs off the main actor.
    static func scan() async -> [LocalGitStatus]? {
        guard let url = resolvedURL() else { return nil }
        return await Task.detached(priority: .utility) { () -> [LocalGitStatus]? in
            #if os(macOS)
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            #endif
            return LocalGitScanner.scanWorkspace(root: url)
        }.value
    }
}
