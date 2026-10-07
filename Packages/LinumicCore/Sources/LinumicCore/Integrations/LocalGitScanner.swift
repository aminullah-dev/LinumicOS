import Foundation
import CryptoKit

/// Reads a working copy's status directly from its `.git` directory. Pure file reads only: no
/// process is spawned (the app is sandboxed and cannot run `git`). Every method reports only what
/// it can read exactly; unreadable facts come back `nil` (Unknown), never guessed.
public enum LocalGitScanner {

    /// Scans one repository. `url` is the working directory (the folder that contains `.git`).
    /// Returns `nil` when there is no readable `.git` directory there.
    public static func scan(repoDirectory url: URL, now: () -> Date = { .now }) -> LocalGitStatus? {
        let gitDir = url.appendingPathComponent(".git", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil   // no .git directory (a worktree's .git file is not handled here)
        }

        var status = LocalGitStatus(path: url.path, scannedAt: now())
        status.originSlug = originSlug(gitDir: gitDir)

        // HEAD → branch or detached tip.
        if let head = readString(gitDir.appendingPathComponent("HEAD")) {
            if head.hasPrefix("ref:") {
                let ref = head.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
                status.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                status.isDetached = false
                status.localTip = resolveRef(ref, gitDir: gitDir)
            } else if isHex(head) {
                status.isDetached = true
                status.localTip = head
            }
        }

        if let branch = status.branch {
            status.remoteTip = resolveRef("refs/remotes/origin/\(branch)", gitDir: gitDir)
        }

        status.modifiedTrackedFiles = modifiedTrackedCount(gitDir: gitDir, workdir: url)
        return status
    }

    /// Finds every repository under `root` (a directory that contains `.git`), up to `maxDepth`
    /// deep, and scans each. Does not descend into a repository once found.
    public static func scanWorkspace(root: URL, maxDepth: Int = 3, now: () -> Date = { .now }) -> [LocalGitStatus] {
        var results: [LocalGitStatus] = []
        func walk(_ dir: URL, depth: Int) {
            if let status = scan(repoDirectory: dir, now: now) {
                results.append(status)
                return   // don't recurse into a repository
            }
            guard depth < maxDepth else { return }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in children {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return results
    }

    // MARK: - Refs

    /// Resolves a ref name (e.g. `refs/heads/main`) to a commit SHA, checking the loose ref file
    /// first and then `packed-refs`.
    private static func resolveRef(_ ref: String, gitDir: URL) -> String? {
        if let loose = readString(gitDir.appendingPathComponent(ref)), isHex(loose) { return loose }
        guard let packed = readString(gitDir.appendingPathComponent("packed-refs")) else { return nil }
        for line in packed.split(separator: "\n") {
            if line.hasPrefix("#") || line.hasPrefix("^") { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[1] == ref { return String(parts[0]) }
        }
        return nil
    }

    /// Parses `[remote "origin"] url = ...` from `.git/config` and returns `owner/name` for a
    /// GitHub remote (https or ssh), or `nil`.
    private static func originSlug(gitDir: URL) -> String? {
        guard let config = readString(gitDir.appendingPathComponent("config")) else { return nil }
        var inOrigin = false
        var url: String?
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "").lowercased() == "[remote\"origin\"]"
            } else if inOrigin, line.lowercased().hasPrefix("url") , let eq = line.firstIndex(of: "=") {
                url = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return url.flatMap(gitHubSlug(fromRemoteURL:))
    }

    /// `owner/name` from a GitHub remote URL (`https://github.com/owner/name.git` or
    /// `git@github.com:owner/name.git`). Returns `nil` for non-GitHub remotes.
    static func gitHubSlug(fromRemoteURL url: String) -> String? {
        var tail: String
        if let range = url.range(of: "github.com/") {
            tail = String(url[range.upperBound...])
        } else if let range = url.range(of: "github.com:") {
            tail = String(url[range.upperBound...])
        } else {
            return nil
        }
        if tail.hasSuffix(".git") { tail = String(tail.dropLast(4)) }
        let parts = tail.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: - Index (exact dirty detection)

    /// Counts tracked files whose working content differs from the index, by comparing each entry's
    /// object id against the git blob SHA-1 of the file on disk. Returns `nil` when the index can't
    /// be read or is an unsupported version (v4 path compression), so callers show Unknown.
    static func modifiedTrackedCount(gitDir: URL, workdir: URL) -> Int? {
        guard let data = try? Data(contentsOf: gitDir.appendingPathComponent("index")), data.count >= 12 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x44, bytes[1] == 0x49, bytes[2] == 0x52, bytes[3] == 0x43 else { return nil } // "DIRC"
        let version = be32(bytes, 4)
        guard version == 2 || version == 3 else { return nil }   // v4 prefix-compresses names: unsupported, Unknown
        let count = Int(be32(bytes, 8))

        var offset = 12
        var modified = 0
        for _ in 0..<count {
            let start = offset
            // Fixed fields are 62 bytes: 10×u32 (40) + 20-byte sha + 2-byte flags.
            guard start + 62 <= bytes.count else { return nil }
            let shaStart = start + 40
            let sha = hex(bytes, shaStart, 20)
            let flags = be16(bytes, start + 60)
            let stage = (Int(flags) >> 12) & 0x3
            let extended = (flags & 0x4000) != 0
            var nameStart = start + 62
            if version >= 3 && extended { nameStart += 2 }   // 2-byte extended flags
            guard nameStart <= bytes.count else { return nil }

            // Name length: the low 12 flag bits, unless 0xFFF, which means "scan to NUL".
            let declared = Int(flags) & 0x0FFF
            var nameEnd = nameStart
            if declared < 0xFFF {
                nameEnd = nameStart + declared
                guard nameEnd <= bytes.count else { return nil }
            } else {
                while nameEnd < bytes.count && bytes[nameEnd] != 0 { nameEnd += 1 }
            }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            // Entry is NUL-padded to a multiple of 8 from `start`, with at least one terminating NUL.
            let base = (version >= 3 && extended) ? 64 : 62
            let actualNameLen = nameEnd - nameStart
            let padded = (base + actualNameLen + 8) & ~7
            offset = start + padded

            if stage != 0 { modified += 1; continue }   // unmerged entry = uncommitted
            let fileURL = workdir.appendingPathComponent(name)
            guard let content = try? Data(contentsOf: fileURL) else { modified += 1; continue } // deleted/unreadable
            if blobSHA1(content) != sha { modified += 1 }
        }
        return modified
    }

    /// git blob object id: SHA-1 over `"blob <bytecount>\0" + content`.
    private static func blobSHA1(_ content: Data) -> String {
        var header = Data("blob \(content.count)".utf8)
        header.append(0)
        var hasher = Insecure.SHA1()
        hasher.update(data: header)
        hasher.update(data: content)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Byte helpers

    private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { (UInt16(b[i]) << 8) | UInt16(b[i + 1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
    private static func hex(_ b: [UInt8], _ start: Int, _ len: Int) -> String {
        b[start..<start + len].map { String(format: "%02x", $0) }.joined()
    }

    private static func isHex(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 7 && t.allSatisfy { $0.isHexDigit }
    }

    private static func readString(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
