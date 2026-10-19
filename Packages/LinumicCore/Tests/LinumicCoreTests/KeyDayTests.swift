import Foundation
import Testing
@testable import LinumicCore

@Suite("KeyDay is a Gregorian day")
struct KeyDayTests {
    // The app runs with the fa_AF locale on the owner's Mac, so Calendar.current there is the Persian one. A KeyDay
    // built or read with it turned 2026-10-19 into 1405-07-27, and "2026-10-31" into a day six centuries away.
    @Test func whateverCalendarTheDeviceShows() {
        let date = Date(timeIntervalSince1970: 1_792_411_200) // 2026-10-19T12:00:00Z
        var persian = Calendar(identifier: .persian)
        persian.timeZone = TimeZone(identifier: "UTC")!
        #expect(KeyDay(date, calendar: persian).year == 1405)   // the hazard
        #expect(KeyDay.calendar.identifier == .gregorian)
        #expect(KeyDay.calendar.timeZone == .current)
        #expect(KeyDay(date).year == 2026)
        let due = KeyDay("2026-10-31")!
        #expect(Calendar(identifier: .gregorian).component(.year, from: due.start()) == 2026)
        #expect(KeyDay(due.start()) == due)
    }
}
