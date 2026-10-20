import Foundation

// MARK: - Access to the legal folder (sandbox check first, then a one-time read-only grant)
//
// The app is sandboxed. Checked on 2026-10-20 with a probe signed with the app's own file entitlements: inside the
// sandbox, `lstat` of ~/Documents and ~/Desktop works (metadata) but listing or opening anything there is refused
// ("Operation not permitted"); ~/Projects/Multiplatform reads through its exception. So the app first tries the folder
// without a grant (`probe`); when the sandbox refuses, the owner grants it once in a folder picker, which the app keeps
// as a read-only security-scoped bookmark (the Keys & Backups pattern, its own key). No new entitlement. The decisions
// and the failure states of a stored grant are here, without AppKit, so they are tested.

/// What a grant is for.
public enum LegalGrantRole: String, Sendable, Hashable, CaseIterable {
    /// ~/Documents/Linumic-Legal: markers counted in its text files, Asasnama names and dates.
    case legalFolder
    /// A folder that holds Asasnama files: their names and dates only.
    case asasnama
}

/// Whether a folder the owner picked may be kept as a grant.
public enum LegalGrantDecision: Hashable, Sendable {
    case accept
    /// Not kept; the reason as shown.
    case refuse(String)
}

/// A stored grant that was removed when the grants were resolved.
public struct LegalDroppedGrant: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The folder is not one this role accepts (an older or hand-made entry).
        case notAllowed
        /// The bookmark now leads to another folder (the folder was moved or renamed).
        case moved(to: String)
    }

    public var path: String
    public var reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

/// The stored grants of one role after resolving them.
public struct LegalBookmarkResolution: Hashable, Sendable {
    /// Grants that resolved to the folder they were made for (absolute paths).
    public var resolved: [String] = []
    /// Grants that could not be resolved now. They are kept (the failure may pass) and tried again at the next read.
    public var unresolved: [String] = []
    public var dropped: [LegalDroppedGrant] = []
    /// What to store back: every kept grant, stale bookmarks remade.
    public var store: [String: Data] = [:]
    /// Paths whose stale bookmark was remade.
    public var refreshed: [String] = []

    public init() {}
}

/// What the sandbox says about a folder before any grant (the TCC and sandbox check).
public enum LegalProbe: Hashable, Sendable {
    /// The app can list it without a grant (not sandboxed, or an exception covers it).
    case readable
    /// Listing it is refused; the reason as the system gives it.
    case refused(String)
    /// Nothing is there.
    case notFound
}

/// Where the legal folder's access stands, for the screen, the Desk and the job.
public enum LegalAccessState: Hashable, Sendable {
    /// Readable without a grant (the sandbox check passed).
    case readableWithoutGrant
    /// No grant, and the sandbox refuses the folder without one.
    case notGranted
    case granted
    /// A grant is stored but could not be resolved at the last read; kept and tried again.
    case unresolved
    /// A grant resolved but macOS refused to use it, or the folder could not be read through it; the reason as shown.
    case denied(String)
    /// The stored grant led to another folder (moved or renamed); it was removed. Grant the folder again.
    case moved(to: String)
    /// Granted, and the folder is not there.
    case notFound

    /// The folder was read through this access.
    public var canRead: Bool {
        switch self {
        case .readableWithoutGrant, .granted: true
        default: false
        }
    }

    /// What the owner should do, or nil when nothing is needed.
    public var ownerStep: String? {
        switch self {
        case .readableWithoutGrant, .granted: nil
        case .notGranted: L("Grant the legal folder once (Legal & company → Grant…). The app reads it read-only.")
        case .unresolved: L("The stored grant could not be resolved. It is tried again at the next read; grant the folder again if this stays.")
        case .denied: L("macOS refused the stored grant. Remove access and grant the folder again.")
        case .moved: L("The granted folder was moved or renamed, so the grant was removed. Grant ~/Documents/Linumic-Legal again.")
        case .notFound: L("~/Documents/Linumic-Legal is not there. Put the legal drafts back there, or grant it again where it is now.")
        }
    }
}

public enum LegalAccessRules {
    /// The legal folder, absolute.
    public static func legalFolder(home: String) -> String { KeyPaths.expand("~/\(LegalReader.folder)", home: home) }

