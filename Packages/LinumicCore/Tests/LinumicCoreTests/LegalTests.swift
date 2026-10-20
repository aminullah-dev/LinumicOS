import Foundation
import Testing
@testable import LinumicCore

// Made-up fixtures only (Fixtures/legal-folder: sample drafts with markers, no real document) and an in-memory file
// system. No test reads the owner's legal folder.

private let now = Date(timeIntervalSince1970: 1_792_497_600) // 2026-10-20T12:00:00Z
private let home = "/Users/owner"
private let legalRoot = "/Users/owner/Documents/Linumic-Legal"

/// Records which files were opened, so a test can prove an Asasnama file never is.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

/// Files and folders by absolute path; links, permission denials, dates and hard links.
private struct FakeLegalFS: LegalFileSystem {
    var files: [String: String] = [:]
    var dirs: Set<String> = []
    var links: Set<String> = []
    var denied: Set<String> = []
    var dates: [String: Date] = [:]
    var linkCounts: [String: Int] = [:]
    var sizes: [String: Int64] = [:]
    let log = ReadLog()

    func entry(atPath path: String) throws -> LegalEntry? {
        if links.contains(path) { return LegalEntry(kind: .symbolicLink, modifiedAt: now) }
        if dirs.contains(path) { return LegalEntry(kind: .directory, modifiedAt: dates[path] ?? now) }
        guard let t = files[path] else { return nil }
        return LegalEntry(kind: .file, size: sizes[path] ?? Int64(t.utf8.count), modifiedAt: dates[path] ?? now, links: linkCounts[path] ?? 1)
    }

    func names(inDirectory path: String) throws -> [String]? {
        if denied.contains(path) { throw LedgerReadError.system("Operation not permitted") }
        guard dirs.contains(path) else { return nil }
        let prefix = path + "/"
        let all = Array(files.keys) + Array(dirs) + Array(links)
        return Array(Set(all.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.filter { !$0.contains("/") }))
    }

    func readText(atPath path: String, maxBytes: Int64, roots: [String]) throws -> String {
        log.add(path)
        if denied.contains(path) { throw LedgerReadError.system("Operation not permitted") }
        guard roots.contains(where: { KeyPaths.isInside(path, root: $0) }) else { throw LedgerReadError.outsideGrant }
        guard let t = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
        return t
    }

    /// A folder tree from "relative path → text" under `root`, with every folder on the way.
    static func tree(_ root: String, _ files: [String: String]) -> FakeLegalFS {
        var fs = FakeLegalFS()
        fs.dirs.insert(root)
        for (rel, text) in files {
            let path = root + "/" + rel
            fs.files[path] = text
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count > root.count { fs.dirs.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
        return fs
    }
}

// MARK: - Markers

@Suite("Legal: the marker counter")
struct LegalMarkerTests {
    @Test func everyFormIsCountedWithItsLine() {
        let text = """
        Customer: [TO FILL]
        Address: [TO FILL: street]  Phone: [TO FILL]
        Court: [LAWYER] and tax [LAWYER: withholding]
        Term: [TO DECIDE - owner]
        """
        let hits = LegalMarkerScanner.scan(text)
        #expect(hits.filter { $0.kind == .toFill }.map(\.line) == [1, 2, 2])
        #expect(hits.filter { $0.kind == .lawyer }.map(\.line) == [3, 3])
        #expect(hits.filter { $0.kind == .toDecide }.map(\.line) == [4])
    }

    @Test func lookalikesAreNotMarkers() {
        let hits = LegalMarkerScanner.scan("[TO FILLED] [lawyer] [TO_FILL] TO FILL [LAWYERS] (TO DECIDE) [ TO FILL]")
        #expect(hits.isEmpty)
    }

    @Test func crlfPersianAndAMarkerAtTheEndOfTheLastLine() {
        let hits = LegalMarkerScanner.scan("a\r\n[LAWYER]\r\nمبلغ [TO FILL] افغانی\r\n[TO DECIDE")
        #expect(hits == [LegalMarkerHit(kind: .lawyer, line: 2), LegalMarkerHit(kind: .toFill, line: 3), LegalMarkerHit(kind: .toDecide, line: 4)])
    }

    @Test func labelsAreTheMarkersAsWritten() {
        #expect(LegalMarkerKind.allCases.map(\.label) == ["[TO FILL]", "[LAWYER]", "[TO DECIDE]"])
    }
}

// MARK: - Reading the folder

@Suite("Legal: reading the folder")
struct LegalReaderTests {
    private func fixtureFolder() throws -> URL {
        try #require(Bundle.module.url(forResource: "legal-folder", withExtension: nil, subdirectory: "Fixtures"))
    }

    /// The fixture folder copied to a temporary home's ~/Documents/Linumic-Legal, with a link to an outside file that
    /// holds markers (never followed, by the app or by grep -r).
    private func temporaryHome() throws -> (home: String, folder: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("legal-\(UUID().uuidString)")
        let docs = tmp.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let folder = docs.appendingPathComponent("Linumic-Legal")
        try FileManager.default.copyItem(at: try fixtureFolder(), to: folder)
        let outside = tmp.appendingPathComponent("outside.md")
        try "[TO FILL] [LAWYER] [TO DECIDE]\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Linked.md").path, withDestinationPath: outside.path)
        // `realpath` so the grant and the paths agree with what the file system reports (/private/var on macOS).
        let real = KeyPaths.trimmed(URL(fileURLWithPath: tmp.path).resolvingSymlinksInPath().path)
        return (real, real + "/Documents/Linumic-Legal")
    }

