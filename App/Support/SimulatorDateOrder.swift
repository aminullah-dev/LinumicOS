#if targetEnvironment(simulator)
import Foundation

/// The iOS Simulator only; a device or a Mac never compiles this.
///
/// The iOS 27.2 SDK back-deploys `Date.>=` and `Date.<=`: on a system that says it is 27.2 the app calls Foundation's
/// own copy. The 27.2 simulator runtime on the owner's Mac (24B5089g) says so and has no such symbol, so the first
/// `a >= b` on two dates jumped to address zero and the app closed on its first page (found 2026-11-12, three crash
/// reports, `AgentActivity.report`). Declared here, the comparison is this module's own and reads the same.
extension Date {
    static func >= (lhs: Date, rhs: Date) -> Bool { !(lhs < rhs) }
    static func <= (lhs: Date, rhs: Date) -> Bool { !(rhs < lhs) }
}
#endif
