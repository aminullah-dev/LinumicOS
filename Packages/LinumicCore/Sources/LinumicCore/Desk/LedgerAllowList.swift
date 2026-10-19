import Foundation

// MARK: - Which files the Desk may read
//
// The owner grants two folders once (read-only security-scoped bookmarks, `LCCLedgerBookmarks`). Those folders also
// hold code, keys and `.env` files, so the app reads only the files named here: the eight PRIORITIES.md files and the
// newest NEXT-ACTIONS-<day>.md directly in ~/Projects/Multiplatform. Nothing else is opened, and nothing is written.

/// One ledger the Desk reads, by its path relative to the home folder.
public struct LedgerSource: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case priorities
        /// The newest NEXT-ACTIONS-<day>.md in the folder `path`.
        case nextActions
    }

    public let id: String
    /// Home-relative: "Projects/Multiplatform/WorkTrack/PRIORITIES.md"; for NEXT-ACTIONS, the folder.
    public let path: String
    public let domain: DeskDomain
    public let kind: Kind

    public init(_ id: String, _ path: String, _ domain: DeskDomain, kind: Kind = .priorities) {
        self.id = id
        self.path = path
        self.domain = domain
        self.kind = kind
    }

    /// "~/Projects/Multiplatform/WorkTrack/PRIORITIES.md", or "~/Projects/Multiplatform/NEXT-ACTIONS-*.md".
    public var displayPath: String {
        kind == .nextActions ? "~/\(path)/\(NextActionsParser.filePrefix)*.md" : "~/\(path)"
    }
}

public enum LedgerAllowList {
    /// The folders the owner grants (home-relative). Every allowed file is inside one of them.
    /// BE-PAYA (the game) was left out on the owner's word, 2026-10-19.
    public static let folders = ["Projects/Multiplatform"]

    public static let priorities: [LedgerSource] = [
        LedgerSource("shared", "Projects/Multiplatform/PRIORITIES.md", .shared),
        LedgerSource("worktrack", "Projects/Multiplatform/WorkTrack/PRIORITIES.md", .worktrack),
        LedgerSource("safebeauty", "Projects/Multiplatform/Safe beauty/PRIORITIES.md", .safeBeauty),
        LedgerSource("talar", "Projects/Multiplatform/Talar/PRIORITIES.md", .talar),
        LedgerSource("velro", "Projects/Multiplatform/Velro/PRIORITIES.md", .velro),
        LedgerSource("dukanpro", "Projects/Multiplatform/DukanPro/PRIORITIES.md", .dukanPro),
        LedgerSource("linumicos", "Projects/Multiplatform/Linumic/LinumicCommandCenter/PRIORITIES.md", .linumicOS),
    ]

    public static let nextActions = LedgerSource("next-actions", "Projects/Multiplatform", .shared, kind: .nextActions)

    public static var all: [LedgerSource] { priorities + [nextActions] }

    /// Whether the app may open this home-relative path: exactly one of the PRIORITIES.md files above, or a file named
    /// NEXT-ACTIONS-YYYY-MM-DD.md directly in the NEXT-ACTIONS folder. Absolute paths, "..", "." and empty components are
    /// refused, so no spelling reaches another file.
    public static func allows(_ relativePath: String) -> Bool {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        if priorities.contains(where: { $0.path == relativePath }) { return true }
        let folder = parts.dropLast().joined(separator: "/")
        return folder == nextActions.path && NextActionsParser.day(fromFileName: String(parts.last!)) != nil
    }

    /// The PRIORITIES.md of a product, for "read PRIORITIES.md first".
    public static func priorities(for domain: DeskDomain) -> LedgerSource? {
        priorities.first { $0.domain == domain }
    }
}

// MARK: - Reading (behind a file system, so tests need no disk)

public struct LedgerFileInfo: Hashable, Sendable {
    public var isRegularFile: Bool
    public var isSymbolicLink: Bool
    public var size: Int64

    public init(isRegularFile: Bool, isSymbolicLink: Bool = false, size: Int64) {
        self.isRegularFile = isRegularFile
        self.isSymbolicLink = isSymbolicLink
        self.size = size
    }
}