    /// The same count with grep, as docs/legal.md prints it.
    private func grepCounts(_ folder: String) throws -> [LegalMarkerKind: Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-rnoE", "--include=*.md", "--include=*.markdown", "--include=*.txt", "--exclude=.*", "--exclude-dir=.*",
                       "--exclude=*[Aa]sasnama*", LegalMarkerScanner.pattern, folder]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var counts: [LegalMarkerKind: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            for kind in LegalMarkerKind.allCases where line.contains("[\(kind.word)") { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    @Test func theCountsEqualGrepOnTheSameFolder() throws {
        let (h, folder) = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        let r = LegalReader.read(home: h, granted: [folder], fs: LocalLegalFileSystem(), now: now)
        #expect(r.state == .read)
        let grep = try grepCounts(folder)
        for kind in LegalMarkerKind.allCases {
            #expect(r.count(kind) == grep[kind, default: 0], "\(kind.label)")
        }
        // The fixture's own numbers, so a grep that counted nothing can't pass either.
        #expect(r.count(.toFill) == 9 && r.count(.lawyer) == 4 && r.count(.toDecide) == 4)
        // The link is left alone, the PDF is not read, and the Asasnama draft is only named.
        #expect(r.skipped == 1)
        #expect(r.unreadFiles.map(\.path) == ["~/Documents/Linumic-Legal/Second-Product/Scan.pdf"])
        #expect(r.asasnama.map(\.name) == ["Sample-Asasnama-draft.md"])
        #expect(!r.isComplete)
        #expect(r.groups(.toFill) == [nil, "Sample-Product", "Second-Product"])
        #expect(r.locations(.toDecide, group: "Sample-Product") == ["~/Documents/Linumic-Legal/Sample-Product/Agreement-EN.md:9",
                                                                     "~/Documents/Linumic-Legal/Sample-Product/Agreement-EN.md:12",
                                                                     "~/Documents/Linumic-Legal/Sample-Product/Notes.txt:5"])
    }

