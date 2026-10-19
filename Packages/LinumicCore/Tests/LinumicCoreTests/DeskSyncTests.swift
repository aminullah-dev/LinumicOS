import Foundation
import Testing
@testable import LinumicCore

// Desk sync (docs/desk-sync.md): merging one row, cloud keys, two devices against an in-memory server with the SQL's
// rules, the Supabase client against answers recorded from the real SQL, and the server sweep against the app's alerts.
// TEST FIXTURES only: desk-sync-pull.json, desk-sync-push.json and desk-sync-ledger.json were produced by running the
// repository's migrations on a scratch Postgres with made-up marks, obligations and accounts ("Sample Host",
// "Sample Store"); desk-sync-sweep.json is made up too. Never real data.

private let t0 = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!
private func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }
private var utc: Calendar { LedgerFixtures.utc }

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func ledgerItem(_ key: String = "a1", hash: String = "0123456789abcdef", title: String = "Sign the sample contract") -> DeskItem {
    DeskItem(origin: .ledger("worktrack"), subjectKey: key, kindKey: "checkbox", kind: .task, domain: .worktrack, severity: .high,
             title: title, subject: "P0", ownerAction: false,
             evidence: DeskEvidence(source: "~/Projects/Multiplatform/WorkTrack/PRIORITIES.md",
                                    file: "~/Projects/Multiplatform/WorkTrack/PRIORITIES.md", line: 3, readAt: t0, cadence: 1800),
             factHash: hash, destination: .file(path: "~/Projects/Multiplatform/WorkTrack/PRIORITIES.md", line: 3))
}

private func customerItem(_ company: String = "emu_sample") -> DeskItem {
    DeskItem(origin: .brief(.worktrack), subjectKey: "worktrack.expired.\(company)", kindKey: "fact", kind: .fact, domain: .worktrack,
             severity: .high, title: "Sample Company's licence has expired", subject: "WorkTrack", ownerAction: true,
             evidence: DeskEvidence(source: "WorkTrack vendor API", readAt: t0, cadence: 6 * 3600),
             factHash: "00112233445566aa", destination: .screen(.worktrackCustomers))
}

private func row<P: CloudPayload>(_ id: String, _ version: Int64, _ value: P?, entry: String = "mark") -> CloudRow<P> {
    CloudRow(id: id, entry: entry, version: version, value: value, writtenOn: .macOS, updatedAt: t0)
}

private let done = DeskMark(kind: .done, at: t0, factHash: "0123456789abcdef")
private let waiting = DeskMark(kind: .waiting, at: at(5), factHash: "0123456789abcdef")
private let dismissed = DeskMark(kind: .dismissed, at: at(6), factHash: "0123456789abcdef", reason: "Handled by phone")

// MARK: - A server with the SQL's rules

/// The `desk_state`, `obligations`, `vendors` and ledger tables in memory, with the rules of
/// supabase/migrations/20261019090000_desk_sync.sql: a write names the version it is based on and is answered "stale"
/// with the row as it is when the row moved on; nothing is deleted (a tombstone is a version); values go through JSON,
/// as they do on the way to Postgres.
private actor FakeDeskCloud: DeskCloudRemote {
    var marks: [String: CloudRow<DeskMark>] = [:]
    var obligations: [String: CloudRow<ObligationCloudPayload>] = [:]
    var vendors: [String: CloudRow<VendorCloudPayload>] = [:]
    var ledger: CloudLedgerSnapshot?
    var refuse: Set<String> = []
    private(set) var written: [String] = []
    private(set) var ledgerCalls = 0

    func pull() async throws -> DeskCloudPull {
        DeskCloudPull(serverTime: t0, marks: marks.values.sorted { $0.id < $1.id },
                      obligations: obligations.values.sorted { $0.id < $1.id }, vendors: vendors.values.sorted { $0.id < $1.id },
                      ledger: ledger)
    }

    func pushMarks(_ changes: [CloudChange<DeskMark>], device: CloudDevice) async throws -> [CloudPushResult<DeskMark>] {
        write(changes, into: &marks, device: device)
    }

    func pushObligations(_ changes: [CloudChange<ObligationCloudPayload>], device: CloudDevice) async throws
        -> [CloudPushResult<ObligationCloudPayload>] {
        write(changes, into: &obligations, device: device)
    }

    func pushVendors(_ changes: [CloudChange<VendorCloudPayload>], device: CloudDevice) async throws -> [CloudPushResult<VendorCloudPayload>] {
        write(changes, into: &vendors, device: device)
    }

    func replaceLedger(expectedVersion: Int64, reading: CloudLedgerUpload) async throws -> CloudLedgerPushResult {
        ledgerCalls += 1
        if (ledger?.version ?? 0) != expectedVersion {
            return CloudLedgerPushResult(status: .stale, version: ledger?.version ?? 0, readAt: ledger?.readAt, message: nil)
        }
        if let ledger, reading.readAt < ledger.readAt {
            return CloudLedgerPushResult(status: .older, version: ledger.version, readAt: ledger.readAt, message: nil)
        }
        let version = (ledger?.version ?? 0) + 1
        ledger = CloudLedgerSnapshot(version: version, readAt: reading.readAt, digest: reading.digest, sources: reading.sources, items: reading.items)
        return CloudLedgerPushResult(status: .applied, version: version, readAt: reading.readAt, message: nil)
    }

    /// The server restored from a copy taken before these rows.
    func wipe() {
        marks = [:]
        obligations = [:]
        vendors = [:]
    }

    func setRefused(_ ids: Set<String>) { refuse = ids }

    private func write<P: CloudPayload>(_ changes: [CloudChange<P>], into rows: inout [String: CloudRow<P>], device: CloudDevice)
    -> [CloudPushResult<P>] {
        changes.map { c in
            if refuse.contains(c.id) { return CloudPushResult(id: c.id, status: .invalid, row: nil, message: "refused by the test server") }
            guard let cur = rows[c.id] else {
                if c.expectedVersion != 0 { return CloudPushResult(id: c.id, status: .stale, row: nil, message: nil) }
                guard c.value != nil else { return CloudPushResult(id: c.id, status: .applied, row: nil, message: nil) }
                let new = Self.json(CloudRow(id: c.id, entry: c.entry, key: c.key, version: 1, value: c.value, seedRevision: c.seedRevision,
                                             writtenOn: device, updatedAt: t0))
                rows[c.id] = new
                written.append(c.id)
                return CloudPushResult(id: c.id, status: .applied, row: new, message: nil)
            }
            guard cur.version == c.expectedVersion else { return CloudPushResult(id: c.id, status: .stale, row: cur, message: nil) }
            let new = Self.json(CloudRow(id: c.id, entry: cur.entry, key: cur.key, version: cur.version + 1, value: c.value,
                                         seedRevision: c.seedRevision ?? cur.seedRevision, writtenOn: device, updatedAt: t0))
            rows[c.id] = new
            written.append(c.id)
            return CloudPushResult(id: c.id, status: .applied, row: new, message: nil)
        }
    }

    private static func json<P: CloudPayload>(_ row: CloudRow<P>) -> CloudRow<P> {
        let data = try! InventoryCoding.encoder().encode(row)
        return try! InventoryCoding.decoder().decode(CloudRow<P>.self, from: data)
    }
}