public protocol LedgerFileSystem: Sendable {
    /// What is at `path` without following a link; nil when nothing is there. Throws when it can't be checked (no
    /// permission), which is not the same as "not there".
    func info(atPath path: String) throws -> LedgerFileInfo?
    /// The UTF-8 text of one regular file of at most `maxBytes`, never through a link at its last part, and only when
    /// the file actually opened lies inside one of `roots` (folders on the way may be links; where they lead is checked).
    func readText(atPath path: String, maxBytes: Int64, roots: [String]) throws -> String
    /// File names in a directory; nil when the directory is not there. Throws when it can't be listed.
    func names(inDirectory path: String) throws -> [String]?
}

/// Why a ledger file was not read, in words for the owner.
public enum LedgerReadError: LocalizedError, Equatable {
    case symbolicLink
    case notRegularFile
    case tooLarge(Int64)
    case notUTF8
    case outsideGrant
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .symbolicLink: L("It is a symbolic link; only regular files are read.")
        case .notRegularFile: L("It is not a regular file.")
        case .tooLarge(let max): LF("Larger than %d KB, so not read.", Int(max / 1000))
        case .notUTF8: L("It is not UTF-8 text, so it was not read.")
        case .outsideGrant: L("Its real location is outside the granted folder, so it was not read.")
        case .system(let message): message
        }
    }
}

/// The real file system, with POSIX calls so that what is checked is what is read: `lstat` (no link followed),
/// `open` with `O_NOFOLLOW`, `fstat` on the open file (type and size), at most `maxBytes` read, and `F_GETPATH` on
/// the open file to check where it really is.
public struct LocalLedgerFileSystem: LedgerFileSystem {
    public init() {}

    public func info(atPath path: String) throws -> LedgerFileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw LedgerReadError.system(Self.message(code))
        }
        let type = st.st_mode & S_IFMT
        return LedgerFileInfo(isRegularFile: type == S_IFREG, isSymbolicLink: type == S_IFLNK, size: Int64(st.st_size))
    }

    public func readText(atPath path: String, maxBytes: Int64, roots: [String]) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            throw code == ELOOP ? LedgerReadError.symbolicLink : LedgerReadError.system(Self.message(code))
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw LedgerReadError.system(Self.message(errno)) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw LedgerReadError.notRegularFile }
        guard Int64(st.st_size) <= maxBytes else { throw LedgerReadError.tooLarge(maxBytes) }
        // Where the open file really is: a folder on the way may be a link that leads out of the grant.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw LedgerReadError.system(Self.message(errno)) }
        let real = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let realRoots = roots.map { root in realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root }
        guard realRoots.contains(where: { KeyPaths.isInside(real, root: $0) }) else { throw LedgerReadError.outsideGrant }
        // Read at most maxBytes + 1, so a file that grew after fstat is refused rather than read in full.
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while Int64(data.count) <= maxBytes {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw LedgerReadError.system(Self.message(errno))
            }
            if n == 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        guard Int64(data.count) <= maxBytes else { throw LedgerReadError.tooLarge(maxBytes) }
        guard let text = String(data: data, encoding: .utf8) else { throw LedgerReadError.notUTF8 }
        return text
    }

    public func names(inDirectory path: String) throws -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw LedgerReadError.system(error.localizedDescription)
        }
    }

    static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

public enum LedgerContent: Hashable, Sendable {
    case priorities(ParsedLedger)
    case nextActions(ParsedNextActions)
}

public enum LedgerFileStatus: Hashable, Sendable {
    case read(LedgerContent)
    /// No granted folder covers the file.
    case notGranted
    /// Granted, and nothing is there (for NEXT-ACTIONS: no NEXT-ACTIONS-<day>.md in the folder).
    case notFound
    /// There, but not read (a link, too large, not UTF-8, refused by the allow-list). The reason is shown as is.
    case unreadable(String)
}

public struct LedgerFileReading: Hashable, Sendable, Identifiable {
    public var source: LedgerSource
    /// The home-relative file that was read (for NEXT-ACTIONS, the newest file), or the source's path.
    public var path: String
    public var status: LedgerFileStatus

