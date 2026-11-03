import Foundation

/// How a to-do repeats.
///
/// Like Things, a repeating to-do either follows a fixed schedule ("every
/// Monday") or comes back a set time after you complete it ("3 days after
/// completion"). Completing an instance creates the next one.
public struct RepeatRule: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, Sendable, CaseIterable {
        case day, week, month, year
    }

    public enum Mode: String, Codable, Sendable {
        /// Next instance is scheduled relative to the previous instance's date.
        case schedule
        /// Next instance is scheduled relative to when this one was completed.
        case afterCompletion
    }

    public var unit: Unit
    public var interval: Int
    public var mode: Mode
    /// For weekly schedules: weekdays (1 = Sunday … 7 = Saturday). Empty means "same weekday".
    public var weekdays: [Int]
    /// Stop generating instances after this day.
    public var until: Day?

    public init(unit: Unit, interval: Int = 1, mode: Mode = .schedule, weekdays: [Int] = [], until: Day? = nil) {
        self.unit = unit
        self.interval = max(1, interval)
        self.mode = mode
        self.weekdays = weekdays.sorted()
        self.until = until
    }

    public static let daily = RepeatRule(unit: .day)
    public static let weekly = RepeatRule(unit: .week)
    public static let monthly = RepeatRule(unit: .month)
    public static let yearly = RepeatRule(unit: .year)

    var encoded: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    init?(encoded: String) {
        guard let data = encoded.data(using: .utf8), let rule = try? JSONDecoder().decode(RepeatRule.self, from: data) else { return nil }
        self = rule
    }

    /// The day of the instance after one scheduled on `previous` and completed on `completed`.
    /// Returns nil once the rule's end date is passed.
    public func next(after previous: Day?, completedOn completed: Day, calendar: Calendar = .current) -> Day? {
        let base: Day
        switch mode {
        case .afterCompletion: base = completed
        case .schedule: base = previous ?? completed
        }

        var candidate: Day
        if unit == .week, !weekdays.isEmpty {
            candidate = nextWeekday(after: base, calendar: calendar)
        } else {
            candidate = advance(base, calendar: calendar)
        }

        // A fixed schedule never produces an instance in the past; skip forward
        // to the first occurrence after the day it was completed.
        if mode == .schedule {
            var guardrail = 0
            while candidate <= completed, guardrail < 10_000 {
                candidate = (unit == .week && !weekdays.isEmpty) ? nextWeekday(after: candidate, calendar: calendar) : advance(candidate, calendar: calendar)
                guardrail += 1
            }
        }

        if let until, candidate > until { return nil }
        return candidate
    }

    private func advance(_ day: Day, calendar: Calendar) -> Day {
        switch unit {
        case .day: return day.adding(.day, interval, calendar: calendar)
        case .week: return day.adding(.day, 7 * interval, calendar: calendar)
        case .month: return day.adding(.month, interval, calendar: calendar)
        case .year: return day.adding(.year, interval, calendar: calendar)
        }
    }

    /// Next listed weekday after `day`. With an interval above one, crossing into
    /// a new week skips `interval - 1` weeks.
    private func nextWeekday(after day: Day, calendar: Calendar) -> Day {
        let current = day.weekday(calendar: calendar)
        if let later = weekdays.first(where: { $0 > current }) {
            return day.adding(days: later - current, calendar: calendar)
        }
        let first = weekdays[0]
        let toNextWeek = 7 - current + first
        return day.adding(days: toNextWeek + 7 * (interval - 1), calendar: calendar)
    }

    public var summary: String {
        let every: String
        switch (unit, interval) {
        case (.day, 1): every = "Every day"
        case (.week, 1): every = "Every week"
        case (.month, 1): every = "Every month"
        case (.year, 1): every = "Every year"
        default: every = "Every \(interval) \(unit.rawValue)s"
        }
        var text = every
        if unit == .week, !weekdays.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            text += " on " + weekdays.map { symbols[$0 - 1] }.joined(separator: ", ")
        }
        if mode == .afterCompletion {
            text = "\(interval) \(unit.rawValue)\(interval == 1 ? "" : "s") after completion"
        }
        if let until { text += " until \(until.relativeLabel())" }
        return text
    }
}
