import Foundation

// MARK: - desk-state.json and obligations.json as cloud rows

public enum DeskCloudMapping {
    // MARK: Row ids

    /// "row:<id>", "seed:<id>", "date:<id>", or "done:<id>|<due day, or ->".
    public static func obligationRowID(_ entry: String, _ obligationID: String, due: KeyDay? = nil) -> String {
        entry == "done" ? "done:\(obligationID)|\(due?.description ?? "-")" : "\(entry):\(obligationID)"
    }

    /// "account:<id>", "seed:<id>" or "facts:<id>".
    public static func vendorRowID(_ entry: String, _ accountID: String) -> String { "\(entry):\(accountID)" }

    /// The entry and key of an obligations row id ("done:x|2026-11-01" → ("done", "x")).
    static func obligationEntryKey(_ id: String) -> (entry: String, key: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let entry = String(id[..<colon])
        var key = String(id[id.index(after: colon)...])
        if entry == "done", let bar = key.lastIndex(of: "|") { key = String(key[..<bar]) }
        return key.isEmpty ? nil : (entry, key)
    }

    static func vendorEntryKey(_ id: String) -> (entry: String, key: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let key = String(id[id.index(after: colon)...])
        return key.isEmpty ? nil : (String(id[..<colon]), key)
    }

    /// A date entry for an account's renewal row ("date:account.<id>.renewal"). Never synced: an account's renewal day
    /// is set on its card (the facts), and `editAccount` removes such a date here, which the sync would otherwise read
    /// as a file that lost a row and take back in.
    static func isAccountRenewalDate(_ id: String) -> Bool {
        guard let (entry, key) = obligationEntryKey(id) else { return false }
        return entry == "date" && VendorAccount.isRenewalObligationID(key)
    }

    // MARK: This device's rows

    /// The owner's marks by cloud key. Two marks for one item (one under its id, one under its cloud key) give the newer.
    /// An undo not yet sent is a deletion. A Sales item's dismissal carries only a preset reason (`SalesDismissReason`).
    public static func localMarks(_ state: DeskState) -> [String: CloudLocal<DeskMark>] {
        var out: [String: CloudLocal<DeskMark>] = [:]
        for (id, mark) in state.marks.sorted(by: { $0.key < $1.key }) {
            let key = DeskCloudKey.cloud(id)
            if case .value(let other)? = out[key], other.at >= mark.at { continue }
            out[key] = .value(SalesDismissReason.cloudSafe(mark, itemID: id))
        }
        for id in state.restored.sorted() {
            let key = DeskCloudKey.cloud(id)
            if out[key] == nil { out[key] = .deleted }
        }
        return out
    }

    /// What the register would take from obligations.json, as rows: the owner's own obligations, his dates and his Done
    /// marks, and a Done he took back as a deletion. Entries the register refuses (no source, no evidence, not the
    /// owner's) are not sent: they are reported on this device, as before.
    public static func localObligations(_ file: ObligationsFile) -> [String: CloudLocal<ObligationCloudPayload>] {
        var out: [String: CloudLocal<ObligationCloudPayload>] = [:]
        for o in file.added where syncable(o) {
            let id = obligationRowID("row", o.id)
            if out[id] == nil { out[id] = .value(.row(o)) }
        }
        for d in file.dates.sorted(by: { $0.enteredAt < $1.enteredAt })
        where ObligationsFile.clean(d.source) != nil && validKey(d.obligationID) && !VendorAccount.isRenewalObligationID(d.obligationID) {
            out[obligationRowID("date", d.obligationID)] = .value(.date(d))
        }
        for r in file.reopened where validKey(r.obligationID) {
            out[obligationRowID("done", r.obligationID, due: r.due)] = .deleted
        }
        for c in file.completions.sorted(by: { $0.enteredAt < $1.enteredAt })
        where ObligationsFile.clean(c.evidence) != nil && validKey(c.obligationID) {
            out[obligationRowID("done", c.obligationID, due: c.due)] = .value(.done(c))
        }
        return out
    }

