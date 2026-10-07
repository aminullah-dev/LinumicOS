import Foundation
import Testing
import CryptoKit
@testable import LinumicCore

// Builds a minimal but real .git directory on disk so the scanner is tested against the actual
// file formats (HEAD, refs, packed-refs, config, and a hand-built v2 index), not a mock.

private struct FakeRepo {
    let root: URL
    let git: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lgs-\(UUID().uuidString)")
        git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/remotes/origin"), withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ text: String) throws {
        let url = git.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeWorkfile(_ relative: String, _ content: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func blobSHA1(_ content: Data) -> [UInt8] {
    var header = Data("blob \(content.count)".utf8); header.append(0)
    var h = Insecure.SHA1(); h.update(data: header); h.update(data: content)
    return Array(h.finalize())
}

/// Builds a DIRC v2 index with one entry (stage 0, no extended flags).
private func buildIndex(name: String, sha: [UInt8]) -> Data {
    var d = Data("DIRC".utf8)
    func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    d.append(be32(2))   // version
    d.append(be32(1))   // one entry
    let entryStart = d.count
    d.append(Data(repeating: 0, count: 40))   // ctime/mtime/dev/ino/mode/uid/gid/size (unused by the scanner)
    d.append(contentsOf: sha)                  // 20-byte object id
    let nameBytes = Array(name.utf8)
    d.append(Data([UInt8(nameBytes.count >> 8 & 0x0f), UInt8(nameBytes.count & 0xff)]))  // flags = name length
    d.append(contentsOf: nameBytes)
    let entryLen = d.count - entryStart
    let padded = (entryLen + 8) & ~7           // NUL pad to a multiple of 8, at least one NUL
    d.append(Data(repeating: 0, count: padded - entryLen))
    d.append(Data(repeating: 0, count: 20))    // trailing checksum (not verified by the scanner)
    return d
}

@Suite("Local git scanner (read-only, sandbox-safe)")
struct LocalGitScannerTests {

    @Test func readsBranchOriginAndCleanTree() throws {
        let repo = try FakeRepo(); defer { repo.cleanup() }
        try repo.write("HEAD", "ref: refs/heads/main\n")
        try repo.write("refs/heads/main", "1111111111111111111111111111111111111111\n")
        try repo.write("refs/remotes/origin/main", "1111111111111111111111111111111111111111\n")
        try repo.write("config", "[remote \"origin\"]\n\turl = https://github.com/owner/name.git\n")
        let content = Data("hello\n".utf8)
        try repo.writeWorkfile("file.txt", content)
        try repo.write("index", "")  // placeholder so the dir exists; overwrite with binary below
        try buildIndex(name: "file.txt", sha: blobSHA1(content)).write(to: repo.git.appendingPathComponent("index"))

        let status = try #require(LocalGitScanner.scan(repoDirectory: repo.root))
        #expect(status.branch == "main")
        #expect(status.isDetached == false)
        #expect(status.originSlug == "owner/name")
        #expect(status.localTip == "1111111111111111111111111111111111111111")
        #expect(status.remoteTip == "1111111111111111111111111111111111111111")
        #expect(status.syncState == .inSync)
        #expect(status.modifiedTrackedFiles == 0, "working file matches the index blob")
        #expect(status.hasUncommittedChanges == false)
    }

    @Test func detectsModifiedTrackedFileByContentHash() throws {
        let repo = try FakeRepo(); defer { repo.cleanup() }
        try repo.write("HEAD", "ref: refs/heads/main\n")
        try repo.write("refs/heads/main", "2222222222222222222222222222222222222222\n")
        // index records the blob of the ORIGINAL content, working file has DIFFERENT content.
        let original = Data("original\n".utf8)
        try buildIndex(name: "a.txt", sha: blobSHA1(original)).write(to: repo.git.appendingPathComponent("index"))
        try repo.writeWorkfile("a.txt", Data("CHANGED\n".utf8))

        let status = try #require(LocalGitScanner.scan(repoDirectory: repo.root))
        #expect(status.modifiedTrackedFiles == 1)
        #expect(status.hasUncommittedChanges == true)
    }

    @Test func divergedWhenLocalAndRemoteTipsDiffer() throws {
        let repo = try FakeRepo(); defer { repo.cleanup() }
        try repo.write("HEAD", "ref: refs/heads/main\n")
        try repo.write("refs/heads/main", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
        try repo.write("refs/remotes/origin/main", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n")
        try buildIndex(name: "x", sha: blobSHA1(Data("x".utf8))).write(to: repo.git.appendingPathComponent("index"))
        try repo.writeWorkfile("x", Data("x".utf8))

        let status = try #require(LocalGitScanner.scan(repoDirectory: repo.root))
        #expect(status.syncState == .diverged)
    }

    @Test func noRemoteRefWhenOriginBranchMissing() throws {
        let repo = try FakeRepo(); defer { repo.cleanup() }
        try repo.write("HEAD", "ref: refs/heads/main\n")
        try repo.write("refs/heads/main", "cccccccccccccccccccccccccccccccccccccccc\n")
        try buildIndex(name: "x", sha: blobSHA1(Data("x".utf8))).write(to: repo.git.appendingPathComponent("index"))
        try repo.writeWorkfile("x", Data("x".utf8))

        let status = try #require(LocalGitScanner.scan(repoDirectory: repo.root))
        #expect(status.syncState == .noRemoteRef)
    }

    @Test func resolvesTipFromPackedRefs() throws {
        let repo = try FakeRepo(); defer { repo.cleanup() }
        try repo.write("HEAD", "ref: refs/heads/main\n")
        // No loose ref file; only packed-refs.
        try repo.write("packed-refs", "# pack-refs with: peeled fully-peeled sorted\ndddddddddddddddddddddddddddddddddddddddd refs/heads/main\n")
        try buildIndex(name: "x", sha: blobSHA1(Data("x".utf8))).write(to: repo.git.appendingPathComponent("index"))
        try repo.writeWorkfile("x", Data("x".utf8))

        let status = try #require(LocalGitScanner.scan(repoDirectory: repo.root))
        #expect(status.localTip == "dddddddddddddddddddddddddddddddddddddddd")
    }

    @Test func parsesSshRemoteSlug() {
        #expect(LocalGitScanner.gitHubSlug(fromRemoteURL: "git@github.com:owner/name.git") == "owner/name")
        #expect(LocalGitScanner.gitHubSlug(fromRemoteURL: "https://github.com/owner/name") == "owner/name")
        #expect(LocalGitScanner.gitHubSlug(fromRemoteURL: "https://gitlab.com/owner/name.git") == nil)
    }

    @Test func returnsNilWhenNoGitDirectory() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-git-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(LocalGitScanner.scan(repoDirectory: empty) == nil)
    }
}