    public static func standardized(_ path: String) -> String { KeyPaths.trimmed(URL(fileURLWithPath: path).standardizedFileURL.path) }

    /// Whether a folder the owner picked is kept. The legal grant takes exactly ~/Documents/Linumic-Legal: a wider folder
    /// (~/Documents, the home folder) would be a lasting read grant over far more than the drafts. An Asasnama folder may
    /// be any folder below the home folder, but not the home folder or one above it, and not the legal folder (its
    /// Asasnama files are already listed).
    public static func decide(_ chosen: String, role: LegalGrantRole, home: String) -> LegalGrantDecision {
        let path = standardized(chosen)
        let legal = standardized(legalFolder(home: home))
        let h = standardized(home)
        switch role {
        case .legalFolder:
            return path == legal ? .accept : .refuse(LF("Only ~/%@ is accepted for the legal grant, so nothing was saved.", LegalReader.folder))
        case .asasnama:
            if path == legal { return .refuse(L("The legal folder's Asasnama files are already listed through its own grant.")) }
            guard KeyPaths.isInside(path, root: h), path != h else {
                return .refuse(L("Choose a folder inside your home folder that holds the Asasnama files, not the home folder or one above it."))
            }
            return .accept
        }
    }

    /// Resolves the stored grants of one role. `resolve` turns bookmark data into the folder it leads to (throws when it
    /// can't now); `rebookmark` remakes a stale one. A grant of a folder the role does not accept is dropped, and so is
    /// one that now leads elsewhere (a moved folder: keeping it would say "granted" for a grant that reads nothing). One
    /// that can't be resolved is kept and reported, so a passing failure never makes the owner grant it again.
    public static func resolve(stored: [String: Data], role: LegalGrantRole, home: String,
                               resolve: (Data) throws -> (path: String, isStale: Bool),
                               rebookmark: (String) -> Data?) -> LegalBookmarkResolution {
        var out = LegalBookmarkResolution()
        for (path, data) in stored.sorted(by: { $0.key < $1.key }) {
            guard decide(path, role: role, home: home) == .accept else {
                out.dropped.append(LegalDroppedGrant(path: path, reason: .notAllowed))
                continue
            }
            let target: (path: String, isStale: Bool)
            do {
                target = try resolve(data)
            } catch {
                out.unresolved.append(path)
                out.store[path] = data
                continue
            }
            guard standardized(target.path) == standardized(path) else {
                out.dropped.append(LegalDroppedGrant(path: path, reason: .moved(to: target.path)))
                continue
            }
            if target.isStale, let fresh = rebookmark(target.path) {
                out.store[path] = fresh
                out.refreshed.append(path)
            } else {
                out.store[path] = data
            }
            out.resolved.append(path)
        }
        return out
    }

    /// The sandbox check: whether the folder can be listed without a grant.
    public static func probe(_ folder: String, fs: LegalFileSystem) -> LegalProbe {
        do {
            return try fs.names(inDirectory: folder) == nil ? .notFound : .readable
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Where the legal folder's access stands. `started` are the resolved grants whose security scope started; `read` is
    /// the folder's state at the last reading through that access, when there was one.
    public static func state(home: String, probe: LegalProbe, resolution: LegalBookmarkResolution, started: Set<String>,
                             read: LegalFolderState?) -> LegalAccessState {
        let folder = standardized(legalFolder(home: home))
        func afterRead(_ access: LegalAccessState) -> LegalAccessState {
            switch read {
            case .notFound?: .notFound
            case .unreadable(let why)?: .denied(why)
            default: access
            }
        }
        if resolution.resolved.contains(where: { standardized($0) == folder }) {
            guard started.contains(where: { standardized($0) == folder }) else {
                return .denied(L("macOS did not let the app use the stored grant."))
            }
            return afterRead(.granted)
        }
        switch probe {
        case .readable: return afterRead(.readableWithoutGrant)
        case .notFound: return .notFound
        case .refused: break
        }
        if resolution.unresolved.contains(where: { standardized($0) == folder }) { return .unresolved }
        if let moved = resolution.dropped.first(where: { standardized($0.path) == folder }), case .moved(let to) = moved.reason {
            return .moved(to: to)
        }
        return .notGranted
    }
}