    /// The owner's accounts and, per account, every fact he recorded with its source.
    public static func localVendors(_ file: ObligationsFile) -> [String: CloudLocal<VendorCloudPayload>] {
        var out: [String: CloudLocal<VendorCloudPayload>] = [:]
        for a in file.accounts where syncable(a) {
            let id = vendorRowID("account", a.id)
            if out[id] == nil { out[id] = .value(.account(a)) }
        }
        let edits = Dictionary(grouping: file.accountEdits.filter(syncable), by: \.accountID)
        for (accountID, list) in edits where validKey(accountID) {
            out[vendorRowID("facts", accountID)] = .value(.facts(AccountFacts(edits: list)))
        }
        return out
    }

    static func validKey(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:@-".contains($0)) }
    }

    static func syncable(_ o: Obligation) -> Bool {
        ObligationsBuilder.isOwners(id: o.id, origin: o.origin) && validKey(o.id) && ObligationsFile.clean(o.title) != nil
            && ObligationsFile.clean(o.source) != nil && o.recordedOn != nil
    }

    static func syncable(_ a: VendorAccount) -> Bool {
        ObligationsBuilder.isOwners(id: a.id, origin: a.origin) && validKey(a.id) && ObligationsFile.clean(a.name) != nil
            && ObligationsFile.clean(a.source) != nil && a.recordedOn != nil
            && (a.holder == nil || ObligationsFile.clean(a.holderSource) != nil)
            && (a.renewal == nil || ObligationsFile.clean(a.renewalSource) != nil)
            && (a.cost == nil || a.cost?.checked != nil)
    }

    /// An edit the register applies whole: every value it sets has its source, and a cost is one the sheet accepts.
    static func syncable(_ e: VendorAccountEdit) -> Bool {
        (e.renewal == nil || ObligationsFile.clean(e.renewalSource) != nil)
            && (e.holder == nil || ObligationsFile.clean(e.holderSource) != nil)
            && (e.cost == nil || e.cost?.checked == e.cost)
    }

    // MARK: Taking rows in

    /// The item id a cloud key stands for on this device: the id of a mark held here, else of an item the Desk shows,
    /// else the key itself (a hashed key whose item this device has not shown; `DeskState.mark(for:)` finds it there).
    static func localID(for key: String, marks: [String: DeskMark], known: Set<String>) -> String {
        guard DeskCloudKey.isHashed(key) else { return key }
        if let id = marks.keys.sorted().first(where: { $0 != key && DeskCloudKey.cloud($0) == key }) { return id }
        if let id = known.sorted().first(where: { DeskCloudKey.cloud($0) == key }) { return id }
        return key
    }

    /// Writes one mark (or its absence) for a cloud key into the state. An undo still waiting to be sent for that item is
    /// settled by it: the cloud's version is what the item now has.
    static func set(_ mark: DeskMark?, key: String, in state: inout DeskState, known: Set<String>) {
        let id = localID(for: key, marks: state.marks, known: known)
        for other in state.marks.keys where DeskCloudKey.cloud(other) == key { state.marks[other] = nil }
        state.restored = state.restored.filter { DeskCloudKey.cloud($0) != key }
        if let mark { state.marks[id] = mark }
    }

    /// Writes one obligations row into the file. Only a Done can be taken back; a tombstone of anything else (no device
    /// writes one) is not applied, so nothing the owner entered is removed by a row from elsewhere.
    static func set(_ value: ObligationCloudPayload?, id: String, in file: inout ObligationsFile) {
        guard let (entry, key) = obligationEntryKey(id) else { return }
        switch (entry, value) {
        case ("row", .row(let o)?):
            if let i = file.added.firstIndex(where: { $0.id == o.id }) { file.added[i] = o } else { file.added.append(o) }
        case ("date", .date(let d)?):
            file.dates.removeAll { $0.obligationID == key }
            file.dates.append(d)
        case ("done", .done(let c)?):
            file.completions.removeAll { $0.obligationID == c.obligationID && $0.due == c.due }
            file.completions.append(c)
            file.reopened.removeAll { $0.obligationID == c.obligationID && $0.due == c.due }
        case ("done", nil):
            let due = id.split(separator: "|").last.flatMap { KeyDay(String($0)) }
            file.completions.removeAll { $0.obligationID == key && $0.due == due }
        default:
            break
        }
    }