    public var id: String { source.id }

    public init(source: LedgerSource, path: String, status: LedgerFileStatus) {
        self.source = source
        self.path = path
        self.status = status
    }

    public var displayPath: String {
        if case .read = status { return "~/\(path)" }
        return source.kind == .nextActions && path == source.path ? source.displayPath : "~/\(path)"
    }

    public var isRead: Bool { if case .read = status { true } else { false } }
}

/// One reading of every allow-listed ledger.
public struct LedgerReading: Hashable, Sendable {
    public var readAt: Date
    public var files: [LedgerFileReading]

    public init(readAt: Date, files: [LedgerFileReading]) {
        self.readAt = readAt
        self.files = files
    }

    public func file(_ id: String) -> LedgerFileReading? { files.first { $0.id == id } }
}

public enum LedgerReader {
    /// A PRIORITIES.md is a few kilobytes; anything far larger is not a ledger.
    public static let maxBytes: Int64 = 1_000_000

    /// Reads every allow-listed ledger under `home`. `granted` are the absolute folders the owner granted; a file in no
    /// granted folder is "not granted" and is not touched.
    public static func read(home: String, granted: [String], fs: LedgerFileSystem, now: Date) -> LedgerReading {
        let access = KeyAccess(roots: granted)
        var files: [LedgerFileReading] = LedgerAllowList.priorities.map { source in
            LedgerFileReading(source: source, path: source.path,
                              status: readFile(source.path, home: home, access: access, fs: fs).map { .read(.priorities(LedgerParser.parse($0))) })
        }
        files.append(readNextActions(home: home, access: access, fs: fs))
        return LedgerReading(readAt: now, files: files)
    }

    static func readNextActions(home: String, access: KeyAccess, fs: LedgerFileSystem) -> LedgerFileReading {
        let source = LedgerAllowList.nextActions
        let folder = absolute(source.path, home: home)
        guard access.isGranted(folder) else { return LedgerFileReading(source: source, path: source.path, status: .notGranted) }
        let names: [String]?
        do {
            names = try fs.names(inDirectory: folder)
        } catch {
            return LedgerFileReading(source: source, path: source.path, status: .unreadable(error.localizedDescription))
        }
        guard let names, let newest = NextActionsParser.newest(names) else {
            return LedgerFileReading(source: source, path: source.path, status: .notFound)
        }
        let path = "\(source.path)/\(newest)"
        let status = readFile(path, home: home, access: access, fs: fs).map { .read(.nextActions(NextActionsParser.parse($0, fileName: newest))) }
        return LedgerFileReading(source: source, path: path, status: status)
    }

    /// The text of one allow-listed file, or why it was not read.
    static func readFile(_ relativePath: String, home: String, access: KeyAccess, fs: LedgerFileSystem) -> Outcome {
        guard LedgerAllowList.allows(relativePath) else { return .failed(.unreadable(L("Not on the ledger allow-list, so not read."))) }
        let path = absolute(relativePath, home: home)
        guard access.isGranted(path) else { return .failed(.notGranted) }
        do {
            // Only "nothing there" is "not found"; a denied check is "could not be read".
            guard let info = try fs.info(atPath: path) else { return .failed(.notFound) }
            if info.isSymbolicLink { throw LedgerReadError.symbolicLink }
            guard info.isRegularFile else { throw LedgerReadError.notRegularFile }
            guard info.size <= maxBytes else { throw LedgerReadError.tooLarge(maxBytes) }
            return .text(try fs.readText(atPath: path, maxBytes: maxBytes, roots: access.roots))
        } catch {
            return .failed(.unreadable(error.localizedDescription))
        }
    }

    enum Outcome {
        case text(String)
        case failed(LedgerFileStatus)

        func map(_ parse: (String) -> LedgerFileStatus) -> LedgerFileStatus {
            switch self {
            case .text(let t): parse(t)
            case .failed(let status): status
            }
        }
    }

    static func absolute(_ relativePath: String, home: String) -> String {
        KeyPaths.trimmed(home) + "/" + relativePath
    }
}
