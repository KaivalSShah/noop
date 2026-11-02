import Foundation
import Combine

// MARK: - Push-up tracker — local-only daily tap counter
//
// The user taps once per push-up; each tap adds 1 to TODAY's total. Only the per-day totals are kept,
// as one JSON dictionary `[yyyy-MM-dd: count]` under a single UserDefaults key — the same small-user-data
// posture `CaffeineLogStore` uses (one process-wide `ObservableObject`, JSON in UserDefaults, on-device
// only, never synced). "Today" is the app-wide LOGICAL day (`Repository.logicalDayRolloverHour`, 04:00
// local), not the calendar day: a set done at 00:30 belongs to the evening before, the day the user is
// still living in. Keys are the calendar date of that logical day in the local time zone. Past days can
// be edited explicitly (the history graph's selected square); future days never can.
//
// Everything below the store is pure (calendar + dictionary in, values out) so the bucketing, the summary
// figures and the contribution-graph layout are unit-testable without UI or persistence.

/// Calendar-day keys for the push-up log.
enum PushupDay {
    /// The calendar the tracker buckets by: Gregorian (so keys are always `yyyy-MM-dd` in the familiar
    /// era, whatever calendar the device displays), in `timeZone`, starting weeks on `firstWeekday`.
    static func calendar(timeZone: TimeZone = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent,
                         firstWeekday: Int = Calendar.current.firstWeekday) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = locale
        cal.firstWeekday = firstWeekday
        return cal
    }

    /// `yyyy-MM-dd` for the calendar day `date` falls on in `calendar`'s time zone.
    static func key(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Noon on the day a `yyyy-MM-dd` key names, or nil for a malformed / impossible key. Noon rather
    /// than midnight so a zone whose DST jump lands at midnight still resolves the day.
    static func date(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
        else { return nil }
        // Reject keys the calendar silently normalised (2026-02-30 → 2026-03-02).
        return Self.key(for: date, calendar: calendar) == key ? date : nil
    }

    /// Noon on the calendar day of `date` — a DST-safe anchor for day arithmetic.
    static func noon(of date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    /// The hour the push-up day rolls over: the same 04:00 boundary Today uses.
    static let rolloverHour = Repository.logicalDayRolloverHour

    /// Noon on the logical day `now` belongs to — the calendar day of `now - rolloverHour` hours, so the
    /// small hours after midnight still count toward the previous evening.
    static func today(at now: Date, calendar: Calendar, rolloverHour: Int = rolloverHour) -> Date {
        noon(of: now.addingTimeInterval(-Double(rolloverHour) * 3_600), calendar: calendar)
    }
}

/// The headline figures shown above the history graph.
struct PushupSummary: Equatable {
    var today: Int
    var thisWeek: Int
    var total: Int
    /// Consecutive days with at least one push-up, ending today — or ending yesterday when today has
    /// none yet, so a streak doesn't read as broken before the day is over.
    var currentStreak: Int

    static func compute(counts: [String: Int], now: Date, calendar: Calendar) -> PushupSummary {
        let today = PushupDay.today(at: now, calendar: calendar)
        func count(_ date: Date) -> Int { max(0, counts[PushupDay.key(for: date, calendar: calendar)] ?? 0) }
        func day(_ offset: Int) -> Date? { calendar.date(byAdding: .day, value: offset, to: today) }

        // This week: from the calendar's first weekday through today.
        let weekdayIndex = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        var week = 0
        for offset in stride(from: -weekdayIndex, through: 0, by: 1) {
            if let d = day(offset) { week += count(d) }
        }

        // Streak: walk back from today (or yesterday, if today is still empty). Bounded by the number of
        // logged days, since a streak can't be longer than that.
        var streak = 0
        var offset = count(today) > 0 ? 0 : -1
        let limit = counts.count + 1
        while streak < limit, let d = day(offset), count(d) > 0 {
            streak += 1
            offset -= 1
        }

        return PushupSummary(today: count(today),
                             thisWeek: week,
                             total: counts.values.reduce(0) { $0 + max(0, $1) },
                             currentStreak: streak)
    }
}

/// Colour-intensity bucketing for the contribution graph: 0 is the empty square, 1–4 are increasing
/// shades. Relative to the busiest day on screen (GitHub's approach), so the scale adapts as the
/// user gets stronger instead of saturating at a fixed threshold.
enum PushupIntensity {
    static let maxLevel = 4

    static func level(count: Int, maxCount: Int) -> Int {
        guard count > 0 else { return 0 }
        guard maxCount > 0 else { return 1 }
        let ratio = Double(min(count, maxCount)) / Double(maxCount)
        return min(maxLevel, max(1, Int((ratio * Double(maxLevel)).rounded(.up))))
    }
}

/// The contribution-graph layout: `weeks` columns ending with the week that contains today, 7 rows per
/// column starting at `calendar.firstWeekday`. Days after today are nil (blank squares).
struct PushupGrid: Equatable {
    struct Cell: Equatable, Hashable {
        let key: String
        /// Noon on the cell's day.
        let date: Date
    }

    struct MonthLabel: Equatable {
        /// The column the label sits over.
        let column: Int
        /// 1...12
        let month: Int
    }

    /// Oldest week first; each inner array always has 7 entries.
    let weeks: [[Cell?]]
    let monthLabels: [MonthLabel]
    let todayKey: String

    static func build(weeks weekCount: Int, endingAt now: Date, calendar: Calendar) -> PushupGrid {
        let today = PushupDay.today(at: now, calendar: calendar)
        let todayKey = PushupDay.key(for: today, calendar: calendar)
        let columns = max(1, weekCount)
        let weekdayIndex = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let firstDayOffset = -weekdayIndex - (columns - 1) * 7

        var weeks: [[Cell?]] = []
        weeks.reserveCapacity(columns)
        for col in 0..<columns {
            var column: [Cell?] = []
            column.reserveCapacity(7)
            for row in 0..<7 {
                let offset = firstDayOffset + col * 7 + row
                if offset > 0 {
                    column.append(nil)   // after today
                } else if let d = calendar.date(byAdding: .day, value: offset, to: today) {
                    column.append(Cell(key: PushupDay.key(for: d, calendar: calendar), date: d))
                } else {
                    column.append(nil)
                }
            }
            weeks.append(column)
        }

        // A month label over each column whose first day starts a new month (and the first column).
        var labels: [MonthLabel] = []
        var previousMonth: Int?
        for (col, week) in weeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first.date)
            if month != previousMonth { labels.append(MonthLabel(column: col, month: month)) }
            previousMonth = month
        }
        // The leading partial month has no room for its name when the next label follows too closely.
        if labels.count >= 2, labels[1].column - labels[0].column < 3 {
            labels.removeFirst()
        }

        return PushupGrid(weeks: weeks, monthLabels: labels, todayKey: todayKey)
    }

    /// The weekday (1 = Sunday … 7 = Saturday) that `row` shows in `calendar`.
    static func weekday(forRow row: Int, calendar: Calendar) -> Int {
        ((calendar.firstWeekday - 1 + row) % 7 + 7) % 7 + 1
    }

    /// The largest count among the visible days, for intensity bucketing.
    func maxCount(in counts: [String: Int]) -> Int {
        var best = 0
        for week in weeks {
            for cell in week {
                if let cell, let c = counts[cell.key], c > best { best = c }
            }
        }
        return best
    }
}