    static func set(_ value: VendorCloudPayload?, id: String, in file: inout ObligationsFile) {
        guard let (entry, key) = vendorEntryKey(id) else { return }
        switch (entry, value) {
        case ("account", .account(let a)?):
            if let i = file.accounts.firstIndex(where: { $0.id == a.id }) { file.accounts[i] = a } else { file.accounts.append(a) }
        case ("facts", .facts(let f)?):
            // Edits this device holds that the register would not apply are not synced; they stay where they are.
            let kept = file.accountEdits.filter { $0.accountID == key && !syncable($0) }
            file.accountEdits.removeAll { $0.accountID == key }
            file.accountEdits += (f.edits + kept).sorted { $0.enteredAt < $1.enteredAt }
        default:
            break
        }
    }

    // MARK: The seed, for the server's sweep

    /// What the sweep needs of a seed row: its id, title, product, day and lead days. Its sources and consequence (file
    /// paths and readings on the owner's Mac) stay in the app; the row names where it comes from instead.
    static func seedRow(_ o: Obligation, revision: Int) -> Obligation {
        Obligation(id: o.id, title: o.title, product: o.product, area: o.area, due: o.due, source: seedSource(revision),
                   recordedOn: o.recordedOn, leadDays: o.leadDays, origin: .seed, subject: o.subject)
    }

    /// What the sweep needs of a seed account: its id and name (for "<name>: renewal").
    static func seedAccount(_ a: VendorAccount, revision: Int) -> VendorAccount {
        VendorAccount(id: a.id, name: a.name, purpose: a.purpose, source: seedSource(revision), recordedOn: a.recordedOn, origin: .seed)
    }

    static func seedSource(_ revision: Int) -> String { "Linumic OS ObligationSeed, revision \(revision) (sources in the app)" }

    /// The seed rows to send: missing on the server, or written there by an app with an older seed. Rows an older seed
    /// had and this one does not are made tombstones, and so is a seed row a live reading replaces on the devices
    /// (domain.linumic.com: the Monitor's RDAP date, never the seed's, is the one that counts, and a Done typed for it is
    /// not applied), which is never sent. A newer app's rows, and rows this version can't read, are left alone.
    static func seedChanges(remote: [CloudRow<ObligationCloudPayload>], seed: [Obligation], revision: Int,
                            unreadable: Set<String> = []) -> [CloudChange<ObligationCloudPayload>] {
        let byID = Dictionary(remote.filter { $0.entry == "seed" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CloudChange<ObligationCloudPayload>] = []
        var mine = Set<String>()
        for o in seed where validKey(o.id) && !ObligationsBuilder.isLiveID(o.id) {
            let id = obligationRowID("seed", o.id)
            mine.insert(id)
            guard !unreadable.contains(id) else { continue }
            let row = byID[id]
            // Written by an app with this seed or a newer one: left as it is (two builds never take turns over a row).
            if let row, (row.seedRevision ?? 0) >= revision { continue }
            out.append(CloudChange(id: id, entry: "seed", key: o.id, expectedVersion: row?.version ?? 0,
                                   value: .seed(seedRow(o, revision: revision)), seedRevision: revision))
        }
        for row in byID.values where !mine.contains(row.id) && row.value != nil && (row.seedRevision ?? 0) < revision {
            out.append(CloudChange(id: row.id, entry: "seed", key: row.key, expectedVersion: row.version, value: nil, seedRevision: revision))
        }
        return out.sorted { $0.id < $1.id }
    }

    static func seedAccountChanges(remote: [CloudRow<VendorCloudPayload>], accounts: [VendorAccount], revision: Int,
                                   unreadable: Set<String> = []) -> [CloudChange<VendorCloudPayload>] {
        let byID = Dictionary(remote.filter { $0.entry == "seed" }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CloudChange<VendorCloudPayload>] = []
        var mine = Set<String>()
        for a in accounts where validKey(a.id) {
            let id = vendorRowID("seed", a.id)
            mine.insert(id)
            guard !unreadable.contains(id) else { continue }
            let row = byID[id]
            if let row, (row.seedRevision ?? 0) >= revision { continue }
            out.append(CloudChange(id: id, entry: "seed", key: a.id, expectedVersion: row?.version ?? 0,
                                   value: .seed(seedAccount(a, revision: revision)), seedRevision: revision))
        }
        for row in byID.values where !mine.contains(row.id) && row.value != nil && (row.seedRevision ?? 0) < revision {
            out.append(CloudChange(id: row.id, entry: "seed", key: row.key, expectedVersion: row.version, value: nil, seedRevision: revision))
        }
        return out.sorted { $0.id < $1.id }
    }
}

// MARK: - The Mac's ledger reading in the cloud

public enum DeskCloudLedger {
    /// What a line's title is sent as when its text is held back.
    public static let withheldTitle = "(withheld)"