    @Test func anAsasnamaFileIsNeverOpenedAnywhere() {
        var fs = FakeLegalFS.tree(legalRoot, ["Asasnama-sample.md": "[TO FILL]", "Contract.md": "[LAWYER]",
                                             "Sub/اساسنامه-نمونه.txt": "[TO DECIDE]"])
        fs.dirs.insert("/Users/owner/Desktop/1")
        fs.files["/Users/owner/Desktop/1/Sample-ASASNAMA-2.docx"] = "binary"
        fs.files["/Users/owner/Desktop/1/other.md"] = "[TO FILL]"
        fs.dates["/Users/owner/Desktop/1/Sample-ASASNAMA-2.docx"] = Date(timeIntervalSince1970: 1_790_000_000)
        let r = LegalReader.read(home: home, granted: [legalRoot, "/Users/owner/Desktop/1"], asasnamaFolders: ["/Users/owner/Desktop/1"],
                                 fs: fs, now: now)
        #expect(fs.log.all == [legalRoot + "/Contract.md"], "only the contract was opened")
        #expect(r.count(.toFill) == 0 && r.count(.lawyer) == 1 && r.count(.toDecide) == 0)
        #expect(Set(r.asasnama.map(\.name)) == ["Asasnama-sample.md", "اساسنامه-نمونه.txt", "Sample-ASASNAMA-2.docx"])
        #expect(r.asasnama.first { $0.name == "Sample-ASASNAMA-2.docx" }?.modifiedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(r.searched.map(\.path) == ["~/Documents/Linumic-Legal", "~/Desktop/1"])
    }

    @Test func anAsasnamaGrantNeverOpensTheLegalDrafts() {
        var fs = FakeLegalFS.tree(legalRoot, ["Contract.md": "[TO FILL]", "Asasnama.docx": "x"])
        fs.dirs.insert("/Users/owner/Documents")
        // The owner added ~/Documents for Asasnama files, and never granted the legal folder itself.
        let r = LegalReader.read(home: home, granted: [], asasnamaFolders: ["/Users/owner/Documents"], fs: fs, now: now)
        #expect(r.state == .notGranted && r.files.isEmpty)
        #expect(fs.log.all.isEmpty, "no text was read")
        #expect(r.asasnama.map(\.name) == ["Asasnama.docx"], "names one level down are still listed")
    }

    @Test func notGrantedNotFoundAndRefusedAreNotZero() {
        let fs = FakeLegalFS.tree(legalRoot, ["A.md": "[TO FILL]"])
        #expect(LegalReader.read(home: home, granted: [], fs: fs, now: now).state == .notGranted)
        #expect(LegalReader.read(home: home, granted: [legalRoot], fs: FakeLegalFS(), now: now).state == .notFound)
        var denied = fs
        denied.denied.insert(legalRoot)
        #expect(LegalReader.read(home: home, granted: [legalRoot], fs: denied, now: now).state == .unreadable("Operation not permitted"))
        var linked = FakeLegalFS()
        linked.links.insert(legalRoot)
        guard case .unreadable = LegalReader.read(home: home, granted: [legalRoot], fs: linked, now: now).state else {
            Issue.record("a link in place of the folder is not read")
            return
        }
    }

    @Test func aFileThatCantBeReadMakesTheCountsAtLeast() {
        var fs = FakeLegalFS.tree(legalRoot, ["A.md": "[TO FILL]", "Big.md": "[TO FILL]", "Twice.md": "[TO FILL]", "Locked/B.md": "[LAWYER]"])
        fs.sizes[legalRoot + "/Big.md"] = LegalReader.maxBytes + 1
        fs.linkCounts[legalRoot + "/Twice.md"] = 2
        fs.denied.insert(legalRoot + "/Locked")
        let r = LegalReader.read(home: home, granted: [legalRoot], fs: fs, now: now)
        #expect(r.count(.toFill) == 1)
        #expect(Set(r.unreadFiles.map(\.path)) == ["~/Documents/Linumic-Legal/Big.md", "~/Documents/Linumic-Legal/Twice.md",
                                                   "~/Documents/Linumic-Legal/Locked/"])
        #expect(!r.isComplete)
        #expect(!fs.log.all.contains(legalRoot + "/Big.md") && !fs.log.all.contains(legalRoot + "/Twice.md"))
    }

    @Test func anAsasnamaFolderThatCantBeListedSaysSo() {
        var fs = FakeLegalFS()
        fs.dirs.insert("/Users/owner/Desktop/1")
        fs.denied.insert("/Users/owner/Desktop/1")
        let r = LegalReader.read(home: home, granted: ["/Users/owner/Desktop/1"], asasnamaFolders: ["/Users/owner/Desktop/1"], fs: fs, now: now)
        #expect(r.state == .notGranted, "the legal folder itself is not granted")
        #expect(r.searched == [LegalSearchedFolder(path: "~/Desktop/1", state: .unreadable("Operation not permitted"))])
        #expect(r.asasnama.isEmpty)
    }
}

