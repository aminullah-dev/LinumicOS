import Foundation

// MARK: - Building the Desk

/// The ledgers as the App holds them.
public enum DeskLedgerInput: Hashable, Sendable {
    /// This device can't read the owner's folders (iPhone, iPad). No ledger items, and a note says why.
    case unsupported
    /// Not read yet in this launch: every ledger is an item "not read yet".
    case notRead
    case read(LedgerReading)
    /// This device can't read the ledgers, and the Mac's last reading came from the cloud: its lines, dated with the
    /// Mac's read time (docs/desk-sync.md).
    case cloud(CloudLedgerSnapshot)
}

/// One item as the Desk shows it.
public struct DeskRow: Identifiable, Hashable, Sendable {
    public var item: DeskItem
    public var bucket: DeskBucket
    public var resolution: DeskResolution
    public var isStale: Bool

    public var id: String { item.id }

    /// "Still open according to <source>" for a Done that the next reading did not confirm.
    public var stillOpenNote: String? {
        guard case .reopened = resolution else { return nil }
        return LF("Still open according to %@", item.evidence.source)
    }
}

/// Rows of one product.
public struct DeskGroup: Identifiable, Hashable, Sendable {
    public var domain: DeskDomain
    public var rows: [DeskRow]
    public var id: String { domain.key }
}

/// One ledger as it was last read, for the header and the Settings card.
public struct DeskSourceStatus: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case unsupported
        case notRead
        case notGranted
        case notFound
        case unreadable(String)
        /// A PRIORITIES.md, read: open items, ticked checkboxes, lines set aside, and the review day when there is one.
        case read(open: Int, ticked: Int, skipped: [Int], reviewedOn: KeyDay?)
        /// The NEXT-ACTIONS report, read: the owner's TODAY and THIS WEEK items, lines set aside, and the report's day.
        /// It has no checkboxes, so nothing is "ticked" in it.
        case report(today: Int, thisWeek: Int, skipped: [Int], day: KeyDay?)
    }

    public var source: LedgerSource
    public var displayPath: String
    public var state: State
    public var readAt: Date?

    public var id: String { source.id }

    /// Read this time (a PRIORITIES.md or the report).
    public var isRead: Bool {
        switch state {
        case .read, .report: true
        case .unsupported, .notRead, .notGranted, .notFound, .unreadable: false
        }
    }
}

public struct Desk: Hashable, Sendable {
    public var generatedAt: Date
    public var today: [DeskRow]
    public var thisWeek: [DeskRow]
    public var later: [DeskRow]
    /// Ledger lines the owner marked Done that the ledger still lists.
    public var markedNotTicked: [DeskRow]
    /// Snoozed, waiting on others, dismissed, and Done until the next reading.
    public var hidden: [DeskRow]
    public var sources: [DeskSourceStatus]
    /// Marks that no longer apply (a snooze that ended, a fact that changed, an item gone from a source that was read).
    public var obsoleteMarks: Set<String>

    public func rows(_ bucket: DeskBucket) -> [DeskRow] {
        switch bucket {
        case .today: today
        case .thisWeek: thisWeek
        case .later: later
        }
    }

    public var open: [DeskRow] { today + thisWeek + later }

    /// Rows grouped by product, focus products first, keeping the rows' order within each group.
    public static func groups(_ rows: [DeskRow]) -> [DeskGroup] {
        var order: [DeskDomain] = []
        var byDomain: [DeskDomain: [DeskRow]] = [:]
        for row in rows {
            if byDomain[row.item.domain] == nil { order.append(row.item.domain) }
            byDomain[row.item.domain, default: []].append(row)
        }
        return order.sorted(by: DeskDomain.order).map { DeskGroup(domain: $0, rows: byDomain[$0] ?? []) }
    }

    public func row(_ id: String) -> DeskRow? {
        (open + markedNotTicked + hidden).first { $0.id == id }
    }
}

