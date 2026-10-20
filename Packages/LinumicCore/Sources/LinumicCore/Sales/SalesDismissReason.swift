import Foundation

/// Why a Sales item on the Desk is dismissed: a fixed choice, never typed text. A dismiss reason is synced to Supabase as
/// it is and kept in its audit history (docs/desk-sync.md), and a typed one could name the customer; these name no one.
public enum SalesDismissReason: String, CaseIterable, Sendable, Identifiable {
    case called = "sales.reason.called"
    case console = "sales.reason.console"
    case notToCall = "sales.reason.notToCall"
    case testRecord = "sales.reason.test"
    case other = "sales.reason.other"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .called: L("Called; the date is moved in the WorkTrack console")
        case .console: L("Handled in the WorkTrack console")
        case .notToCall: L("Not someone to call")
        case .testRecord: L("A test or duplicate record")
        case .other: L("Another reason (not written down, so nothing about the customer is synced)")
        }
    }

    /// Every item of the Sales section: its lines name customers, and its other items sit beside them.
    public static func applies(toItemID id: String) -> Bool {
        id.hasPrefix(DeskOrigin.brief(.sales).key + "|")
    }

    /// A reason as shown: a preset's title, or the owner's own text for any other item.
    public static func displayText(_ reason: String) -> String {
        Self(rawValue: reason)?.title ?? reason
    }

    /// The mark as it may leave this device: a Sales item's dismissal always carries a preset, so a reason that is not one
    /// (only an edited desk-state.json could hold it) is sent as "another reason", never as written.
    public static func cloudSafe(_ mark: DeskMark, itemID: String) -> DeskMark {
        guard applies(toItemID: itemID), let reason = mark.reason, Self(rawValue: reason) == nil else { return mark }
        var safe = mark
        safe.reason = Self.other.rawValue
        return safe
    }
}
