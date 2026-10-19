import Foundation
@testable import LinumicCore

// Shared by the Ledger and Desk tests: invented fixtures (Fixtures/ledger-priorities-sample.md,
// Fixtures/next-actions-sample.md) and an in-memory file system, so no test touches the owner's files.

enum LedgerFixtures {
    static let now = Date(timeIntervalSince1970: 1_791_720_000) // 2026-10-11T12:00:00Z
    static let home = "/Users/owner"

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Fixtures") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// An in-memory file system: files by absolute path, links, sizes that differ from the text, and paths that can't be
/// checked (a permission denial).
struct FakeLedgerFS: LedgerFileSystem {
    var files: [String: String] = [:]
    var links: Set<String> = []
    var sizes: [String: Int64] = [:]
    var denied: Set<String> = []

    func info(atPath path: String) throws -> LedgerFileInfo? {
        if denied.contains(path) { throw LedgerReadError.system("Operation not permitted") }
        if links.contains(path) { return LedgerFileInfo(isRegularFile: false, isSymbolicLink: true, size: 10) }
        guard let t = files[path] else { return nil }
        return LedgerFileInfo(isRegularFile: true, size: sizes[path] ?? Int64(t.utf8.count))
    }

    func readText(atPath path: String, maxBytes: Int64, roots: [String]) throws -> String {
        guard let t = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        guard roots.contains(where: { KeyPaths.isInside(path, root: $0) }) else { throw LedgerReadError.outsideGrant }
        return t
    }

    func names(inDirectory path: String) throws -> [String]? {
        if denied.contains(path) { throw LedgerReadError.system("Operation not permitted") }
        let prefix = path + "/"
        let names = (Array(files.keys) + Array(links)).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.contains("/") }
        return names.isEmpty ? nil : names
    }
}