public enum DeskBuilder {
    /// "This week" reaches this many days ahead.
    public static let weekDays = 7
    /// A ledger whose «آخرین بازبینی» is older than this is an item (roadmap §4).
    public static let reviewStaleDays = 7

    public static func build(brief: DailyBrief?, ledgers: DeskLedgerInput, state: DeskState, now: Date,
                             calendar: Calendar = KeyDay.calendar) -> Desk {
        let today = KeyDay(now, calendar: calendar)
        var items = brief.map(briefItems) ?? []
        items += ledgerItems(ledgers, today: today)

        var lists: [DeskBucket: [DeskRow]] = [:]
        var markedNotTicked: [DeskRow] = []
        var hidden: [DeskRow] = []
        var obsolete: Set<String> = []
        for item in items {
            let resolution = state.resolve(item, now: now)
            if resolution == .open {
                if state.marks[item.id] != nil { obsolete.insert(item.id) }
                let key = DeskCloudKey.cloud(item.id)
                if key != item.id, state.marks[key] != nil { obsolete.insert(key) }
            }
            let row = DeskRow(item: item, bucket: bucket(item, today: today), resolution: resolution,
                              isStale: item.evidence.isStale(now: now))
            switch resolution {
            case .hidden: hidden.append(row)
            case .markedNotTicked: markedNotTicked.append(row)
            case .open, .reopened: lists[row.bucket, default: []].append(row)
            }
        }
        // A mark whose item is gone from a source that was read this time no longer applies. A mark kept under an item's
        // cloud key (it came from the cloud before this device showed the item) is the item's too.
        let present = Set(items.flatMap { [$0.id, DeskCloudKey.cloud($0.id)] })
        let readLedgers = readLedgerOrigins(ledgers)
        for (id, mark) in state.marks where !present.contains(id) {
            if readLedgers.contains(DeskItem.originKey(ofID: id)) || briefLineIsGone(id, mark: mark, brief: brief) {
                obsolete.insert(id)
            }
        }
        return Desk(generatedAt: now,
                    today: sorted(lists[.today] ?? []), thisWeek: sorted(lists[.thisWeek] ?? []), later: sorted(lists[.later] ?? []),
                    markedNotTicked: sorted(markedNotTicked), hidden: sorted(hidden),
                    sources: sources(ledgers), obsoleteMarks: obsolete)
    }

    // MARK: Buckets and order

    /// Today: high severity, due today or earlier (or "today" by its source), or the owner's own undated work in a
    /// focus product. This week: due within seven days, the source says "this week", or normal severity. Later: the
    /// rest. A dated item (an obligation) goes by its day and its own urgency, which its lead window (30, 14, 7, 1
    /// days) sets, not by the focus rule: a SafeBeauty post time due in 12 days is this week's, not today's.
    public static func bucket(_ item: DeskItem, today: KeyDay) -> DeskBucket {
        if item.severity == .high { return .today }
        if let due = item.due, due <= today { return .today }
        if item.horizon == .today { return .today }
        if let due = item.due {
            if today.days(until: due) <= weekDays { return .thisWeek }
            return item.severity == .normal ? .thisWeek : .later
        }
        if item.ownerAction, item.domain.isFocus { return .today }
        if item.horizon == .thisWeek { return .thisWeek }
        if item.severity == .normal { return .thisWeek }
        return .later
    }

    /// Focus products first, then by severity, due day, file and line, title.
    static func sorted(_ rows: [DeskRow]) -> [DeskRow] {
        rows.sorted { a, b in
            let x = a.item, y = b.item
            if x.domain != y.domain { return DeskDomain.order(x.domain, y.domain) }
            if x.severity != y.severity { return x.severity < y.severity }
            if x.due != y.due {
                guard let dx = x.due else { return false }
                guard let dy = y.due else { return true }
                return dx < dy
            }
            let fx = x.evidence.file ?? "", fy = y.evidence.file ?? ""
            if fx != fy { return fx < fy }
            if x.evidence.line != y.evidence.line { return (x.evidence.line ?? .max) < (y.evidence.line ?? .max) }
            return x.title < y.title
        }
    }