/// One device: its files and what it remembers between syncs.
private struct Device {
    var kind: CloudDevice
    var desk = DeskState()
    var file = ObligationsFile()
    var state = DeskSyncState()
    var known: Set<String> = []

    init(_ kind: CloudDevice) { self.kind = kind }

    @discardableResult
    mutating func sync(_ server: FakeDeskCloud, at now: Date, ledger: CloudLedgerUpload? = nil, seed: [Obligation] = [],
                       seedAccounts: [VendorAccount] = [], revision: Int = 1) async throws -> DeskCloudReport {
        let result = try await DeskCloudSync.sync(local: DeskCloudLocal(desk: desk, obligations: file, ledger: ledger), state: state,
                                                  remote: server, device: kind, now: now, seed: seed, seedAccounts: seedAccounts,
                                                  seedRevision: revision)
        let applied = result.apply(desk: desk, obligations: file, known: known)
        desk = applied.desk
        file = applied.obligations ?? file
        state = applied.state
        return result.report
    }
}

// MARK: - One row

@Suite("Desk sync: merging one row")
struct DeskSyncMergeTests {
    private let id = "ledger.worktrack|a1|checkbox"

    @Test func whatOnlyOneSideChangedIsKeptFromThatSide() {
        let base: CloudRow<DeskMark> = row(id, 1, done)
        #expect(DeskCloudMerge.step(base: base, local: .value(done), remote: base) == .keep)
        #expect(DeskCloudMerge.step(base: base, local: .value(waiting), remote: base) == .push(waiting, expected: 1),
                "changed here: sent, based on the server's version")
        let theirs: CloudRow<DeskMark> = row(id, 2, dismissed)
        #expect(DeskCloudMerge.step(base: base, local: .value(done), remote: theirs) == .adopt(theirs), "changed there: taken in")
        #expect(DeskCloudMerge.step(base: nil, local: .absent, remote: theirs) == .adopt(theirs), "new there: taken in")
        #expect(DeskCloudMerge.step(base: nil, local: .value(waiting), remote: nil) == .push(waiting, expected: 0), "new here: sent")
    }

    @Test func twoDifferentChangesAreAConflictNeverAnOverwrite() {
        let base: CloudRow<DeskMark> = row(id, 1, done)
        let theirs: CloudRow<DeskMark> = row(id, 2, dismissed)
        #expect(DeskCloudMerge.step(base: base, local: .value(waiting), remote: theirs) == .conflict(local: waiting, remote: theirs))
        #expect(DeskCloudMerge.step(base: base, local: .value(dismissed), remote: theirs) == .adopt(theirs), "the same change twice")
        #expect(DeskCloudMerge.step(base: nil, local: .value(waiting), remote: theirs) == .conflict(local: waiting, remote: theirs),
                "both marked it before they ever synced")
        // An undo here against a change there.
        #expect(DeskCloudMerge.step(base: base, local: .deleted, remote: theirs) == .conflict(local: nil, remote: theirs))
    }

    @Test func aRowMissingOnEitherSideIsNeverReadAsDeleted() {
        let base: CloudRow<DeskMark> = row(id, 3, done)
        #expect(DeskCloudMerge.step(base: base, local: .value(done), remote: nil) == .push(done, expected: 0),
                "the server lost it (restored from an older copy): sent again")
        #expect(DeskCloudMerge.step(base: base, local: .absent, remote: base) == .adopt(base),
                "this device lost it (desk-state.json removed): taken in again")
        #expect(DeskCloudMerge.step(base: base, local: .absent, remote: base, dropped: 3) == .keep,
                "dropped here as no longer applying: not taken in again")
        let changed: CloudRow<DeskMark> = row(id, 4, waiting)
        #expect(DeskCloudMerge.step(base: base, local: .absent, remote: changed, dropped: 3) == .adopt(changed),
                "but taken in once it changes there")
        #expect(DeskCloudMerge.step(base: base, local: .absent, remote: nil, dropped: 3) == .forget)
    }

    @Test func anUndoIsATombstone() {
        let base: CloudRow<DeskMark> = row(id, 1, done)
        #expect(DeskCloudMerge.step(base: base, local: .deleted, remote: base) == .push(nil, expected: 1))
        let tomb: CloudRow<DeskMark> = row(id, 2, nil)
        #expect(DeskCloudMerge.step(base: tomb, local: .deleted, remote: tomb) == .keep, "already a tombstone")
        #expect(DeskCloudMerge.step(base: nil as CloudRow<DeskMark>?, local: .deleted, remote: nil) == .keep, "nothing there to undo")
        #expect(DeskCloudMerge.step(base: nil, local: .deleted, remote: base) == .conflict(local: nil, remote: base),
                "an undo with nothing agreed before it and a mark on the server: both shown, nothing chosen")
    }

    @Test func accountFactsFromTwoDevicesAreKeptTogetherUnlessTheyContradict() throws {
        let renewal = VendorAccountEdit(accountID: "test-host", renewal: KeyDay("2026-12-01"), renewalSource: "sample invoice 1", enteredAt: at(1))
        let cost = VendorAccountEdit(accountID: "test-host", cost: AccountCost(amount: 5, currency: "USD", cycle: .yearly, source: "sample bill"),
                                     enteredAt: at(2))
        let otherDay = VendorAccountEdit(accountID: "test-host", renewal: KeyDay("2026-12-03"), renewalSource: "sample invoice 2", enteredAt: at(3))
        let merged = try #require(DeskCloudMerge.mergeFacts(base: nil, local: AccountFacts(edits: [cost]), remote: AccountFacts(edits: [renewal])))
        #expect(merged.edits == [renewal, cost], "a renewal there and a cost here: both, oldest first")
        #expect(DeskCloudMerge.mergeFacts(base: nil, local: AccountFacts(edits: [otherDay]), remote: AccountFacts(edits: [renewal])) == nil,
                "two renewal days: a conflict")
        let base = AccountFacts(edits: [renewal])
        #expect(DeskCloudMerge.mergeFacts(base: base, local: AccountFacts(edits: [renewal, cost]), remote: AccountFacts(edits: [renewal, otherDay]))
                == AccountFacts(edits: [renewal, cost, otherDay]), "what both already had is not a contradiction")
        let step = DeskCloudMerge.step(base: nil, local: .value(VendorCloudPayload.facts(AccountFacts(edits: [cost]))),
                                       remote: row("facts:test-host", 1, VendorCloudPayload.facts(AccountFacts(edits: [renewal])), entry: "facts"),
                                       merge: DeskCloudMerge.mergeVendor)
        #expect(step == .pushMerged(.facts(AccountFacts(edits: [renewal, cost])), expected: 1))
    }
}