    /// The reading the Mac sends: its ledger and NEXT-ACTIONS lines as Desk items (title, product, file:line, severity,
    /// the fact hash its marks need), and each ledger's state. A line whose text holds an email address, a phone number
    /// or a key is sent without its text.
    public static func upload(_ reading: LedgerReading, now: Date, calendar: Calendar = KeyDay.calendar) -> CloudLedgerUpload {
        let items = DeskBuilder.ledgerItems(.read(reading), today: KeyDay(now, calendar: calendar)).map(item)
        let sources = DeskBuilder.sources(.read(reading)).map(source)
        return CloudLedgerUpload(readAt: DeskState.stamp(reading.readAt), sources: sources, items: items)
    }

    /// The reading sent when the owner turned ledger lines off on the Mac: none, so the cloud copy is emptied.
    public static func empty(at: Date) -> CloudLedgerUpload {
        CloudLedgerUpload(readAt: DeskState.stamp(at), sources: [], items: [], linesOff: true)
    }

    static func item(_ i: DeskItem) -> CloudLedgerItem {
        let withheld = withholds(i.title)
        let title = String(i.title.prefix(2000))
        return CloudLedgerItem(id: i.id, title: withheld || title.trimmingCharacters(in: .whitespaces).isEmpty ? withheldTitle : title,
                               titleWithheld: withheld, domain: String(i.domain.key.prefix(100)),
                               domainName: String(i.domain.name.prefix(100)), severity: severityKey(i.severity),
                               kind: i.kind == .source ? "source" : "task", kindKey: i.kindKey,
                               subject: withholds(i.subject) ? "" : String(i.subject.prefix(300)), file: i.evidence.file,
                               line: i.evidence.line, due: i.due, horizon: i.horizon?.rawValue, ownerAction: i.ownerAction,
                               factHash: i.factHash)
    }

    static func source(_ s: DeskSourceStatus) -> CloudLedgerSource {
        switch s.state {
        case .unsupported: CloudLedgerSource(id: s.id, path: s.displayPath, state: "unsupported")
        case .notRead: CloudLedgerSource(id: s.id, path: s.displayPath, state: "notRead")
        case .notGranted: CloudLedgerSource(id: s.id, path: s.displayPath, state: "notGranted")
        case .notFound: CloudLedgerSource(id: s.id, path: s.displayPath, state: "notFound")
        case .unreadable(let why):
            CloudLedgerSource(id: s.id, path: s.displayPath, state: "unreadable", reason: withholds(why) ? nil : String(why.prefix(300)))
        case .read(let open, let ticked, let skipped, let reviewedOn):
            CloudLedgerSource(id: s.id, path: s.displayPath, state: "read", open: open, ticked: ticked, skipped: skipped, day: reviewedOn)
        case .report(let today, let thisWeek, let skipped, let day):
            CloudLedgerSource(id: s.id, path: s.displayPath, state: "report", today: today, thisWeek: thisWeek, skipped: skipped, day: day)
        }
    }

    static func severityKey(_ s: BriefSeverity) -> String {
        switch s {
        case .high: "high"
        case .normal: "normal"
        case .info: "info"
        }
    }

    // MARK: What is held back