    // MARK: From the Daily Brief

    /// Every line of the Brief (except "What changed since yesterday", which repeats the others), every section that
    /// was not read, and every part of a section that was not read (a product not signed in, a store without a key)
    /// as an item of its own.
    static func briefItems(_ brief: DailyBrief) -> [DeskItem] {
        var items: [DeskItem] = []
        for section in brief.sections where section.kind != .changes {
            let origin = DeskOrigin.brief(section.kind)
            let cadence = cadence(section.kind)
            switch section.state {
            case .neverRead(let why):
                let domain = domain(section.kind, product: nil)
                items.append(DeskItem(origin: origin, subjectKey: "section", kindKey: "not-read", kind: .source,
                                      domain: domain, severity: domain.isFocus ? .normal : .info,
                                      title: LF("%@: not read yet", section.kind.title), detail: why, subject: section.kind.title,
                                      ownerAction: false, evidence: DeskEvidence(source: section.source, readAt: nil, cadence: cadence),
                                      factHash: DeskHash.of(section.kind.rawValue, "not-read"),
                                      destination: .screen(destination(section.kind))))
            case .unavailable(let why):
                items.append(DeskItem(origin: origin, subjectKey: "section", kindKey: "unavailable", kind: .source,
                                      domain: domain(section.kind, product: nil), severity: .normal,
                                      title: LF("%@: could not be read", section.kind.title), detail: why, subject: section.kind.title,
                                      ownerAction: false, evidence: DeskEvidence(source: section.source, readAt: section.readAt, cadence: cadence),
                                      factHash: DeskHash.of(section.kind.rawValue, "unavailable"),
                                      destination: .screen(destination(section.kind))))
            case .allClear, .items:
                for line in section.lines {
                    items.append(DeskItem(origin: origin, subjectKey: line.id, kindKey: "fact", kind: .fact,
                                          domain: domain(line.kind, product: line.product), severity: line.severity,
                                          title: line.text, detail: line.detail, subject: line.product ?? line.kind.title,
                                          due: line.due, horizon: line.horizon, ownerAction: line.severity <= .normal,
                                          evidence: DeskEvidence(source: line.source, readAt: line.readAt, cadence: cadence),
                                          factHash: factHash(line), destination: .screen(line.destination),
                                          obligationID: line.obligationID, closesAtSource: line.closesAtSource))
                }
            }
            // "All clear" is only about what was read: a part that was not read is an item, never a zero. A section that
            // could not be read can still name parts that are unknown whatever happens (Money's store proceeds). A caveat
            // on a part that was read is an item too, and says it was read, unless another section already raises it.
            for gap in section.gaps where gap.isDeskItem {
                let domain = domain(section.kind, product: gap.product)
                items.append(DeskItem(origin: origin, subjectKey: "part.\(gap.key)", kindKey: "not-read", kind: .source,
                                      domain: domain, severity: domain.isFocus ? .normal : .info,
                                      title: LF("%@: %@", section.kind.title, gap.text),
                                      detail: gap.isCaveat ? L("This part was read; its figures are shown, but may not be complete or exact until this is resolved.")
                                          : L("This part was not read, so it is unknown here, not zero."),
                                      subject: section.kind.title, ownerAction: false,
                                      evidence: DeskEvidence(source: section.source, readAt: section.readAt, cadence: cadence),
                                      factHash: DeskHash.of(section.kind.rawValue, gap.key, gap.text),
                                      destination: .screen(destination(section.kind))))
            }
        }
        return items
    }

    /// The fact is the line's subject and how urgent it is, not its wording: a countdown ("in 12 days") changes daily,
    /// an escalation to high does count. A count line adds its power-of-two bucket and a dated line its day, so a mark
    /// on "3 waiting" does not hide "30 waiting", and a new due day is a new fact. A line without either keeps the hash
    /// it always had, so marks made before stay valid.
    static func factHash(_ line: BriefLine) -> String {
        var parts = [line.id, "\(line.severity.rawValue)"]
        if let key = line.factKey { parts.append(key) }
        if let due = line.due { parts.append(due.description) }
        return parts.count == 2 ? DeskHash.of(parts[0], parts[1]) : DeskHash.of(parts)
    }

