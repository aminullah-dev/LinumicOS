import Foundation

// MARK: - Obligations in the Daily Brief (and so on the Desk)

/// The obligations register as the App holds it.
public struct BriefObligationsInput: Sendable {
    public var register: ObligationsRegister
    /// `obligations.json` exists but could not be read: the owner's dates and Done marks are then unknown, not absent.
    public var loadError: String?

    public init(register: ObligationsRegister, loadError: String? = nil) {
        self.register = register
        self.loadError = loadError
    }
}

/// Which open obligations become Brief lines, and how each is worded. Every open obligation is a line (a far one is
/// for information, so the Desk keeps it under Later), except where another section of the Brief already says the
/// same thing: a domain or licence inside that section's 30-day window, and the Keys & Backups reminders. TLS
/// certificates renew on their own (each host's provider does it); the Monitor's section brings one forward from 30
/// days before it ends, so they stay on the Obligations screen and out of the Desk.
public enum ObligationsBriefRules {
    public static func showsInBrief(_ o: Obligation, today: KeyDay) -> Bool {
        guard o.completion == nil else { return false }
        switch o.origin {
        case .certificate:
            return false
        case .domain, .licence:
            // The Monitor and Licences sections list these from 30 days before the end (and after it).
            guard let due = o.due else { return true }
            return today.days(until: due) > DailyBriefBuilder.expiryWindowDays
        case .keys:
            // Keys & Backups already says "no restore test", "restore test due" and "no second copy"; only a future
            // restore-test day is new here.
            guard let due = o.due else { return false }
            return today < due
        case .seed, .owner, .account, .continuity:
            return true
        }
    }

    /// High when overdue or due within a day, normal in the 7- and 14-day windows, information otherwise; an encrypted
    /// copy off this Mac that was never made is normal (the roadmap's Phase 2 is not done without one).
    public static func severity(_ o: Obligation, today: KeyDay) -> BriefSeverity {
        if o.origin == .continuity, o.due == nil { return .normal }
        return ObligationRules.severity(o, today: today)
    }

    /// The title with where it stands: "… (in 12 days)", "… (due today)", "… (overdue by 3 days)", "… (date unknown)".
    public static func text(_ o: Obligation, today: KeyDay) -> String {
        switch ObligationRules.timing(o, today: today) {
        case .closed: return LF("%@ (done)", o.displayTitle)
        case .dateUnknown: return LF("%@ (date unknown)", o.displayTitle)
        case .overdue(let days): return LF("%1$@ (overdue by %2$d days)", o.displayTitle, days)
        case .due(0, _): return LF("%@ (due today)", o.displayTitle)
        case .due(let days, _): return LF("%1$@ (in %2$d days)", o.displayTitle, days)
        }
    }

    /// When the fact behind a line was read: a live row's reading, else the day it was recorded in its source. A row
    /// built from a file the app keeps itself (the continuity log, the Keys & Backups registry) is read again each time
    /// the register is built, so its time is the build's: a Desk mark made before it then comes back at the next Brief
    /// while the row is still there, instead of hiding it until the due day changes.
    static func readAt(_ o: Obligation, builtAt: Date, calendar: Calendar) -> Date? {
        switch o.origin {
        case .continuity, .keys: builtAt
        default: o.readAt ?? o.recordedOn?.start(calendar: calendar)
        }
    }
}

extension DailyBriefBuilder {
    static func obligations(_ input: BriefInput) -> BriefSection {
        let source = L("Obligations register on this device (obligations.json, the seed and the live dates)")
        guard let o = input.obligations else {
            return BriefSection(kind: .obligations, state: .neverRead(L("The obligations register has not been built yet.")),
                                readAt: nil, source: source)
        }
        let calendar = KeyDay.calendar
        let today = KeyDay(input.now, calendar: calendar)
        var lines: [BriefLine] = []
        // What validate() refuses is said first and never hidden.
        for issue in o.register.issues {
            lines.append(BriefLine(id: "obligation.issue.\(issue.id)", kind: .obligations, severity: .high, text: issue.text,
                                   detail: L("A row without a source, or a Done without evidence, is refused: it is not counted as known or done."),
                                   source: source, readAt: o.register.builtAt, destination: .obligations, product: "Linumic OS"))
        }
        for row in o.register.obligations where ObligationsBriefRules.showsInBrief(row, today: today) {
            var detail = row.displayConsequence
            if let dueSource = row.dueSource { detail = [detail, LF("Date from: %@", dueSource)].compactMap { $0 }.joined(separator: "\n") }
            lines.append(BriefLine(id: "obligation.\(row.id)", kind: .obligations,
                                   severity: ObligationsBriefRules.severity(row, today: today),
                                   text: ObligationsBriefRules.text(row, today: today), detail: detail,
                                   source: row.source, readAt: ObligationsBriefRules.readAt(row, builtAt: o.register.builtAt, calendar: calendar),
                                   destination: row.destination, product: row.product, due: row.due, obligationID: row.id))
        }
        var gaps: [BriefGap] = []
        if let error = o.loadError {
            gaps.append(BriefGap(key: "file", text: LF("obligations.json could not be read (%@), so your own dates and Done marks are unknown here.", error)))
        }
        for part in o.register.unread {
            gaps.append(BriefGap(key: part.rawValue, text: part.notReadText))
        }
        return finish(.obligations, lines: lines, readAt: o.register.builtAt, source: source, gaps: gaps)
    }
}