// MARK: - Keys and marks

@Suite("Desk sync: cloud keys and the owner's undo")
struct DeskSyncKeyTests {
    @Test func customerSectionsCarryAHashNeverTheEntryID() {
        let key = DeskCloudKey.cloud("brief.worktrack|worktrack.expired.emu_sample|fact")
        #expect(key.hasPrefix("brief.worktrack|h-") && key.hasSuffix("|fact") && !key.contains("emu_sample"))
        #expect(key.split(separator: "|")[1].count == 18)
        #expect(DeskCloudKey.cloud(key) == key, "a key is its own key")
        #expect(DeskCloudKey.isHashed(key))
        #expect(!DeskCloudKey.cloud("brief.siteMessages|site.42|fact").contains("site.42"))
        #expect(!DeskCloudKey.cloud("brief.licences|licence.expiring.L-20|fact").contains("L-20"))
        for plain in ["ledger.worktrack|a1|checkbox", "next-actions|worktrack/sample|owner", "brief.monitor|monitor.down.x|fact",
                      "brief.obligations|obligation.owner.1|fact"] {
            #expect(DeskCloudKey.cloud(plain) == plain)
        }
    }

    @Test func aMarkKeptUnderItsCloudKeyFindsItsItem() {
        let item = customerItem()
        var state = DeskState(marks: [DeskCloudKey.cloud(item.id): DeskMark(kind: .done, at: t0, factHash: item.factHash)])
        #expect(state.resolve(item, now: at(1)) == .reopened(DeskMark(kind: .done, at: t0, factHash: item.factHash)) ||
                state.resolve(item, now: at(1)) == .hidden(DeskMark(kind: .done, at: t0, factHash: item.factHash)))
        // Marking it here keeps one mark, under its own id.
        state.markWaiting(item, now: at(2))
        #expect(state.marks.keys.sorted() == [item.id])
        // A Desk built with it does not drop the cloud-keyed mark as gone.
        let desk = DeskBuilder.build(brief: nil, ledgers: .unsupported,
                                     state: DeskState(marks: [DeskCloudKey.cloud(item.id): DeskMark(kind: .waiting, at: t0, factHash: "ffffffffffffffff")]),
                                     now: at(1), calendar: utc)
        #expect(desk.obsoleteMarks.isEmpty, "no item and no read source: nothing known to be gone")
    }

    @Test func aRestoreIsRememberedForTheCloudAndAPruneIsNot() throws {
        let a = ledgerItem("a1"), b = ledgerItem("b1")
        var state = DeskState()
        state.markDone(a, now: t0)
        state.markDone(b, now: t0)
        state.restore(a.id)
        state.remove([b.id])
        #expect(state.marks.isEmpty)
        #expect(state.restored == [a.id], "the undo is kept until it is sent; a prune is not an undo")
        state.markWaiting(a, now: at(1))
        #expect(state.restored.isEmpty, "marking it again takes the undo back")
        state.restore("nothing.here|x|y")
        #expect(state.restored.isEmpty, "restoring nothing records nothing")
        // desk-state.json written before the sync has no "restored".
        let old = Data(#"{"version":1,"marks":{"ledger.worktrack|a1|checkbox":{"kind":"done","at":"2026-10-19T08:00:00Z","factHash":"0123456789abcdef"}}}"#.utf8)
        let decoded = try InventoryCoding.decoder().decode(DeskState.self, from: old)
        #expect(decoded.marks.count == 1 && decoded.restored.isEmpty)
        #expect(!String(decoding: try InventoryCoding.encoder().encode(decoded), as: UTF8.self).contains("restored"),
                "an empty undo list is not written")
    }

    @Test func aReopenIsRememberedForTheCloud() throws {
        var file = ObligationsFile()
        let o = try file.add(title: "Pay the sample host", product: nil, area: .accounts, due: KeyDay("2026-11-01"), consequence: nil,
                             source: "sample bill", now: t0, calendar: utc)
        file.reopen(o.id, due: o.due)
        #expect(file.reopened.isEmpty, "nothing was done, so nothing is reopened")
        try file.complete(o.id, due: o.due, on: KeyDay(t0, calendar: utc), evidence: "sample receipt", now: t0, calendar: utc)
        file.reopen(o.id, due: o.due)
        #expect(file.reopened == [ObligationReopen(obligationID: o.id, due: o.due)])
        try file.complete(o.id, due: o.due, on: KeyDay(t0, calendar: utc), evidence: "sample receipt 2", now: t0, calendar: utc)
        #expect(file.reopened.isEmpty)
        let old = Data(#"{"version":1,"added":[],"dates":[],"completions":[],"accounts":[],"accountEdits":[]}"#.utf8)
        #expect(try InventoryCoding.decoder().decode(ObligationsFile.self, from: old).reopened.isEmpty)
    }
}

// MARK: - Two devices

@Suite("Desk sync: two devices")
struct DeskSyncDeviceTests {
    private func reading() -> LedgerReading {
        var fs = FakeLedgerFS()
        fs.files["\(LedgerFixtures.home)/Projects/Multiplatform/WorkTrack/PRIORITIES.md"] = """
        آخرین بازبینی: 2026-10-10
        ## P0
        - [ ] **Sign the sample contract.** With the sample customer.
        - [ ] Write to sample@example.com about the invoice
        """
        return LedgerReader.read(home: LedgerFixtures.home, granted: ["\(LedgerFixtures.home)/Projects/Multiplatform"], fs: fs,
                                 now: LedgerFixtures.now)
    }

