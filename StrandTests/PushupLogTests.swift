import XCTest
@testable import Strand

/// Pins the push-up tracker's pure half: calendar-day bucketing in the local time zone, the persisted
/// per-day totals (increment / undo / reload), the summary figures, the contribution-graph layout and
/// the intensity buckets. Headless — no UI — with a fixed time zone and an isolated UserDefaults suite.
final class PushupLogTests: XCTestCase {

    private let suiteName = "PushupLogTests"
    private var defaults: UserDefaults!
    private let calendar = PushupDay.calendar(timeZone: TimeZone(identifier: "America/New_York")!,
                                              locale: Locale(identifier: "en_US_POSIX"),
                                              firstWeekday: 1)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// Sunday 2026-11-01, 23:30 in New York (the day US DST ends).
    private var sundayNight: Date { date("2026-11-01T23:30:00-05:00") }

    private func day(_ offset: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base)!
    }

    // MARK: - Day keys

    func testKeyUsesLocalCalendarDayNotUTC() {
        // 04:30 UTC on the 2nd is still the evening of the 1st in New York.
        XCTAssertEqual(PushupDay.key(for: date("2026-11-02T04:30:00Z"), calendar: calendar), "2026-11-01")
        XCTAssertEqual(PushupDay.key(for: date("2026-11-02T05:30:00Z"), calendar: calendar), "2026-11-02")
    }

    func testDateForKeyRoundTripsAndRejectsImpossibleDays() {
        let d = PushupDay.date(forKey: "2026-03-08", calendar: calendar)   // US DST starts
        XCTAssertNotNil(d)
        XCTAssertEqual(PushupDay.key(for: d!, calendar: calendar), "2026-03-08")
        XCTAssertNil(PushupDay.date(forKey: "2026-02-30", calendar: calendar))
        XCTAssertNil(PushupDay.date(forKey: "not-a-day", calendar: calendar))
    }

    // MARK: - Logical day (04:00 rollover)

    func testSmallHoursCountTowardThePreviousEvening() {
        // The reported bug: a set done just after midnight showed up as "today" the next afternoon.
        var clock = date("2026-11-02T00:30:00-05:00")   // Monday 00:30, still Sunday night's session
        let store = PushupLogStore(defaults: defaults, calendar: calendar, now: { clock })
        for _ in 0..<10 { store.increment() }
        XCTAssertEqual(store.counts, ["2026-11-01": 10])

        clock = date("2026-11-02T16:30:00-05:00")       // Monday afternoon
        XCTAssertEqual(store.todayKey, "2026-11-02")
        XCTAssertEqual(store.count(), 0, "yesterday's set must not read as today")
        XCTAssertEqual(store.summary(), PushupSummary(today: 0, thisWeek: 10, total: 10, currentStreak: 1))
        store.increment()
        XCTAssertEqual(store.counts, ["2026-11-01": 10, "2026-11-02": 1])
    }

    func testRolloverHappensAtFourAM() {
        XCTAssertEqual(PushupDay.key(for: PushupDay.today(at: date("2026-11-02T03:59:00-05:00"), calendar: calendar),
                                     calendar: calendar), "2026-11-01")
        XCTAssertEqual(PushupDay.key(for: PushupDay.today(at: date("2026-11-02T04:01:00-05:00"), calendar: calendar),
                                     calendar: calendar), "2026-11-02")
        let grid = PushupGrid.build(weeks: 4, endingAt: date("2026-11-02T02:00:00-05:00"), calendar: calendar)
        XCTAssertEqual(grid.todayKey, "2026-11-01")
    }

    func testPastDaysCanBeCorrectedButFutureDaysCannot() {
        let monday = date("2026-11-02T16:30:00-05:00")
        let store = PushupLogStore(defaults: defaults, calendar: calendar, now: { monday })
        for _ in 0..<3 { store.increment() }
        // Move the three taps back to Sunday, where they belonged.
        let sunday = PushupDay.date(forKey: "2026-11-01", calendar: calendar)!
        for _ in 0..<3 { store.decrement(); store.increment(on: sunday) }
        XCTAssertEqual(store.counts, ["2026-11-01": 3])
        XCTAssertEqual(store.count(on: sunday), 3)

        let tomorrow = PushupDay.date(forKey: "2026-11-03", calendar: calendar)!
        XCTAssertEqual(store.increment(on: tomorrow), 0)
        XCTAssertEqual(store.counts, ["2026-11-01": 3], "a day after today can't be logged")
    }

    // MARK: - Store

    func testIncrementAndUndoNeverGoBelowZero() {
        let store = PushupLogStore(defaults: defaults, calendar: calendar, now: { self.sundayNight })
        XCTAssertEqual(store.increment(), 1)
        XCTAssertEqual(store.increment(), 2)
        XCTAssertEqual(store.decrement(), 1)
        XCTAssertEqual(store.decrement(), 0)
        XCTAssertEqual(store.decrement(), 0)
        XCTAssertTrue(store.counts.isEmpty, "a day undone to zero is dropped from the log")
    }

    func testCountsPersistAcrossRelaunch() {
        let store = PushupLogStore(defaults: defaults, calendar: calendar, now: { self.sundayNight })
        for _ in 0..<3 { store.increment() }
        store.increment(on: day(-1, from: sundayNight))

        let relaunched = PushupLogStore(defaults: defaults, calendar: calendar, now: { self.sundayNight })
        XCTAssertEqual(relaunched.counts, ["2026-11-01": 3, "2026-10-31": 1])
        XCTAssertEqual(relaunched.count(), 3)
    }

    func testCorruptStorageLoadsEmpty() {
        defaults.set(Data("nope".utf8), forKey: PushupLogStore.storageKey)
        let store = PushupLogStore(defaults: defaults, calendar: calendar, now: { self.sundayNight })
        XCTAssertTrue(store.counts.isEmpty)
    }

    // MARK: - Summary

    func testSummaryTotalsWeekAndStreak() {
        let counts = [
            "2026-11-01": 5,    // Sun (today; first day of the Sunday-start week)
            "2026-10-31": 10,   // Sat
            "2026-10-30": 20,   // Fri
            "2026-10-28": 40,   // Wed — gap on Thu breaks the streak
        ]
        let s = PushupSummary.compute(counts: counts, now: sundayNight, calendar: calendar)
        XCTAssertEqual(s, PushupSummary(today: 5, thisWeek: 5, total: 75, currentStreak: 3))
    }

    func testStreakSurvivesAnEmptyTodayUntilTheDayEnds() {
        let counts = ["2026-10-31": 10, "2026-10-30": 20]
        let s = PushupSummary.compute(counts: counts, now: sundayNight, calendar: calendar)
        XCTAssertEqual(s.today, 0)
        XCTAssertEqual(s.currentStreak, 2)
    }

    func testThisWeekSpansFromFirstWeekdayToToday() {
        let wednesday = date("2026-11-04T12:00:00-05:00")
        let counts = ["2026-10-31": 100, "2026-11-01": 1, "2026-11-02": 2, "2026-11-04": 4]
        let s = PushupSummary.compute(counts: counts, now: wednesday, calendar: calendar)
        XCTAssertEqual(s.thisWeek, 7, "Saturday belongs to the previous week")
    }

    // MARK: - Grid

    func testGridEndsOnTodayWithFutureDaysBlank() {
        let wednesday = date("2026-11-04T12:00:00-05:00")
        let grid = PushupGrid.build(weeks: 26, endingAt: wednesday, calendar: calendar)
        XCTAssertEqual(grid.weeks.count, 26)
        XCTAssertTrue(grid.weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(grid.todayKey, "2026-11-04")
        XCTAssertEqual(grid.weeks.last!.map { $0?.key },
                       ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", nil, nil, nil])
        // Every earlier column is a full Sunday-to-Saturday week.
        XCTAssertEqual(grid.weeks.first!.first!!.key, "2026-05-10")
        XCTAssertEqual(grid.weeks.first!.last!!.key, "2026-05-16")
    }

    func testGridMonthLabelsMarkNewMonths() {
        let grid = PushupGrid.build(weeks: 26, endingAt: sundayNight, calendar: calendar)
        XCTAssertEqual(grid.monthLabels.map(\.month), [5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(grid.monthLabels.last, PushupGrid.MonthLabel(column: 25, month: 11))
    }

    func testWeekdayRowsFollowFirstWeekday() {
        XCTAssertEqual((0..<7).map { PushupGrid.weekday(forRow: $0, calendar: calendar) }, [1, 2, 3, 4, 5, 6, 7])
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        XCTAssertEqual((0..<7).map { PushupGrid.weekday(forRow: $0, calendar: mondayFirst) }, [2, 3, 4, 5, 6, 7, 1])
    }

    func testGridMaxCountOnlyLooksAtVisibleDays() {
        let grid = PushupGrid.build(weeks: 4, endingAt: sundayNight, calendar: calendar)
        XCTAssertEqual(grid.maxCount(in: ["2026-11-01": 7, "2020-01-01": 500]), 7)
    }

    // MARK: - Intensity

    func testIntensityBuckets() {
        XCTAssertEqual(PushupIntensity.level(count: 0, maxCount: 100), 0)
        XCTAssertEqual(PushupIntensity.level(count: 1, maxCount: 100), 1)
        XCTAssertEqual(PushupIntensity.level(count: 25, maxCount: 100), 1)
        XCTAssertEqual(PushupIntensity.level(count: 26, maxCount: 100), 2)
        XCTAssertEqual(PushupIntensity.level(count: 75, maxCount: 100), 3)
        XCTAssertEqual(PushupIntensity.level(count: 100, maxCount: 100), 4)
        XCTAssertEqual(PushupIntensity.level(count: 3, maxCount: 0), 1)
    }
}
