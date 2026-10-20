import Foundation

// MARK: - Reading the legal folder (read-only, behind a file system, so tests need no disk)
//
// The owner grants one folder, ~/Documents/Linumic-Legal (docs/legal.md). In it the app reads the text files (.md,
// .markdown, .txt) and counts their markers; it keeps the file, the line and the kind of each marker, nothing of the
// text. Files whose name says Asasnama (the articles of association) are never opened: only their name and modification
// date are kept, here and in any folder the owner adds for them. Every other file is listed as "not read" (a .docx or a
// .pdf may hold markers the app can't count), so a count is "at least" until they are text. Links are never followed.

/// What one entry of a folder is, without following a link. No content.
public struct LegalEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case file, directory, symbolicLink, other
    }

    public var kind: Kind
    public var size: Int64
    public var modifiedAt: Date
    /// How many names the file has; more than one is a hard link.
    public var links: Int

    public init(kind: Kind, size: Int64 = 0, modifiedAt: Date, links: Int = 1) {
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.links = links
    }
}

public protocol LegalFileSystem: Sendable {
    /// What is at `path` without following a link; nil when nothing is there. Throws when it can't be checked.
    func entry(atPath path: String) throws -> LegalEntry?
    /// The names in a directory; nil when it is not there. Throws when it can't be listed (the sandbox refuses it).
    func names(inDirectory path: String) throws -> [String]?
    /// The UTF-8 text of one regular file of at most `maxBytes`, never through a link, only inside one of `roots`.
    func readText(atPath path: String, maxBytes: Int64, roots: [String]) throws -> String
}

/// The real file system: `lstat` for entries (no link followed), and the ledgers' reader for text (`O_NOFOLLOW`, the
/// open file's real path checked against the grant, at most `maxBytes`).
public struct LocalLegalFileSystem: LegalFileSystem {
    public init() {}

    public func entry(atPath path: String) throws -> LegalEntry? {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw LedgerReadError.system(String(cString: strerror(code)))
        }
        let kind: LegalEntry.Kind = switch st.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return LegalEntry(kind: kind, size: Int64(st.st_size), modifiedAt: modified, links: Int(st.st_nlink))
    }

    public func names(inDirectory path: String) throws -> [String]? {
        try LocalLedgerFileSystem().names(inDirectory: path)
    }

    public func readText(atPath path: String, maxBytes: Int64, roots: [String]) throws -> String {
        try LocalLedgerFileSystem().readText(atPath: path, maxBytes: maxBytes, roots: roots)
    }
}

// MARK: - What was read

/// A file whose name says it is an Asasnama: its name and modification date, never its content.
public struct LegalNamedFile: Hashable, Sendable, Identifiable {
    /// The file's name, as on disk.
    public var name: String
    /// The folder it is in, home-relative ("~/Documents/Linumic-Legal").
    public var folder: String
    public var modifiedAt: Date

    public var id: String { "\(folder)/\(name)" }

    public init(name: String, folder: String, modifiedAt: Date) {
        self.name = name
        self.folder = folder
        self.modifiedAt = modifiedAt
    }
}

/// One file of the legal folder and what became of it.
public struct LegalFileResult: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// Read: its markers (kind and line only).
        case read([LegalMarkerHit])
        /// Not a text file (.docx, .pdf, …): markers in it can't be counted. The extension, lower-cased.
        case notText(String)
        /// A text file that could not be read (too large, not UTF-8, a link, refused): the reason as shown.
        case unreadable(String)
    }

    /// Home-relative ("~/Documents/Linumic-Legal/WorkTrack/Terms.md").
    public var path: String
    /// The first folder under the legal folder ("WorkTrack"), or nil for a file directly in it.
    public var group: String?
    public var status: Status

    public var id: String { path }

    public init(path: String, group: String?, status: Status) {
        self.path = path
        self.group = group
        self.status = status
    }

    public var hits: [LegalMarkerHit] { if case .read(let h) = status { h } else { [] } }
    public var isRead: Bool { if case .read = status { true } else { false } }
}

/// The legal folder as last read.
public enum LegalFolderState: Hashable, Sendable {
    /// No grant covers it (and the sandbox refuses it without one).
    case notGranted
    /// Granted, and nothing is there.
    case notFound
    /// There, but it could not be read (the reason as shown, e.g. "Operation not permitted").
    case unreadable(String)
    case read
}

/// A folder searched for Asasnama files, and how it went.
public struct LegalSearchedFolder: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        case read
        case notFound
        case unreadable(String)
    }

    /// Home-relative.
    public var path: String
    public var state: State

    public var id: String { path }

    public init(path: String, state: State) {
        self.path = path
        self.state = state
    }
}

