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

    // A test host whose own calendar is Gregorian can't tell a default of `Calendar.current` from `KeyDay.calendar`.
    // tools/test/persian-calendar.sh (and CI) runs this suite with the Persian calendar as the device's, where these
    // fail if a default slips back to the device's calendar.
    @Test func theDefaultsAreGregorianWhereverADayIsMade() {
        // 2026-10-19 is 1405-07-27 in the Persian calendar: every component differs.
        let date = Date(timeIntervalSince1970: 1_792_411_200)
        var persian = Calendar(identifier: .persian)
        persian.timeZone = .current
        #expect(KeyDay(date, calendar: persian) != KeyDay(date, calendar: KeyDay.calendar))
        #expect(KeyDay(date) == KeyDay(date, calendar: KeyDay.calendar))
        #expect(KeyDay(date) != KeyDay(date, calendar: persian))
        #expect(KeyDay.calendar.identifier == .gregorian)
        // Keys & Backups checks and the Desk take the same default.
        #expect(KeysCheckInput(registry: KeysRegistry.seed, now: date).calendar.identifier == .gregorian)
        #expect(InventoryBackup.gregorian.identifier == .gregorian)
        // A normal item due on today's Gregorian day is Today's on a Desk built with the default calendar.
        let line = BriefLine(id: "x", kind: .obligations, severity: .normal, text: "x", source: "s", readAt: date,
                             destination: .obligations, due: KeyDay(date, calendar: KeyDay.calendar))
        let brief = DailyBrief(sections: [BriefSection(kind: .obligations, state: .items, lines: [line], readAt: date, source: "s")],
                               generatedAt: date)
        let desk = DeskBuilder.build(brief: brief, ledgers: .unsupported, state: DeskState(), now: date)
        #expect(desk.today.map(\.item.subjectKey) == ["x"])
    }
}