    static func domain(_ kind: BriefSourceKind, product: String?) -> DeskDomain {
        if let product { return .named(product) }
        switch kind {
        case .siteMessages: return .website
        case .worktrack: return .worktrack
        case .automation: return .linumicOS
        default: return .shared
        }
    }

    /// The screen a whole Brief section opens.
    static func destination(_ kind: BriefSourceKind) -> BriefDestination {
        switch kind {
        case .monitor: .monitor
        case .siteMessages: .siteMessages
        case .releases: .releaseCenter
        case .licences: .licences
        case .worktrack: .worktrackCustomers
        case .operations: .operations(nil)
        case .oversight: .oversight
        case .keys: .keys
        case .obligations: .obligations
        case .money: .money
        case .sales: .sales(nil)
        case .products: .products(nil)
        case .agents: .agents(nil)
        case .legal: .legal
        case .automation, .changes: .automation
        }
    }

    /// How often the job behind a Brief section reads it.
    static func cadence(_ kind: BriefSourceKind) -> TimeInterval? {
        let job: AutomationJobID? = switch kind {
        case .monitor: .monitor
        case .siteMessages: .siteMessages
        case .releases: .releases
        case .licences: .licences
        case .worktrack: .worktrack
        case .operations: .operations
        // Read by the WorkTrack and Operations jobs; the slower one (6 hours) sets when a row is old.
        case .money: .worktrack
        // Built from the WorkTrack refresh (and the website messages and SafeBeauty readings it lists, never as items).
        case .sales: .worktrack
        case .oversight: .oversight
        case .keys: .keys
        // Read by their own job, together with the Platforms hub's and the Release Center's readings it uses.
        case .products, .agents: .products
        // Built from what the other jobs read, every time the Brief is: never older than they are. Legal & company's
        // company lines are recorded facts dated by the day they were recorded (like the obligations' seed rows), so a
        // cadence would call them old forever; its marker lines carry the legal folder's own read time.
        case .obligations, .automation, .changes, .legal: nil
        }
        return job.map { AutomationCatalog.spec($0).cadence }
    }

    // MARK: From the ledgers

    static var ledgerCadence: TimeInterval { AutomationCatalog.spec(.ledgers).cadence }

    static func ledgerItems(_ input: DeskLedgerInput, today: KeyDay) -> [DeskItem] {
        switch input {
        case .unsupported:
            return []
        case .notRead:
            return LedgerAllowList.all.map { source in
                sourceItem(source, path: source.displayPath, kindKey: "not-read", severity: .info, owner: false,
                           title: LF("Ledger not read yet: %@", source.displayPath),
                           detail: L("Ledgers are read when the app opens and every 30 minutes."), readAt: nil,
                           destination: .ledgerAccess)
            }
        case .read(let reading):
            return reading.files.flatMap { items(for: $0, readAt: reading.readAt, today: today) }
        case .cloud(let snapshot):
            return DeskCloudLedger.items(snapshot)
        }
    }

    static func origin(_ source: LedgerSource) -> DeskOrigin {
        source.kind == .nextActions ? .nextActions : .ledger(source.id)
    }