    static let emailPattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    /// A phone number written the way numbers are dialled: starting with +, ( or 0 (Latin, Persian or Arabic-Indic),
    /// with at least nine digits in it. A date or a version is not one.
    static let phonePattern = #"(?:\+|\(|[0۰٠])[0-9۰-۹٠-٩][0-9۰-۹٠-٩ ()\-]{7,}[0-9۰-۹٠-٩]"#

    /// Whether a line's text is kept off the cloud: it holds an email address, a phone number or something that reads as
    /// a key or token. A heuristic: a name is not detected.
    public static func withholds(_ text: String) -> Bool {
        if let email = try? Regex(emailPattern), text.contains(email) { return true }
        if let phone = try? Regex(phonePattern) {
            for match in text.matches(of: phone) where text[match.range].count(where: \.isNumber) >= 9 { return true }
        }
        return !ContinuityBundle.forbiddenKinds(in: Data(text.utf8)).isEmpty
    }

    // MARK: On iPhone and iPad

    /// The Mac's lines as Desk items, dated with the Mac's reading. A line whose text was held back says so.
    public static func items(_ snapshot: CloudLedgerSnapshot) -> [DeskItem] {
        snapshot.items.compactMap { item($0, readAt: snapshot.readAt) }
    }

    static func item(_ c: CloudLedgerItem, readAt: Date) -> DeskItem? {
        let parts = c.id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let originKey = String(parts[0])
        let origin: DeskOrigin
        if originKey == DeskOrigin.nextActions.key {
            origin = .nextActions
        } else if originKey.hasPrefix("ledger."), originKey.count > 7 {
            origin = .ledger(String(originKey.dropFirst(7)))
        } else {
            return nil
        }
        let severity: BriefSeverity = switch c.severity {
        case "high": .high
        case "normal": .normal
        default: .info
        }
        let location = c.file ?? c.subject
        return DeskItem(origin: origin, subjectKey: String(parts[1]), kindKey: String(parts[2]),
                        kind: c.kind == "source" ? .source : .task, domain: DeskDomain(c.domain, c.domainName),
                        severity: severity,
                        title: c.titleWithheld ? L("This line's text was kept off the cloud (it holds an address, a phone number or a key). Read it on the Mac.") : c.title,
                        subject: c.subject, due: c.due, horizon: c.horizon.flatMap(DeskHorizon.init(rawValue:)),
                        ownerAction: c.ownerAction,
                        evidence: DeskEvidence(source: LF("%@ (read on the Mac)", location), file: c.file, line: c.line,
                                               readAt: readAt, cadence: DeskBuilder.ledgerCadence),
                        factHash: c.factHash,
                        destination: c.file.map { .file(path: $0, line: c.line) } ?? .ledgerAccess,
                        readOn: .macOS)
    }

    /// Each ledger as the Mac last read it.
    public static func sources(_ snapshot: CloudLedgerSnapshot) -> [DeskSourceStatus] {
        snapshot.sources.map { s in
            let source = LedgerAllowList.all.first { $0.id == s.id } ?? LedgerSource(s.id, s.path, .shared)
            let state: DeskSourceStatus.State = switch s.state {
            case "read": .read(open: s.open ?? 0, ticked: s.ticked ?? 0, skipped: s.skipped ?? [], reviewedOn: s.day)
            case "report": .report(today: s.today ?? 0, thisWeek: s.thisWeek ?? 0, skipped: s.skipped ?? [], day: s.day)
            case "notGranted": .notGranted
            case "notFound": .notFound
            case "unreadable": .unreadable(s.reason ?? "")
            case "notRead": .notRead
            default: .unsupported
            }
            return DeskSourceStatus(source: source, displayPath: s.path, state: state, readAt: snapshot.readAt)
        }
    }

    /// Ledgers the Mac read in this snapshot (their items are all here), for dropping marks on lines gone from them.
    static func readOrigins(_ snapshot: CloudLedgerSnapshot) -> Set<String> {
        Set(snapshot.sources.filter { $0.state == "read" || $0.state == "report" }
            .map { $0.id == LedgerAllowList.nextActions.id ? DeskOrigin.nextActions.key : DeskOrigin.ledger($0.id).key })
    }
}