    @Test func doneOnTheMacShowsOnTheIPhoneWithTheMacsReadingDated() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        let reading = reading()
        let macDesk = DeskBuilder.build(brief: nil, ledgers: .read(reading), state: mac.desk, now: LedgerFixtures.now, calendar: utc)
        let line = try #require(macDesk.open.first { $0.item.title == "Sign the sample contract" })
        mac.desk.markDone(line.item, now: LedgerFixtures.now.addingTimeInterval(60))
        let upload = DeskCloudLedger.upload(reading, now: LedgerFixtures.now, calendar: utc)
        let report = try await mac.sync(server, at: at(1), ledger: upload)
        #expect(report.sent == 1 && report.ledger == .applied)

        try await phone.sync(server, at: at(2))
        #expect(phone.desk.marks[line.item.id]?.kind == .done)
        let snapshot = try #require(phone.state.cloudLedger)
        let phoneDesk = DeskBuilder.build(brief: nil, ledgers: .cloud(snapshot), state: phone.desk, now: LedgerFixtures.now.addingTimeInterval(7200),
                                          calendar: utc)
        let shown = try #require(phoneDesk.row(line.item.id))
        #expect(shown.resolution == .markedNotTicked(DeskMark(kind: .done, at: DeskState.stamp(LedgerFixtures.now.addingTimeInterval(60)),
                                                              factHash: line.item.factHash)),
                "the Mac's Done, on the iPhone, in «you marked it, the ledger is not ticked yet»")
        #expect(shown.item.readOn == .macOS && shown.item.evidence.readAt == DeskState.stamp(reading.readAt), "dated with the Mac's reading")
        #expect(shown.isStale, "two hours after the Mac's reading it says so")
        #expect(phoneDesk.sources.first { $0.id == "worktrack" }?.isRead == true)
        // The line with an address went up without its text.
        let withheld = try #require(snapshot.items.first { $0.titleWithheld })
        #expect(withheld.title == DeskCloudLedger.withheldTitle && !snapshot.items.contains { $0.title.contains("@") })
        #expect(phoneDesk.open.contains { $0.item.id == withheld.id && !$0.item.title.contains("@") })
        // The same reading is not sent twice.
        try await mac.sync(server, at: at(3), ledger: upload)
        #expect(await server.ledgerCalls == 1)
    }

    @Test func editsOnTwoDevicesAtOnceShowAConflictAndNeitherIsLost() async throws {
        let server = FakeDeskCloud()
        let item = ledgerItem()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        mac.desk.markDone(item, now: t0)
        phone.desk.dismiss(item, reason: "Handled by phone", now: at(1))
        try await mac.sync(server, at: at(2))
        let report = try await phone.sync(server, at: at(3))
        #expect(report.conflicts == 1)
        let conflict = try #require(phone.state.marks.conflicts[item.id])
        #expect(conflict.local?.kind == .dismissed && conflict.remote.value?.kind == .done && conflict.remote.writtenOn == .macOS)
        #expect(phone.desk.marks[item.id]?.kind == .dismissed, "this device keeps its own")
        #expect(await server.marks[item.id]?.value?.kind == .done, "the server keeps the other's")
        // Syncing again changes nothing: the conflict stays until the owner picks.
        try await phone.sync(server, at: at(4))
        #expect(phone.state.marks.conflicts[item.id] != nil && phone.desk.marks[item.id]?.kind == .dismissed)
        try await mac.sync(server, at: at(4))
        #expect(mac.desk.marks[item.id]?.kind == .done)

        // The owner keeps the iPhone's: it is sent over the Mac's, and the Mac takes it in.
        _ = DeskCloudSync.resolve(&phone.state.marks, id: item.id, keepThisDevice: true)
        try await phone.sync(server, at: at(5))
        #expect(phone.state.marks.conflicts.isEmpty)
        #expect(await server.marks[item.id]?.value?.kind == .dismissed)
        try await mac.sync(server, at: at(6))
        #expect(mac.desk.marks[item.id]?.kind == .dismissed && mac.desk.marks[item.id]?.reason == "Handled by phone")
    }

    @Test func choosingTheOtherDevicesVersionTakesItIn() async throws {
        let server = FakeDeskCloud()
        let item = ledgerItem()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        mac.desk.markDone(item, now: t0)
        phone.desk.markWaiting(item, now: at(1))
        try await mac.sync(server, at: at(2))
        try await phone.sync(server, at: at(3))
        let choice = DeskCloudSync.resolve(&phone.state.marks, id: item.id, keepThisDevice: false)
        if case .some(let theirs) = choice { DeskCloudSync.take(theirs, key: item.id, into: &phone.desk, known: []) }
        #expect(phone.desk.marks[item.id]?.kind == .done)
        let report = try await phone.sync(server, at: at(4))
        #expect(report.sent == 0 && report.conflicts == 0)
    }

    @Test func aDoneWithEvidenceAndItsReopenTravel() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        let o = try mac.file.add(title: "Pay the sample host", product: "WorkTrack", area: .accounts, due: KeyDay("2026-11-01"),
                                 consequence: nil, source: "sample bill 7", now: t0, calendar: utc)
        try await mac.sync(server, at: at(1))
        try await phone.sync(server, at: at(2))
        #expect(phone.file.added.map(\.id) == [o.id])
        try phone.file.complete(o.id, due: o.due, on: KeyDay(at(2), calendar: utc), evidence: "sample receipt 12", now: at(2), calendar: utc)
        try await phone.sync(server, at: at(3))
        try await mac.sync(server, at: at(4))
        let register = ObligationsBuilder.build(file: mac.file, live: ObligationLiveInput(), now: at(4), calendar: utc, seed: [], seedAccounts: [])
        #expect(register.obligation(o.id)?.completion?.evidence == "sample receipt 12", "done on the iPhone, closed on the Mac")

        mac.file.reopen(o.id, due: o.due)
        try await mac.sync(server, at: at(5))
        #expect(mac.file.reopened.isEmpty, "the reopen reached the server")
        #expect(await server.obligations["done:\(o.id)|2026-11-01"]?.isDeleted == true)
        try await phone.sync(server, at: at(6))
        #expect(phone.file.completions.isEmpty)
    }

    @Test func twoDonesForOneDayAreAConflict() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        let o = try mac.file.add(title: "Pay the sample host", product: nil, area: .accounts, due: KeyDay("2026-11-01"),
                                 consequence: nil, source: "sample bill 7", now: t0, calendar: utc)
        try await mac.sync(server, at: at(1))
        try await phone.sync(server, at: at(2))
        try mac.file.complete(o.id, due: o.due, on: KeyDay(at(3), calendar: utc), evidence: "receipt A", now: at(3), calendar: utc)
        try phone.file.complete(o.id, due: o.due, on: KeyDay(at(3), calendar: utc), evidence: "receipt B", now: at(3), calendar: utc)
        try await mac.sync(server, at: at(4))
        try await phone.sync(server, at: at(5))
        let id = DeskCloudMapping.obligationRowID("done", o.id, due: o.due)
        let conflict = try #require(phone.state.obligations.conflicts[id])
        guard case .done(let mine)? = conflict.local, case .done(let theirs)? = conflict.remote.value else {
            Issue.record("both sides should be Done marks")
            return
        }
        #expect(mine.evidence == "receipt B" && theirs.evidence == "receipt A")
        #expect(phone.file.completions.map(\.evidence) == ["receipt B"])
    }

    @Test func accountFactsRecordedOnBothDevicesAreKept() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        try mac.file.editAccount("test-host", renewal: KeyDay("2026-12-01"), renewalSource: "sample invoice 1", holder: nil, holderSource: nil,
                                 now: at(1))
        try phone.file.editAccount("test-host", renewal: nil, renewalSource: nil, holder: nil, holderSource: nil,
                                   cost: AccountCost(amount: 5, currency: "USD", cycle: .yearly, source: "sample bill"), now: at(2))
        try await mac.sync(server, at: at(3))
        let report = try await phone.sync(server, at: at(4))
        #expect(report.conflicts == 0)
        try await mac.sync(server, at: at(5))
        for device in [mac, phone] {
            #expect(device.file.accountEdits.count == 2, "\(device.kind): the renewal and the cost")
        }
        // The same fact recorded differently on each: a conflict.
        try mac.file.editAccount("test-host", renewal: KeyDay("2026-12-05"), renewalSource: "sample invoice 2", holder: nil, holderSource: nil,
                                 now: at(6))
        try phone.file.editAccount("test-host", renewal: KeyDay("2026-12-07"), renewalSource: "sample invoice 3", holder: nil, holderSource: nil,
                                   now: at(7))
        try await mac.sync(server, at: at(8))
        try await phone.sync(server, at: at(9))
        #expect(phone.state.vendors.conflicts["facts:test-host"] != nil)
    }

    @Test func aRestoreReachesTheOtherDeviceAPruneDoesNot() async throws {
        let server = FakeDeskCloud()
        let a = ledgerItem("a1"), b = ledgerItem("b1")
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        mac.desk.markDone(a, now: t0)
        mac.desk.markDone(b, now: t0)
        try await mac.sync(server, at: at(1))
        try await phone.sync(server, at: at(2))
        mac.desk.restore(a.id)
        mac.desk.remove([b.id])
        mac.state.dropped([b.id])
        try await mac.sync(server, at: at(3))
        #expect(mac.desk.restored.isEmpty && mac.desk.marks[b.id] == nil, "the dropped mark is not taken in again")
        try await phone.sync(server, at: at(4))
        #expect(phone.desk.marks[a.id] == nil, "the undo reached the iPhone")
        #expect(phone.desk.marks[b.id]?.kind == .done, "the Mac's prune did not")
        // Once the iPhone changes it, the Mac takes it in again.
        phone.desk.snooze(b, until: at(60 * 24), now: at(5))
        try await phone.sync(server, at: at(6))
        try await mac.sync(server, at: at(7))
        #expect(mac.desk.marks[b.id]?.kind == .snoozed)
    }

    @Test func aServerThatLostItsRowsGetsThemBackAndNothingIsDeletedHere() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        mac.desk.markDone(ledgerItem(), now: t0)
        _ = try mac.file.add(title: "Renew the sample domain", product: nil, area: .domains, due: nil, consequence: nil,
                             source: "sample note", now: t0, calendar: utc)
        try await mac.sync(server, at: at(1))
        await server.wipe()
        let report = try await mac.sync(server, at: at(2))
        #expect(report.sent == 2)
        #expect(await server.marks.count == 1)
        #expect(await server.obligations.count == 1)
        #expect(mac.desk.marks.count == 1 && mac.file.added.count == 1)
    }

    @Test func aFileLostHereIsFilledAgainFromTheCloud() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        mac.desk.markDone(ledgerItem(), now: t0)
        try mac.file.editAccount("test-host", renewal: KeyDay("2026-12-01"), renewalSource: "sample invoice", holder: nil, holderSource: nil,
                                 now: t0)
        try await mac.sync(server, at: at(1))
        mac.desk = DeskState()
        mac.file = ObligationsFile()
        try await mac.sync(server, at: at(2))
        #expect(mac.desk.marks.count == 1 && mac.file.accountEdits.count == 1)
        #expect(await server.marks.values.allSatisfy { !$0.isDeleted }, "a lost file is never sent as deletions")
    }

    @Test func aChangeMadeWhileTheSyncRanIsKeptAndLeadsToAConflict() async throws {
        let server = FakeDeskCloud()
        let item = ledgerItem()
        var mac = Device(.macOS)
        var phone = Device(.iOS)
        mac.desk.markDone(item, now: t0)
        try await mac.sync(server, at: at(1))
        try await phone.sync(server, at: at(2))
        phone.desk.snooze(item, until: at(600), now: at(3))
        try await phone.sync(server, at: at(4))
        // The Mac starts a sync, and the owner marks the item while it runs.
        let result = try await DeskCloudSync.sync(local: DeskCloudLocal(desk: mac.desk, obligations: mac.file), state: mac.state,
                                                  remote: server, device: .macOS, now: at(5), seed: [], seedAccounts: [])
        mac.desk.markWaiting(item, now: at(5))
        let applied = result.apply(desk: mac.desk, obligations: mac.file, known: [])
        #expect(applied.desk.marks[item.id]?.kind == .waiting, "the owner's change is not overwritten")
        mac.desk = applied.desk
        mac.state = applied.state
        try await mac.sync(server, at: at(6))
        #expect(mac.state.marks.conflicts[item.id]?.remote.value?.kind == .snoozed, "and the next sync shows both")
        #expect(await server.marks[item.id]?.value?.kind == .snoozed, "nothing was sent over the iPhone's")
    }

    @Test func hashedMarksFindTheirItemOnTheOtherDevice() async throws {
        let server = FakeDeskCloud()
        let item = customerItem()
        var mac = Device(.macOS)
        mac.desk.markDone(item, now: t0)
        try await mac.sync(server, at: at(1))
        let keys = await Array(server.marks.keys)
        #expect(keys == [DeskCloudKey.cloud(item.id)] && !keys.joined().contains("emu_sample"), "no company id reaches the server")
        #expect(mac.desk.marks.keys.sorted() == [item.id], "the Mac keeps its own id")

        var phone = Device(.iOS)
        try await phone.sync(server, at: at(2))
        #expect(phone.desk.marks.keys.sorted() == [DeskCloudKey.cloud(item.id)], "not shown here yet: kept under its cloud key")
        #expect(phone.desk.resolve(item, now: at(2)) != .open, "and it still applies when the item shows up")
        var other = Device(.iOS)
        other.known = [item.id]
        try await other.sync(server, at: at(3))
        #expect(other.desk.marks.keys.sorted() == [item.id], "shown here: kept under the item's own id")
    }

    @Test func theSeedIsSentForTheSweepOncePerRevisionAndNeverTakenIn() async throws {
        let server = FakeDeskCloud()
        let seed = [Obligation(id: "test.seed-a", title: "Sample seed row", area: .other, due: KeyDay("2026-11-01"), source: "fixture:1",
                               recordedOn: KeyDay("2026-10-01"), origin: .seed),
                    Obligation(id: "test.seed-b", title: "Sample row the next seed drops", area: .other, due: nil, source: "fixture:2",
                               recordedOn: KeyDay("2026-10-01"), origin: .seed)]
        let accounts = [VendorAccount(id: "test-host", name: "Sample Host", purpose: "A made-up host.", source: "fixture:3",
                                      recordedOn: KeyDay("2026-10-01"), origin: .seed)]
        var mac = Device(.macOS)
        try await mac.sync(server, at: at(1), seed: seed, seedAccounts: accounts, revision: 3)
        #expect(await server.obligations["seed:test.seed-a"]?.seedRevision == 3)
        #expect(await server.vendors["seed:test-host"] != nil)
        #expect(mac.file.added.isEmpty && mac.file.accounts.isEmpty, "seed rows never enter obligations.json")
        guard case .seed(let sent)? = await server.obligations["seed:test.seed-a"]?.value else {
            Issue.record("the seed row should be on the server")
            return
        }
        #expect(sent.title == "Sample seed row" && sent.due == KeyDay("2026-11-01") && sent.consequence == nil)
        #expect(sent.source.hasPrefix("Linumic OS ObligationSeed, revision 3"), "the Mac's file paths stay in the app")
        let before = await server.written.count
        try await mac.sync(server, at: at(2), seed: seed, seedAccounts: accounts, revision: 3)
        #expect(await server.written.count == before, "nothing sent again")
        var newer = Device(.iOS)
        var changed = seed[0]
        changed.due = KeyDay("2026-11-03")
        try await newer.sync(server, at: at(3), seed: [changed], seedAccounts: accounts, revision: 4)
        #expect(await server.obligations["seed:test.seed-a"]?.seedRevision == 4)
        #expect(await server.obligations["seed:test.seed-b"]?.isDeleted == true, "a row the newer seed dropped")
        let afterNewer = await server.written.count
        try await mac.sync(server, at: at(4), seed: seed, seedAccounts: accounts, revision: 3)
        #expect(await server.written.count == afterNewer, "an older app leaves a newer seed alone")
    }

    @Test func aRowTheServerRefusesIsKeptHereAndReported() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        let o = try mac.file.add(title: "Pay the sample host", product: nil, area: .accounts, due: nil, consequence: nil,
                                 source: "sample bill", now: t0, calendar: utc)
        await server.setRefused(["row:\(o.id)"])
        let report = try await mac.sync(server, at: at(1))
        #expect(report.refused == 1 && mac.state.obligations.refused["row:\(o.id)"] == "refused by the test server")
        #expect(mac.file.added.count == 1)
        await server.setRefused([])
        try await mac.sync(server, at: at(2))
        #expect(mac.state.obligations.refused.isEmpty)
    }

    @Test func nothingThatReadsAsAKeyLeavesTheDevice() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        let item = ledgerItem()
        mac.desk.dismiss(item, reason: "used ghp_\(String(repeating: "x", count: 36)) to check", now: t0)
        let report = try await mac.sync(server, at: at(1))
        #expect(await server.marks.isEmpty, "never sent")
        #expect(report.refused == 1 && mac.state.marks.refused[item.id]?.contains("GitHub token") == true)
        #expect(mac.desk.marks[item.id]?.kind == .dismissed, "and kept here")
        mac.desk.restore(item.id)
        try await mac.sync(server, at: at(2))
        #expect(mac.state.marks.refused.isEmpty && mac.desk.restored.isEmpty, "undone before it was ever sent: nothing left to report")
    }

    @Test func entriesTheRegisterRefusesAreNotSent() async throws {
        let server = FakeDeskCloud()
        var mac = Device(.macOS)
        mac.file.added = [Obligation(id: "signing.developer-id-certificate", title: "A seed row passed off as the owner's", area: .signing,
                                     due: KeyDay("2026-11-01"), source: "x", recordedOn: KeyDay("2026-10-19"), origin: .owner)]
        mac.file.completions = [ObligationCompletion(obligationID: "owner.x", due: nil, on: KeyDay("2026-10-19")!, evidence: "  ", enteredAt: t0)]
        try await mac.sync(server, at: at(1))
        #expect(await server.obligations.isEmpty)
    }
}