/// One reading of the legal folder and the Asasnama folders.
public struct LegalReading: Hashable, Sendable {
    public var readAt: Date
    /// The legal folder, home-relative.
    public var folder: String
    public var state: LegalFolderState
    public var files: [LegalFileResult]
    public var asasnama: [LegalNamedFile]
    /// Every folder searched for Asasnama files (the legal folder first when it was read).
    public var searched: [LegalSearchedFolder]
    /// Entries left alone: links (never followed), and what lies deeper than `LegalReader.maxDepth` or past
    /// `LegalReader.maxEntries`.
    public var skipped: Int

    public init(readAt: Date, folder: String, state: LegalFolderState, files: [LegalFileResult] = [],
                asasnama: [LegalNamedFile] = [], searched: [LegalSearchedFolder] = [], skipped: Int = 0) {
        self.readAt = readAt
        self.folder = folder
        self.state = state
        self.files = files
        self.asasnama = asasnama
        self.searched = searched
        self.skipped = skipped
    }

    /// Files whose markers are unknown: not text, or not readable.
    public var unreadFiles: [LegalFileResult] { files.filter { !$0.isRead } }

    /// Every marker counted, by kind.
    public func count(_ kind: LegalMarkerKind) -> Int { files.reduce(0) { $0 + $1.hits.count { $0.kind == kind } } }

    /// Whether every file was read, so the counts are exact (otherwise "at least").
    public var isComplete: Bool { state == .read && unreadFiles.isEmpty && skipped == 0 }

    /// The places of one kind, "<file>:<line>" (home-relative), in file and line order; a line with two markers is
    /// named twice, so the list is as long as the count.
    public func locations(_ kind: LegalMarkerKind) -> [String] { locations(kind, in: files) }

    /// The same, for the files of one group.
    public func locations(_ kind: LegalMarkerKind, group: String?) -> [String] {
        locations(kind, in: files.filter { $0.group == group })
    }

    private func locations(_ kind: LegalMarkerKind, in files: [LegalFileResult]) -> [String] {
        files.sorted { $0.path < $1.path }.flatMap { file in
            file.hits.filter { $0.kind == kind }.map { "\(file.path):\($0.line)" }
        }
    }

    /// The groups (first folders under the legal folder, nil for files directly in it) that hold markers of `kind`.
    public func groups(_ kind: LegalMarkerKind) -> [String?] {
        var seen: [String?] = []
        for f in files.sorted(by: { ($0.group ?? "") < ($1.group ?? "") }) where f.hits.contains(where: { $0.kind == kind }) {
            if !seen.contains(f.group) { seen.append(f.group) }
        }
        return seen
    }

    public func count(_ kind: LegalMarkerKind, group: String?) -> Int {
        files.filter { $0.group == group }.reduce(0) { $0 + $1.hits.count { $0.kind == kind } }
    }
}

// MARK: - The reader

public enum LegalReader {
    /// The folder the legal grant is for, home-relative (roadmap module 7).
    public static let folder = "Documents/Linumic-Legal"
    /// Text files whose markers are counted.
    public static let textExtensions: Set<String> = ["md", "markdown", "txt"]
    /// A draft is tens of kilobytes (the largest on 2026-10-20 was 23 KB); anything far larger is not one.
    public static let maxBytes: Int64 = 1_000_000
    /// Folders inside the legal folder are entered this deep; Asasnama folders one level.
    public static let maxDepth = 4
    public static let maxEntries = 500

    /// Whether a file's name says it is an Asasnama (Latin or Persian spelling, any case): never opened.
    public static func isAsasnama(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("asasnama") || lower.contains("asasnameh") || name.contains("اساسنامه")
    }

    static func isHidden(_ name: String) -> Bool { name.hasPrefix(".") }

    /// Reads the legal folder (`<home>/Documents/Linumic-Legal`) if a root of the legal grant covers it, then each
    /// Asasnama folder. `granted` are the legal grant's folders (its security-scoped bookmark, and the legal folder itself
    /// when the sandbox lets the app read it without one); `asasnamaFolders` are folders the caller can list through
    /// their own grants, for names and dates only. An Asasnama grant never makes the legal folder's text readable, even
    /// when it covers it (~/Documents): that grant promised names only.
    public static func read(home: String, granted: [String], asasnamaFolders: [String] = [], fs: LegalFileSystem, now: Date) -> LegalReading {
        let root = KeyPaths.expand("~/\(folder)", home: home)
        let display = "~/\(folder)"
        let access = KeyAccess(roots: granted)
        var reading = LegalReading(readAt: now, folder: display, state: .notGranted)
        if access.isGranted(root) {
            readLegalFolder(root, home: home, roots: access.roots, fs: fs, into: &reading)
        }
        for path in asasnamaFolders.sorted() where !(reading.state == .read && KeyPaths.isInside(path, root: root)) {
            searchAsasnama(path, home: home, fs: fs, into: &reading)
        }
        reading.asasnama.sort { ($0.folder, $0.name) < ($1.folder, $1.name) }
        reading.files.sort { $0.path < $1.path }
        return reading
    }