// MARK: - Access (the sandbox check, the grant, and a stored grant's failure states)

@Suite("Legal: access and bookmark failure states")
struct LegalAccessTests {
    @Test func theLegalGrantTakesOnlyTheLegalFolder() {
        #expect(LegalAccessRules.decide(legalRoot, role: .legalFolder, home: home) == .accept)
        #expect(LegalAccessRules.decide(legalRoot + "/", role: .legalFolder, home: home) == .accept)
        for wider in ["/Users/owner/Documents", home, "/", "/Users/owner/Documents/Linumic-Legal/WorkTrack", "/Users/owner/Desktop/1"] {
            guard case .refuse = LegalAccessRules.decide(wider, role: .legalFolder, home: home) else {
                Issue.record("\(wider) must be refused")
                continue
            }
        }
    }

    @Test func anAsasnamaFolderIsBelowHomeAndNotTheLegalFolder() {
        #expect(LegalAccessRules.decide("/Users/owner/Desktop/1", role: .asasnama, home: home) == .accept)
        #expect(LegalAccessRules.decide("/Users/owner/Documents/Business-Docs", role: .asasnama, home: home) == .accept)
        for refused in [home, "/Users", "/", legalRoot, "/Volumes/Other"] {
            guard case .refuse = LegalAccessRules.decide(refused, role: .asasnama, home: home) else {
                Issue.record("\(refused) must be refused")
                continue
            }
        }
    }

    @Test func storedGrantsResolveDropOrStay() {
        let stored: [String: Data] = [
            legalRoot: Data("ok".utf8),
            "/Users/owner/Documents": Data("wide".utf8),
        ]
        // Resolves where it was made, not stale.
        var r = LegalAccessRules.resolve(stored: stored, role: .legalFolder, home: home,
                                         resolve: { _ in (legalRoot, false) }, rebookmark: { _ in nil })
        #expect(r.resolved == [legalRoot])
        #expect(r.dropped == [LegalDroppedGrant(path: "/Users/owner/Documents", reason: .notAllowed)])
        #expect(r.store == [legalRoot: Data("ok".utf8)], "the wide grant is not stored back")

        // Can't be resolved now: kept, reported, tried again.
        r = LegalAccessRules.resolve(stored: [legalRoot: Data("ok".utf8)], role: .legalFolder, home: home,
                                     resolve: { _ in throw CocoaError(.fileReadUnknown) }, rebookmark: { _ in nil })
        #expect(r.resolved.isEmpty && r.unresolved == [legalRoot] && r.store[legalRoot] == Data("ok".utf8))

        // The folder was moved: the grant leads elsewhere, so it is dropped.
        r = LegalAccessRules.resolve(stored: [legalRoot: Data("ok".utf8)], role: .legalFolder, home: home,
                                     resolve: { _ in ("/Users/owner/Documents/Old-Legal", false) }, rebookmark: { _ in nil })
        #expect(r.dropped == [LegalDroppedGrant(path: legalRoot, reason: .moved(to: "/Users/owner/Documents/Old-Legal"))])
        #expect(r.store.isEmpty && r.resolved.isEmpty)

        // Stale: remade when it can be, kept as it was when it can't.
        r = LegalAccessRules.resolve(stored: [legalRoot: Data("old".utf8)], role: .legalFolder, home: home,
                                     resolve: { _ in (legalRoot, true) }, rebookmark: { _ in Data("new".utf8) })
        #expect(r.store[legalRoot] == Data("new".utf8) && r.refreshed == [legalRoot] && r.resolved == [legalRoot])
        r = LegalAccessRules.resolve(stored: [legalRoot: Data("old".utf8)], role: .legalFolder, home: home,
                                     resolve: { _ in (legalRoot, true) }, rebookmark: { _ in nil })
        #expect(r.store[legalRoot] == Data("old".utf8) && r.refreshed.isEmpty && r.resolved == [legalRoot])
    }