// MARK: - The Mac's ledger lines

@Suite("Desk sync: what the Mac's ledger reading holds back")
struct DeskSyncLedgerTests {
    @Test func addressesNumbersAndKeysAreHeldBackDatesAreNot() {
        for held in ["Write to sample@example.com about it", "Call +93 70 123 4567 today", "Ring 0700 123 456 after Friday",
                     "Ring (613) 555-0123", "Use ghp_\(String(repeating: "a", count: 36)) for the job", "شماره ۰۷۰۰۱۲۳۴۵۶ را بگیر"] {
            #expect(DeskCloudLedger.withholds(held), "\(held)")
        }
        for kept in ["Ship 1.3.0 (4) by 2026-10-19 or 2026-11-01", "versionCode 12, build 20261019", "P0: renew before ۲۰۲۶-۱۰-۲۷",
                     "Play account 7764339598095587681 (personal)"] {
            #expect(!DeskCloudLedger.withholds(kept), "\(kept)")
        }
    }

    @Test func aReadingKeepsOnlyWhatTheDeskNeeds() throws {
        var fs = FakeLedgerFS()
        fs.files["\(LedgerFixtures.home)/Projects/Multiplatform/WorkTrack/PRIORITIES.md"] = """
        آخرین بازبینی: 2026-10-10
        ## P0
        - [ ] **Sign the sample contract.** Detail that stays on the Mac.
          - a note under it that stays on the Mac
        """
        let reading = LedgerReader.read(home: LedgerFixtures.home, granted: ["\(LedgerFixtures.home)/Projects/Multiplatform"], fs: fs,
                                        now: LedgerFixtures.now)
        let upload = DeskCloudLedger.upload(reading, now: LedgerFixtures.now, calendar: utc)
        let json = String(decoding: try InventoryCoding.encoder().encode(upload), as: UTF8.self)
        #expect(json.contains("Sign the sample contract"))
        #expect(!json.contains("Detail that stays") && !json.contains("a note under it"), "no detail, no lines under it")
        #expect(upload.items.allSatisfy { $0.id.hasPrefix("ledger.") || $0.id.hasPrefix("next-actions|") })
        #expect(upload.sources.count == LedgerAllowList.all.count)
        #expect(upload.digest == CloudLedgerUpload.digest(upload.items) && upload.digest.count == 64)
        // Back on an iPhone, the ids are the Mac's ids, so marks match.
        let snapshot = CloudLedgerSnapshot(version: 1, readAt: upload.readAt, sources: upload.sources, items: upload.items)
        let mac = DeskBuilder.ledgerItems(.read(reading), today: KeyDay(LedgerFixtures.now, calendar: utc))
        #expect(DeskCloudLedger.items(snapshot).map(\.id) == mac.map(\.id))
        #expect(DeskCloudLedger.items(snapshot).map(\.factHash) == mac.map(\.factHash))
    }
}