    static func items(for file: LedgerFileReading, readAt: Date, today: KeyDay) -> [DeskItem] {
        let source = file.source
        let path = file.displayPath
        switch file.status {
        case .notGranted:
            return [sourceItem(source, path: path, kindKey: "not-granted", severity: .high, owner: true,
                               title: LF("Ledger not granted: %@", path),
                               detail: LF("Grant read access to ~/%@ once in Settings → Integrations → Ledger access.", grantFolder(source)),
                               readAt: readAt, destination: .ledgerAccess)]
        case .notFound:
            return [sourceItem(source, path: path, kindKey: "not-found", severity: .normal, owner: false,
                               title: LF("Ledger not found: %@", path),
                               detail: L("The folder is granted and the file is not there. Not “0 open”: unknown until it is found."),
                               readAt: readAt, destination: .ledgerAccess)]
        case .unreadable(let why):
            return [sourceItem(source, path: path, kindKey: "unreadable", severity: .normal, owner: false,
                               title: LF("Ledger could not be read: %@", path), detail: why, readAt: readAt,
                               destination: .ledgerAccess)]
        case .read(.priorities(let ledger)):
            return prioritiesItems(ledger, source: source, path: path, readAt: readAt, today: today)
        case .read(.nextActions(let report)):
            return nextActionItems(report, source: source, path: path, readAt: readAt, today: today)
        }
    }

    static func grantFolder(_ source: LedgerSource) -> String {
        LedgerAllowList.folders.first { source.path == $0 || source.path.hasPrefix($0 + "/") } ?? source.path
    }

    static func sourceItem(_ source: LedgerSource, path: String, kindKey: String, severity: BriefSeverity, owner: Bool,
                           title: String, detail: String?, readAt: Date?, line: Int? = nil, fact: String = "",
                           destination: DeskDestination) -> DeskItem {
        // The fact is the kind, the file and what is wrong with it (a day, the lines), never a count of days that
        // changes on its own.
        DeskItem(origin: origin(source), subjectKey: "source", kindKey: kindKey, kind: .source, domain: source.domain,
                 severity: severity, title: title, detail: detail, subject: path, ownerAction: owner,
                 evidence: DeskEvidence(source: path, file: path, line: line, readAt: readAt, cadence: ledgerCadence),
                 factHash: DeskHash.of(kindKey, path, fact), destination: destination)
    }

    static func prioritiesItems(_ ledger: ParsedLedger, source: LedgerSource, path: String, readAt: Date, today: KeyDay) -> [DeskItem] {
        var items: [DeskItem] = []
        var seen: [String: Int] = [:]
        for entry in ledger.items {
            // The id follows the line's text, not its number: moving a line keeps its marks, editing it starts afresh.
            let hash = DeskHash.of(entry.text)
            seen[hash, default: 0] += 1
            let key = seen[hash]! > 1 ? "\(hash)#\(seen[hash]!)" : hash
            // The fact is the line and the lines under it: a correction added under a line brings it back.
            let fact = entry.notes.isEmpty ? hash : DeskHash.of([entry.text] + entry.notes)
            items.append(DeskItem(origin: origin(source), subjectKey: key, kindKey: entry.kind.rawValue, kind: .task,
                                  domain: source.domain, severity: entry.priority.severity, title: entry.title,
                                  detail: entry.detail, subject: entry.section ?? source.domain.displayTitle,
                                  ownerAction: false,
                                  evidence: DeskEvidence(source: path, file: path, line: entry.line, readAt: readAt, cadence: ledgerCadence),
                                  factHash: fact, destination: .file(path: path, line: entry.line), notes: entry.notes))
        }
        if let line = ledger.reviewLine, let day = ledger.reviewedOn {
            let age = day.days(until: today)
            if age > reviewStaleDays {
                items.append(sourceItem(source, path: path, kindKey: "review-stale", severity: .normal, owner: false,
                                        title: LF("%@ was last reviewed %d days ago (%@)", path, age, day.description),
                                        detail: L("Ask an agent to review it against the live state before trusting its items."),
                                        readAt: readAt, line: line, fact: day.description, destination: .file(path: path, line: line)))
            }
        } else if let line = ledger.reviewLine {
            // There is a review line, but no Gregorian day in it (a Solar Hijri date is not converted by guess).
            items.append(sourceItem(source, path: path, kindKey: "review-unknown", severity: .info, owner: false,
                                    title: LF("The «آخرین بازبینی» date of %@ could not be read", path),
                                    detail: L("Only a Gregorian YYYY-MM-DD date is read; any other date is not guessed. When it was last reviewed is unknown."),
                                    readAt: readAt, line: line, destination: .file(path: path, line: line)))
        } else {
            items.append(sourceItem(source, path: path, kindKey: "review-unknown", severity: .info, owner: false,
                                    title: LF("%@ has no «آخرین بازبینی» date", path),
                                    detail: L("When it was last reviewed is unknown."), readAt: readAt, line: nil,
                                    destination: .file(path: path, line: nil)))
        }
        if !ledger.skippedLines.isEmpty {
            items.append(skippedItem(source, path: path, lines: ledger.skippedLines, readAt: readAt))
        }
        return items
    }