    @Test func theSandboxCheckComesFirst() {
        var fs = FakeLegalFS.tree(legalRoot, ["A.md": ""])
        #expect(LegalAccessRules.probe(legalRoot, fs: fs) == .readable)
        fs.denied.insert(legalRoot)
        #expect(LegalAccessRules.probe(legalRoot, fs: fs) == .refused("Operation not permitted"))
        #expect(LegalAccessRules.probe(legalRoot, fs: FakeLegalFS()) == .notFound)
    }

    @Test func everyStateTheScreenCanShow() {
        let none = LegalBookmarkResolution()
        var granted = LegalBookmarkResolution()
        granted.resolved = [legalRoot]
        var unresolved = LegalBookmarkResolution()
        unresolved.unresolved = [legalRoot]
        var moved = LegalBookmarkResolution()
        moved.dropped = [LegalDroppedGrant(path: legalRoot, reason: .moved(to: "/x"))]
        let refused = LegalProbe.refused("Operation not permitted")

        #expect(LegalAccessRules.state(home: home, probe: refused, resolution: none, started: [], read: nil) == .notGranted)
        #expect(LegalAccessRules.state(home: home, probe: .readable, resolution: none, started: [], read: .read) == .readableWithoutGrant)
        #expect(LegalAccessRules.state(home: home, probe: refused, resolution: granted, started: [legalRoot], read: .read) == .granted)
        guard case .denied = LegalAccessRules.state(home: home, probe: refused, resolution: granted, started: [], read: nil) else {
            Issue.record("a grant whose scope did not start is denied")
            return
        }
        #expect(LegalAccessRules.state(home: home, probe: refused, resolution: granted, started: [legalRoot],
                                       read: .unreadable("Operation not permitted")) == .denied("Operation not permitted"))
        #expect(LegalAccessRules.state(home: home, probe: refused, resolution: granted, started: [legalRoot], read: .notFound) == .notFound)
        #expect(LegalAccessRules.state(home: home, probe: refused, resolution: unresolved, started: [], read: nil) == .unresolved)
        #expect(LegalAccessRules.state(home: home, probe: refused, resolution: moved, started: [], read: nil) == .moved(to: "/x"))
        #expect(LegalAccessRules.state(home: home, probe: .notFound, resolution: none, started: [], read: nil) == .notFound)
        // Only a granted or readable folder is read; every other state has a step for the owner.
        for s in [LegalAccessState.notGranted, .unresolved, .denied("x"), .moved(to: "/x"), .notFound] {
            #expect(!s.canRead && s.ownerStep != nil)
        }
        #expect(LegalAccessState.granted.canRead && LegalAccessState.readableWithoutGrant.ownerStep == nil)
    }
}

// MARK: - The company card

@Suite("Legal: company status")
struct CompanyStatusTests {
    private func listing(_ store: AppStore, seller: String?, sources: [Source]) -> StoreListing {
        StoreListing(store: store, appName: "Sample", seller: seller, verification: Verification(status: .verified, sources: sources))
    }