    static func readLegalFolder(_ root: String, home: String, roots: [String], fs: LegalFileSystem, into reading: inout LegalReading) {
        do {
            guard let entry = try fs.entry(atPath: root) else {
                reading.state = .notFound
                return
            }
            guard entry.kind == .directory else {
                reading.state = .unreadable(entry.kind == .symbolicLink ? L("It is a symbolic link; only a real folder is read.") : L("It is not a folder."))
                return
            }
            guard try fs.names(inDirectory: root) != nil else {
                reading.state = .notFound
                return
            }
        } catch {
            reading.state = .unreadable(error.localizedDescription)
            return
        }
        reading.state = .read
        reading.searched.append(LegalSearchedFolder(path: KeyPaths.abbreviate(root, home: home), state: .read))
        var queue: [(path: String, depth: Int, group: String?)] = [(root, 0, nil)]
        var seen = 0
        while !queue.isEmpty {
            let (dir, depth, group) = queue.removeFirst()
            let names: [String]
            do {
                names = try fs.names(inDirectory: dir)?.sorted() ?? []
            } catch {
                // A folder inside that can't be listed: its files are unknown, never "no markers".
                reading.files.append(LegalFileResult(path: KeyPaths.abbreviate(dir, home: home) + "/", group: group,
                                                     status: .unreadable(error.localizedDescription)))
                continue
            }
            for name in names where !isHidden(name) {
                seen += 1
                guard seen <= maxEntries else { reading.skipped += 1; continue }
                let path = dir + "/" + name
                let display = KeyPaths.abbreviate(path, home: home)
                let entry: LegalEntry?
                do { entry = try fs.entry(atPath: path) } catch {
                    reading.files.append(LegalFileResult(path: display, group: depth == 0 ? nil : group,
                                                         status: .unreadable(error.localizedDescription)))
                    continue
                }
                guard let entry else { continue }
                switch entry.kind {
                case .symbolicLink, .other:
                    reading.skipped += 1
                case .directory:
                    if depth + 1 < maxDepth {
                        queue.append((path, depth + 1, group ?? name))
                    } else {
                        reading.skipped += 1
                    }
                case .file:
                    let fileGroup = depth == 0 ? nil : group
                    if isAsasnama(name) {
                        reading.asasnama.append(LegalNamedFile(name: name, folder: KeyPaths.abbreviate(dir, home: home), modifiedAt: entry.modifiedAt))
                        continue
                    }
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard textExtensions.contains(ext) else {
                        reading.files.append(LegalFileResult(path: display, group: fileGroup, status: .notText(ext)))
                        continue
                    }
                    reading.files.append(LegalFileResult(path: display, group: fileGroup,
                                                         status: readFile(path, entry: entry, roots: roots, fs: fs)))
                }
            }
        }
    }

    static func readFile(_ path: String, entry: LegalEntry, roots: [String], fs: LegalFileSystem) -> LegalFileResult.Status {
        do {
            guard entry.links <= 1 else { throw LedgerReadError.hardLink }
            guard entry.size <= maxBytes else { throw LedgerReadError.tooLarge(maxBytes) }
            let text = try fs.readText(atPath: path, maxBytes: maxBytes, roots: roots)
            return .read(LegalMarkerScanner.scan(text))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Names and dates of the Asasnama files in one folder and the folders directly in it. Nothing is opened.
    static func searchAsasnama(_ root: String, home: String, fs: LegalFileSystem, into reading: inout LegalReading) {
        let display = KeyPaths.abbreviate(root, home: home)
        var dirs = [(root, 0)]
        var first = true
        var seen = 0
        while !dirs.isEmpty {
            let (dir, depth) = dirs.removeFirst()
            let names: [String]?
            do { names = try fs.names(inDirectory: dir) } catch {
                if first { reading.searched.append(LegalSearchedFolder(path: display, state: .unreadable(error.localizedDescription))); return }
                continue
            }
            if first {
                reading.searched.append(LegalSearchedFolder(path: display, state: names == nil ? .notFound : .read))
                first = false
            }
            for name in (names ?? []).sorted() where !isHidden(name) {
                seen += 1
                guard seen <= maxEntries else { break }
                let path = dir + "/" + name
                guard let entry = try? fs.entry(atPath: path) else { continue }
                if entry.kind == .directory, depth < 1 {
                    dirs.append((path, depth + 1))
                } else if entry.kind == .file, isAsasnama(name) {
                    reading.asasnama.append(LegalNamedFile(name: name, folder: KeyPaths.abbreviate(dir, home: home), modifiedAt: entry.modifiedAt))
                }
            }
        }
    }
}