// MARK: - Store

/// The process-wide push-up log. Holds per-day totals and persists them as JSON under one UserDefaults
/// key on every change, so counts survive relaunches and accumulate into history.
final class PushupLogStore: ObservableObject {

    static let shared = PushupLogStore()

    /// UserDefaults key for the `[yyyy-MM-dd: count]` JSON dictionary.
    static let storageKey = "noop.pushups.dailyCounts"

    /// Per-day totals keyed by `PushupDay.key`. Days with zero push-ups are absent.
    @Published private(set) var counts: [String: Int] { didSet { save() } }

    /// The calendar days are bucketed by (local time zone, Gregorian).
    let calendar: Calendar

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         calendar: Calendar = PushupDay.calendar(),
         now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        let decoded = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        self.counts = decoded.filter { $0.value > 0 }
    }

    /// The key of the logical day the user is in right now.
    var todayKey: String {
        PushupDay.key(for: PushupDay.today(at: now(), calendar: calendar), calendar: calendar)
    }

    /// The key a mutation applies to: the calendar day of `date` when given (a past day being edited),
    /// otherwise today's logical day. Nil for a day after today, which can't be logged.
    private func editableKey(_ date: Date?) -> String? {
        let key = date.map { PushupDay.key(for: $0, calendar: calendar) } ?? todayKey
        return key <= todayKey ? key : nil
    }

    /// The total for the calendar day of `date`, or today's logical day when nil.
    func count(on date: Date? = nil) -> Int {
        let key = date.map { PushupDay.key(for: $0, calendar: calendar) } ?? todayKey
        return counts[key] ?? 0
    }

    /// Add one push-up to the calendar day of `date`, or today's logical day when nil. Days after today
    /// are refused. Returns that day's new total.
    @discardableResult
    func increment(on date: Date? = nil) -> Int {
        guard let key = editableKey(date) else { return 0 }
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        return next
    }

    /// Remove one push-up from the calendar day of `date`, or today's logical day when nil — the undo for
    /// a mistaken tap. Never goes below zero; a day that reaches zero is dropped from the log. Returns the
    /// new total.
    @discardableResult
    func decrement(on date: Date? = nil) -> Int {
        guard let key = editableKey(date) else { return 0 }
        let current = counts[key] ?? 0
        guard current > 0 else { return 0 }
        let next = current - 1
        counts[key] = next > 0 ? next : nil
        return next
    }

    /// Headline figures as of `date` (defaults to now).
    func summary(at date: Date? = nil) -> PushupSummary {
        PushupSummary.compute(counts: counts, now: date ?? now(), calendar: calendar)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