// MARK: - The Supabase client

private final class Recorder: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) -> (Int, Data)
    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = handler(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let config = SupabaseConfig(url: URL(string: "https://sample.supabase.co")!, publishableKey: "sb_publishable_SAMPLE")
private func body(_ r: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
}

@Suite("Desk sync: Supabase client")
struct DeskSyncClientTests {
    @Test func pullReadsEveryRowTheServerWrote() async throws {
        let data = try fixture("desk-sync-pull")
        let t = Recorder { _ in (200, data) }
        let pull = try await SupabaseDeskCloud(config: config, transport: t, token: { "admin-jwt" }).pull()
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString == "https://sample.supabase.co/rest/v1/rpc/desk_sync_pull")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer admin-jwt")
        #expect(pull.unreadable == 0)

        #expect(pull.marks.count == 4)
        let tomb = try #require(pull.marks.first { $0.id == "brief.monitor|monitor.down.sample.api|fact" })
        #expect(tomb.isDeleted && tomb.version == 2 && tomb.writtenOn == .iOS)
        let snooze = try #require(pull.marks.first { $0.id.hasPrefix("brief.worktrack|h-") })
        #expect(snooze.value?.kind == .snoozed && snooze.value?.until == ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z"))
        #expect(pull.marks.first { $0.id.hasPrefix("next-actions|") }?.value?.reason == "Handled on the phone")

        let seed = try #require(pull.obligations.first { $0.entry == "seed" })
        #expect(seed.seedRevision == 3 && seed.key == "test.seed-x")
        guard case .row(let row)? = pull.obligations.first(where: { $0.entry == "row" })?.value else {
            Issue.record("the owner's row should decode")
            return
        }
        #expect(row.title == "Pay the sample host" && row.due == KeyDay("2026-11-01") && row.origin == .owner)
        #expect(pull.obligations.first { $0.entry == "done" }?.isDeleted == true)
        guard case .facts(let facts)? = pull.vendors.first(where: { $0.entry == "facts" })?.value else {
            Issue.record("the facts should decode")
            return
        }
        #expect(facts.edits.count == 2 && facts.edits.last?.cost?.amount == Decimal(string: "12.5"))

        let ledger = try #require(pull.ledger)
        #expect(ledger.version == 1 && ledger.items.count == 3 && ledger.sources.count == 3)
        #expect(ledger.readAt == ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z"))
        let items = DeskCloudLedger.items(ledger)
        #expect(items.count == 3)
        #expect(items.first { $0.origin == .nextActions }?.horizon == .today)
        #expect(items.first { $0.kind == .source }?.kindKey == "not-found")
        let statuses = DeskCloudLedger.sources(ledger)
        #expect(statuses.first { $0.id == "worktrack" }?.state == .read(open: 1, ticked: 2, skipped: [], reviewedOn: KeyDay("2026-10-18")))
        #expect(statuses.first { $0.id == "talar" }?.state == .notFound)
    }

    @Test func pushSendsTheVersionsAndReadsEachAnswer() async throws {
        let data = try fixture("desk-sync-push")
        let t = Recorder { _ in (200, data) }
        let client = SupabaseDeskCloud(config: config, transport: t, token: { "admin-jwt" })
        let results = try await client.pushMarks([
            CloudChange(id: "ledger.worktrack|1a2b3c4d5e6f7081|checkbox", entry: "mark", key: nil, expectedVersion: 1, value: waiting),
            CloudChange(id: "brief.monitor|monitor.down.x|fact", entry: "mark", key: nil, expectedVersion: 2, value: nil),
        ], device: .iOS)
        let r = try #require(t.requests.first)
        #expect(r.url?.lastPathComponent == "push_desk_state")
        let sent = try body(r)
        #expect(sent["device"] as? String == "iOS")
        let changes = try #require(sent["changes"] as? [[String: Any]])
        #expect(changes[0]["expectedVersion"] as? Int == 1 && (changes[0]["data"] as? [String: Any])?["kind"] as? String == "waiting")
        #expect(changes[1]["data"] is NSNull, "a tombstone sends data null")
        #expect(results.map(\.status) == [.applied, .stale, .invalid])
        #expect(results[0].row?.version == 2 && results[0].row?.value?.kind == .waiting)
        #expect(results[1].row?.value?.kind == .dismissed, "stale answers the row as it is")
        #expect(results[2].message?.contains("check constraint") == true)
    }

    @Test func obligationsCarryTheirEntryAndKey() async throws {
        let t = Recorder { _ in (200, Data("[]".utf8)) }
        let client = SupabaseDeskCloud(config: config, transport: t, token: { "admin-jwt" })
        let c = ObligationCompletion(obligationID: "owner.1", due: KeyDay("2026-11-01"), on: KeyDay("2026-10-19")!, evidence: "sample receipt",
                                     enteredAt: t0)
        _ = try await client.pushObligations([CloudChange(id: "done:owner.1|2026-11-01", entry: "done", key: "owner.1", expectedVersion: 0,
                                                          value: .done(c))], device: .macOS)
        let request = try #require(t.requests.first)
        let change = try #require((try body(request)["changes"] as? [[String: Any]])?.first)
        #expect(change["entry"] as? String == "done" && change["key"] as? String == "owner.1")
        let data = try #require(change["data"] as? [String: Any])
        #expect(data["evidence"] as? String == "sample receipt" && data["due"] as? String == "2026-11-01")
        #expect(data["enteredAt"] as? String == "2026-10-19T08:00:00Z")
        _ = try await client.pushVendors([], device: .macOS)
        #expect(t.requests.count == 1, "nothing to send, no request")
    }

    @Test func theLedgerReadingIsSentWithTheVersionItReplaces() async throws {
        let data = try fixture("desk-sync-ledger")
        let t = Recorder { _ in (200, data) }
        let upload = CloudLedgerUpload(readAt: t0, sources: [], items: [])
        let answer = try await SupabaseDeskCloud(config: config, transport: t, token: { "admin-jwt" })
            .replaceLedger(expectedVersion: 1, reading: upload)
        let sent = try body(#require(t.requests.first))
        #expect(sent["expected_version"] as? Int == 1)
        #expect((sent["reading"] as? [String: Any])?["digest"] as? String == upload.digest)
        #expect(answer.status == .applied && answer.version == 2)
    }

    @Test func aRowOfAKindThisVersionCantReadIsLeftAlone() throws {
        let json = #"{"deskState":[],"vendors":[],"obligations":[{"id":"later:x","entry":"later","key":"x","version":1,"deleted":false,"data":{"a":1}},{"id":"date:x","entry":"date","key":"x","version":1,"deleted":false,"data":{"obligationID":"x","due":"2026-11-01","source":"s","enteredAt":"2026-10-19T08:00:00Z"}}],"ledger":null}"#
        let pull = try InventoryCoding.decoder().decode(DeskCloudPull.self, from: Data(json.utf8))
        #expect(pull.unreadable == 1 && pull.obligations.map(\.id) == ["date:x"] && pull.ledger == nil)
    }

    @Test func notAnAdminIsReportedAsSuch() async throws {
        let t = Recorder { _ in (400, Data(#"{"code":"42501","message":"Not authorised: Linumic OS admins only"}"#.utf8)) }
        await #expect(throws: SupabaseError.notAuthorized) {
            try await SupabaseDeskCloud(config: config, transport: t, token: { "someone-else" }).pull()
        }
    }
}

// MARK: - The server's sweep and the app's alerts

private struct SweepFixture: Decodable {
    var today: KeyDay
    var seedRevision: Int
    var seed: [Obligation]
    var seedAccounts: [VendorAccount]
    var file: ObligationsFile
    var expectedKeys: [String]
    var nextDay: KeyDay
    var expectedNextDayKeys: [String]
}

@Suite("Desk sync: the server's sweep")
struct DeskSyncSweepTests {
    /// supabase/tests/desk-sync/behaviour.sql runs the server's sweep on the same fixture and expects the same keys.
    @Test func theAppAndTheServerNameTheSameAlerts() throws {
        let f = try InventoryCoding.decoder().decode(SweepFixture.self, from: fixture("desk-sync-sweep"))
        func keys(on day: KeyDay, sent: Set<String>) -> [String] {
            let now = day.start(calendar: utc).addingTimeInterval(12 * 3600)
            let register = ObligationsBuilder.build(file: f.file, live: ObligationLiveInput(), now: now, calendar: utc, seed: f.seed,
                                                    seedAccounts: f.seedAccounts)
            return ObligationAlerts.due(register, today: day, sent: sent).map(\.key).sorted()
        }
        #expect(keys(on: f.today, sent: []) == f.expectedKeys)
        #expect(keys(on: f.nextDay, sent: Set(f.expectedKeys)) == f.expectedNextDayKeys)
        // The rows the sweep reads are the rows the sync sends.
        let rows = DeskCloudMapping.localObligations(f.file)
        #expect(rows.keys.contains("date:test.seed-e") && rows.keys.contains("done:test.seed-d|2026-10-10"))
        #expect(DeskCloudMapping.localVendors(f.file).keys.sorted() == ["account:owner.00000000000000a1", "facts:test-host"])
    }

    @Test func eventKindsMatchTheMigration() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sql = try String(contentsOf: root.appending(path: "supabase/migrations/20261019090100_obligation_sweep.sql"), encoding: .utf8)
        let check = try #require(sql.range(of: "check (kind in (").map { sql[$0.upperBound...] }?.prefix { $0 != ")" })
        let kinds = check.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\n")) }
        #expect(Set(kinds) == Set(SentinelEventKind.allCases.map(\.rawValue)))
    }

    @Test func obligationEventsDecodeAndAnOldServerIsAskedAsBefore() async throws {
        let event = #"[{"id":9,"occurredAt":"2026-10-19T06:15:00Z","kind":"obligationDue","severity":"warning","subject":"test.seed-a","product":"Linumic","title":"Sample seed row is due in 7 days","detail":{"obligationID":"test.seed-a","title":"Sample seed row","renewal":false,"due":"2026-10-26","daysLeft":7,"lead":7,"key":"obligation:test.seed-a:2026-10-26:7"}}]"#
        let t = Recorder { r in
            let asked = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])?["include_obligations"] != nil
            return asked ? (404, Data(#"{"code":"PGRST202","message":"Could not find the function"}"#.utf8)) : (200, Data(event.utf8))
        }
        let events = try await SentinelClient(config: config, transport: t, token: { "admin-jwt" }).events(limit: 10, includeAcknowledged: false)
        #expect(t.requests.count == 2, "asked with include_obligations, then as before")
        let e = try #require(events.first)
        #expect(e.kind == .obligationDue && e.detail?.lead == 7 && e.detail?.key == "obligation:test.seed-a:2026-10-26:7")
        #expect(e.detail?.title == "Sample seed row" && e.detail?.renewal == false && e.detail?.due == "2026-10-26")
    }
}

@Suite("Desk sync: the automation job")
struct DeskSyncJobTests {
    @Test func everyThirtyMinutesOverTheNetworkWithinTwoMinutes() {
        let spec = AutomationCatalog.spec(.deskSync)
        #expect(spec.cadence == 30 * 60 && spec.needsNetwork && spec.runsInBackground && spec.timeLimit == 2 * 60)
        let ids = AutomationCatalog.jobs.map(\.id)
        #expect(ids.firstIndex(of: .deskSync)! < ids.firstIndex(of: .ledgers)!, "the ledgers still run just before the Brief")
        #expect(ids.firstIndex(of: .deskSync)! > ids.firstIndex(of: .licences)!)
    }
}