    static func nextActionItems(_ report: ParsedNextActions, source: LedgerSource, path: String, readAt: Date, today: KeyDay) -> [DeskItem] {
        var items: [DeskItem] = []
        var seen: [String: Int] = [:]
        for entry in report.items {
            let base = "\(DeskDomain.normalized(entry.product))/\(entry.slug.lowercased())"
            seen[base, default: 0] += 1
            let key = seen[base]! > 1 ? "\(base)#\(seen[base]!)" : base
            let domain = DeskDomain.named(entry.product)
            var related: [DeskDomain] = []
            for other in entry.otherProducts.map(DeskDomain.named) where other != domain && !related.contains(other) { related.append(other) }
            items.append(DeskItem(origin: .nextActions, subjectKey: key, kindKey: "owner", kind: .task,
                                  domain: domain, severity: .normal, title: entry.title,
                                  detail: entry.body.isEmpty ? nil : entry.body.joined(separator: "\n"),
                                  subject: "\(entry.product) / \(entry.slug)",
                                  due: entry.section == .today ? report.day : nil,
                                  horizon: entry.section == .today ? .today : .thisWeek, ownerAction: true,
                                  evidence: DeskEvidence(source: path, file: path, line: entry.line, readAt: readAt, cadence: ledgerCadence),
                                  factHash: DeskHash.of(entry.title), destination: .file(path: path, line: entry.line),
                                  related: related, reference: entry.sourceText))
        }
        if let day = report.day {
            let age = day.days(until: today)
            if age > reviewStaleDays {
                items.append(sourceItem(source, path: path, kindKey: "stale", severity: .normal, owner: false,
                                        title: LF("The newest NEXT-ACTIONS is from %@ (%d days ago)", day.description, age),
                                        detail: L("Its TODAY and THIS WEEK items may no longer hold."), readAt: readAt,
                                        fact: day.description, destination: .file(path: path, line: 1)))
            }
        }
        // Owner tasks that could not be read are not "none": this week, not Later.
        if report.sections.isEmpty {
            items.append(sourceItem(source, path: path, kindKey: "no-sections", severity: .normal, owner: false,
                                    title: LF("%@ has no (TODAY) or (THIS WEEK) section", path),
                                    detail: L("No owner tasks could be read from it, which is not the same as none."),
                                    readAt: readAt, destination: .file(path: path, line: 1)))
        }
        if !report.skippedLines.isEmpty {
            items.append(skippedItem(source, path: path, lines: report.skippedLines, readAt: readAt, severity: .normal))
        }
        return items
    }

    static func skippedItem(_ source: LedgerSource, path: String, lines: [Int], readAt: Date,
                            severity: BriefSeverity = .info) -> DeskItem {
        let list = lines.map(String.init).joined(separator: ", ")
        return sourceItem(source, path: path, kindKey: "skipped", severity: severity, owner: false,
                          title: LF("%d lines of %@ could not be understood", lines.count, path),
                          detail: LF("Set aside, not guessed: lines %@.", list), readAt: readAt, line: lines.first,
                          fact: list, destination: .file(path: path, line: lines.first))
    }

    // MARK: Sources