    @Test func theSellerPerStoreWithItsSourceAndTime() {
        let lookup = Date(timeIntervalSince1970: 1_792_400_000)
        let recorded = Date(timeIntervalSince1970: 1_790_000_000)
        var a = Product(id: "a", name: "A")
        a.storeListings = [
            listing(.appStore, seller: "SAMPLE SELLER", sources: [Source(kind: .appStore, reference: "https://itunes.apple.com/lookup?bundleId=x&country=us", observedAt: lookup)]),
            listing(.googlePlay, seller: "Sample Seller", sources: [Source(kind: .googlePlay, reference: "Play Console view", observedAt: recorded),
                                                                   Source(kind: .googlePlay, reference: "Google Play Developer API", observedAt: lookup)]),
        ]
        var b = Product(id: "b", name: "B")
        b.storeListings = [listing(.appStore, seller: nil, sources: [])]
        let status = CompanyStatusBuilder.build(products: [a, b], calendar: Self.utc)
        let apple = try! #require(status.seller(.appStore))
        #expect(apple.sellers == ["SAMPLE SELLER"] && apple.listings == 2 && apple.withoutSeller == 1)
        #expect(apple.readAt == lookup && apple.isRead)
        let play = try! #require(status.seller(.googlePlay))
        #expect(play.sellers == ["Sample Seller"] && !play.isRead && play.readAt == nil)
        #expect(play.recordedOn == KeyDay(recorded, calendar: Self.utc), "the day it was first recorded, not the API read")
    }

    @Test func noListingIsUnknownAndDSAIsUnknownWithoutASource() {
        let status = CompanyStatusBuilder.build(products: [])
        #expect(status.sellers.allSatisfy { !$0.isKnown && $0.listings == 0 })
        #expect(!status.dsa.isKnown && status.dsa.value == nil && status.dsa.unknownReason != nil)
        #expect(status.registration.isKnown && status.registration.recordedOn != nil)
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}

// MARK: - The Brief and the Desk

@Suite("Legal: the Brief section and its Desk items")
struct LegalBriefTests {
    private func input(_ legal: LegalInput?) -> BriefInput {
        BriefInput(now: now, monitor: MonitorSnapshot(), releases: ReleaseCenterSnapshot(),
                   licences: BriefLicenceInput(isLoaded: false, records: [], lastSyncedAt: nil),
                   worktrack: BriefWorkTrackInput(isSignedIn: false, environment: nil, companies: [], lastRead: nil),
                   operations: [], oversight: BriefOversightInput(repos: [], recentChanges: []), legal: legal)
    }

    private var company: CompanyStatus {
        var p = Product(id: "a", name: "A")
        p.storeListings = [StoreListing(store: .appStore, seller: "SAMPLE SELLER",
                                        verification: Verification(status: .verified, sources: [Source(kind: .appStore, reference: "https://itunes.apple.com/lookup?bundleId=x", observedAt: now)])),
                           StoreListing(store: .googlePlay, seller: "Sample Seller",
                                        verification: Verification(status: .verified, sources: [Source(kind: .googlePlay, reference: "Play Console", observedAt: now)]))]
        return CompanyStatusBuilder.build(products: [p])
    }

    private var reading: LegalReading {
        let fs = FakeLegalFS.tree(legalRoot, [
            "Customer-Acme/Agreement.md": "[TO FILL]\n[TO FILL] [LAWYER]\n",
            "Root.md": "[TO DECIDE]",
            "Sample-Asasnama.docx": "x",
        ])
        return LegalReader.read(home: home, granted: [legalRoot], fs: fs, now: now)
    }

    private func section(_ legal: LegalInput?) -> BriefSection {
        DailyBriefBuilder.build(input(legal), changes: nil).section(.legal)!
    }

    @Test func notCollectedIsNeverRead() {
        guard case .neverRead = section(nil).state else { Issue.record("never read"); return }
    }

