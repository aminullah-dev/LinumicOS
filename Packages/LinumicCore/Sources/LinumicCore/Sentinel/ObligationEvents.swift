import Foundation

/// Where an obligation event from the server's sweep (`obligationDue`) stands on this device: the sweep wrote it from
/// what was synced at 06:16 UTC, and this device may know more since (a Done, a new date) or may read it days later.
public enum ObligationEventStanding: Hashable, Sendable {
    /// Open here, and due on the event's day: the reminder applies.
    case applies
    /// Done here for the event's day: nothing to remind about.
    case closed
    /// Due on another day here (or no longer dated): the event's day is not the obligation's any more.
    case moved(KeyDay?)
    /// Not in this device's register (a row this version does not know, or one that is gone).
    case unknown
}

public enum ObligationEvents {
    /// The event read against this device's register.
    public static func standing(_ event: SentinelEvent, in register: ObligationsRegister) -> ObligationEventStanding {
        let id = event.detail?.obligationID ?? event.subject
        guard event.kind == .obligationDue, let o = register.obligation(id) else { return .unknown }
        let due = event.detail?.due.flatMap(KeyDay.init)
        guard o.due == due else { return .moved(o.due) }
        return o.completion == nil ? .applies : .closed
    }

    /// "<title> (in 4 days)", worded as the app words its own obligation alerts (the owner's title as written, the
    /// seed's in the app's language, an account's renewal as "<name>: renewal"), and counted from the event's due day
    /// to `today`, never from the days left when the server wrote it. One re-dated on this device (`standing` is
    /// `.moved`) says so instead of counting toward a day the obligation no longer has.
    public static func line(_ event: SentinelEvent, today: KeyDay, standing: ObligationEventStanding = .applies) -> String {
        let id = event.detail?.obligationID ?? event.subject
        let raw = event.detail?.title ?? event.subject
        let name = event.detail?.renewal == true ? LF("%@: renewal", raw) : (id.hasPrefix("owner.") ? raw : L(raw))
        if case .moved = standing { return LF("%@ (date changed)", name) }
        guard let due = event.detail?.due.flatMap(KeyDay.init) else { return name }
        let days = today.days(until: due)
        if days < 0 { return LF("%1$@ (overdue by %2$d days)", name, -days) }
        if days == 0 { return LF("%@ (due today)", name) }
        return LF("%1$@ (in %2$d days)", name, days)
    }
}