    static func sources(_ input: DeskLedgerInput) -> [DeskSourceStatus] {
        switch input {
        case .unsupported:
            return LedgerAllowList.all.map { DeskSourceStatus(source: $0, displayPath: $0.displayPath, state: .unsupported, readAt: nil) }
        case .notRead:
            return LedgerAllowList.all.map { DeskSourceStatus(source: $0, displayPath: $0.displayPath, state: .notRead, readAt: nil) }
        case .cloud(let snapshot):
            return DeskCloudLedger.sources(snapshot)
        case .read(let reading):
            return reading.files.map { file in
                let state: DeskSourceStatus.State = switch file.status {
                case .notGranted: .notGranted
                case .notFound: .notFound
                case .unreadable(let why): .unreadable(why)
                case .read(.priorities(let p)): .read(open: p.items.count, ticked: p.ticked, skipped: p.skippedLines, reviewedOn: p.reviewedOn)
                case .read(.nextActions(let n)):
                    .report(today: n.items.count { $0.section == .today }, thisWeek: n.items.count { $0.section == .thisWeek },
                            skipped: n.skippedLines, day: n.day)
                }
                return DeskSourceStatus(source: file.source, displayPath: file.displayPath, state: state, readAt: reading.readAt)
            }
        }
    }

    /// Ledgers that were read this time, so a mark on a line that is gone from them can be dropped.
    static func readLedgerOrigins(_ ledgers: DeskLedgerInput) -> Set<String> {
        switch ledgers {
        case .read(let reading): Set(reading.files.filter(\.isRead).map { origin($0.source).key })
        case .cloud(let snapshot): DeskCloudLedger.readOrigins(snapshot)
        case .unsupported, .notRead: []
        }
    }

    /// Whether a Brief mark's item is known to be gone, so the mark can be dropped. Only when its section was read
    /// (not "never read", not "could not be read") and:
    /// - for the section's own item or a part's item ("not read"): the section or part is now read;
    /// - for a line: the section was read after the mark was made, and the line's part of it was read too. For
    ///   Operations that is the line's product (a product not signed in or not read keeps its marks); for the other
    ///   sections, every part. An offline launch or an expired sign-in therefore never deletes a mark.
    static func briefLineIsGone(_ id: String, mark: DeskMark, brief: DailyBrief?) -> Bool {
        let parts = id.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("brief."),
              let section = brief?.sections.first(where: { DeskOrigin.brief($0.kind).key == parts[0] }) else { return false }
        switch section.state {
        case .allClear, .items: break
        case .neverRead, .unavailable: return false
        }
        let subject = String(parts[1])
        // A Money caveat (no TEST mark, a limit reached, not production) or failed part is gone only once the part it is
        // about was read again: a WorkTrack failure or sign-out alone must not drop its dismissal.
        if section.kind == .money, subject.hasPrefix("part."), let keys = MoneyBrief.readGapKeys(forPart: String(subject.dropFirst(5))) {
            return !section.gaps.contains { keys.contains($0.key) }
        }
        if subject == "section" || subject.hasPrefix("part.") { return true }
        guard let readAt = section.readAt, readAt > mark.at else { return false }
        if section.kind == .operations, subject.hasPrefix("ops."),
           let queue = OperationsQueue(rawValue: String(subject.dropFirst(4))) {
            return !section.gaps.contains { $0.key == queue.product.rawValue }
        }
        // Money always has gaps (store proceeds): a line is gone when its own product's part was read.
        if section.kind == .money, let keys = MoneyBrief.readGapKeys(forLineID: subject) {
            return !section.gaps.contains { keys.contains($0.key) }
        }
        // A Sales line is gone when the accounts (and, for a company's line, the companies) were read whole: not while
        // some were set aside or a limit was reached. Not production is no reason to keep a mark.
        if section.kind == .sales, let keys = SalesBrief.readGapKeys(forLineID: subject) {
            return !section.gaps.contains { keys.contains($0.key) }
        }
        // Legal & company always has a part unknown (the DSA status): a marker or Asasnama line is gone once the legal
        // folder was read, a company line once the section was.
        if section.kind == .legal {
            let keys = LegalBrief.readGapKeys(forLineID: subject)
            return !section.gaps.contains { keys.contains($0.key) }
        }
        return section.gaps.isEmpty
    }
}