    @Test func aFolderNotGrantedIsAnItemNotZero() {
        let s = section(LegalInput(reading: nil, access: .notGranted, readsFolder: true, company: company))
        #expect(s.lines.map(\.id) == [LegalBrief.registrationID])
        #expect(Set(s.gaps.map(\.key)) == ["folder", "dsa"])
        let desk = DeskBuilder.build(brief: DailyBriefBuilder.build(input(LegalInput(reading: nil, access: .notGranted, readsFolder: true, company: company)), changes: nil),
                                     ledgers: .unsupported, state: DeskState(), now: now)
        let items = desk.open.map(\.item).filter { $0.origin == .brief(.legal) }
        #expect(Set(items.map(\.subjectKey)) == [LegalBrief.registrationID, "part.folder", "part.dsa"])
        #expect(items.allSatisfy { $0.destination == .screen(.legal) })
    }

    @Test func markerLinesByKindAndGroupWithoutNamesInTheirIds() {
        let s = section(LegalInput(reading: reading, access: .granted, readsFolder: true, company: company))
        let markers = s.lines.filter { $0.id.hasPrefix("legal.markers.") }
        #expect(markers.count == 3)
        let fill = try! #require(markers.first { $0.id == LegalBrief.markersID(.toFill, group: "Customer-Acme") })
        #expect(fill.text.contains("2") && fill.text.contains("[TO FILL]") && fill.severity == .normal)
        #expect(fill.detail == "Customer-Acme/Agreement.md: 1, 2")
        #expect(fill.product == "Customer-Acme")
        #expect(markers.first { $0.id == LegalBrief.markersID(.toDecide, group: nil) }?.product == nil)
        // No folder or file name in any id (a folder may be named after a customer); nothing of the text anywhere.
        for line in s.lines {
            #expect(!line.id.contains("Acme") && !line.id.contains("Agreement") && !line.id.contains("Asasnama"))
        }
        let asasnama = try! #require(s.lines.first { $0.id == LegalBrief.asasnamaID })
        #expect(asasnama.text.contains("1") && asasnama.severity == .normal)
        #expect(s.gaps.map(\.key) == ["dsa"], "every file was read and the Asasnama file was found")
    }

    @Test func unreadFilesSayAtLeast() {
        let fs = FakeLegalFS.tree(legalRoot, ["A.md": "[TO FILL]", "Scan.pdf": "x"])
        let r = LegalReader.read(home: home, granted: [legalRoot], fs: fs, now: now)
        let s = section(LegalInput(reading: r, access: .granted, readsFolder: true, company: company))
        let line = try! #require(s.lines.first { $0.id == LegalBrief.markersID(.toFill, group: nil) })
        #expect(line.text.hasPrefix("At least"))
        #expect(s.gaps.first { $0.key == "files" }?.isCaveat == true)
        #expect(s.gaps.contains { $0.key == "asasnama" }, "none found in the folders read: unknown, not none")
    }

    @Test func onIPhoneTheFolderIsANoteNotADeskItem() {
        let s = section(LegalInput(reading: nil, access: nil, readsFolder: false, company: company))
        #expect(s.gaps.first { $0.key == "folder" }?.isDeskItem == false)
    }

    @Test func aMarkOnAMarkerLineStaysWhileTheFolderIsNotRead() {
        let id = "brief.legal|\(LegalBrief.markersID(.toFill, group: "Customer-Acme"))|fact"
        let mark = DeskMark(kind: .waiting, at: now.addingTimeInterval(-3600), factHash: "0000000000000000")
        // The folder could not be read this time: the line is missing, but the mark is not dropped.
        let unread = DailyBriefBuilder.build(input(LegalInput(reading: nil, access: .denied("x"), readsFolder: true, company: company)), changes: nil)
        #expect(!DeskBuilder.briefLineIsGone(id, mark: mark, brief: unread))
        // Read again and the line is gone: then the mark goes too.
        let empty = LegalReader.read(home: home, granted: [legalRoot], fs: FakeLegalFS.tree(legalRoot, ["A.md": "nothing"]), now: now)
        let readEmpty = DailyBriefBuilder.build(input(LegalInput(reading: empty, access: .granted, readsFolder: true, company: company)), changes: nil)
        #expect(DeskBuilder.briefLineIsGone(id, mark: mark, brief: readEmpty))
    }
}