// MARK: - Copy agent brief

/// The text the owner pastes to an agent: always Dari, with file:line and "read PRIORITIES.md first".
public enum DeskAgentBrief {
    /// Brief sections whose lines name customers (a website message's sender and text, a WorkTrack company, a licence
    /// holder, a CRM account) or carry amounts (Money), with their Dari names. Their brief carries the Brief entry id
    /// instead of the title, and no detail (a Sales id is a hash, never the CRM's own id).
    static let customerSections: [BriefSourceKind: String] = [
        .siteMessages: "پیام‌های وب‌سایت", .worktrack: "مشتریان WorkTrack", .licences: "لایسنس‌ها", .money: "پول", .sales: "فروش",
    ]

    /// Whether the item comes from a section whose lines name customers: its dismiss reason, which is synced as typed,
    /// should not name one either (Sales items take a fixed reason, `SalesDismissReason`).
    public static func namesCustomers(_ item: DeskItem) -> Bool {
        if case .brief(let kind) = item.origin { customerSections[kind] != nil } else { false }
    }

    public static func text(for item: DeskItem, now: Date) -> String {
        let ledger: String = {
            if case .ledger(let id) = item.origin, let s = LedgerAllowList.priorities.first(where: { $0.id == id }) { return s.displayPath }
            return (LedgerAllowList.priorities(for: item.domain) ?? LedgerAllowList.priorities[0]).displayPath
        }()
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("کار از «میز کار» Linumic OS (\(iso.string(from: now)))")
        lines.append("اول PRIORITIES.md را بخوان: \(ledger)")
        lines.append("محصول: \(item.domain == .shared ? "همهٔ محصولات" : item.domain.name)")
        if !item.related.isEmpty { lines.append("محصولات دیگر در منبع: " + item.related.map(\.name).joined(separator: "، ")) }
        if case .brief(let kind) = item.origin, item.kind == .fact, let section = customerSections[kind] {
            // No customer's name, address or message leaves the app through the clipboard.
            lines.append("کار: یک مورد «\(section)» در گزارش روز Linumic OS (شناسه: \(item.subjectKey)). نام و متن مشتری عمداً این‌جا نیامده؛ در خود برنامه ببین.")
        } else {
            lines.append("کار: \(item.title)")
            if let detail = item.detail, !detail.isEmpty { lines.append("جزئیات: \(detail)") }
        }
        // Corrections (dated, or saying «اصلاح» / «درست نیست») are named as such only when there are some; the other
        // lines under the item follow under a neutral heading.
        let corrections = item.corrections
        if !corrections.isEmpty {
            lines.append("اصلاح‌های تاریخ‌دار زیر همین مورد در دفتر (سطر بالا ممکن است دیگر درست نباشد):")
            lines += corrections.map { "  \($0)" }
        }
        let others = item.notes.filter { !LedgerText.isCorrection($0) }
        if !others.isEmpty {
            lines.append(corrections.isEmpty ? "سطرهای زیر همین مورد در دفتر، به همان ترتیب:" : "سطرهای دیگر زیر همین مورد در دفتر، به همان ترتیب:")
            lines += others.map { "  \($0)" }
        }
        if item.evidence.file != nil {
            lines.append("منبع: \(item.evidence.location)")
        } else {
            lines.append("منبع: \(item.evidence.source)")
        }
        if item.origin == .nextActions { lines.append("موضوع: \(item.subject)") }
        if let reference = item.reference { lines.append("منبع در گزارش: \(reference)") }
        // A source that says it was not read was only checked at that time, not read.
        lines.append((item.wasRead ? "زمان خواندن: " : "زمان بررسی (خوانده نشد): ") + (item.evidence.readAt.map { iso.string(from: $0) } ?? "نامعلوم"))
        lines.append("قاعده: چیزی را که ثابت نشده «انجام شد» ننویس. وقتی تمام شد، همان سطر را در دفتر با تاریخ و مدرک تیک بزن.")
        return lines.joined(separator: "\n")
    }
}
