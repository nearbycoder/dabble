import Foundation

/// A calendar day with no time or time zone, e.g. 2026-11-03.
///
/// "When" dates and deadlines in Dabble are days, not instants, so a to-do
/// scheduled for Tuesday stays on Tuesday when you travel.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static var today: Day { Day(Date()) }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight at the start of this day in the given calendar's time zone.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int, calendar: Calendar = .current) -> Day {
        Day(calendar.date(byAdding: .day, value: days, to: date(calendar: calendar))!, calendar: calendar)
    }

    public func adding(_ component: Calendar.Component, _ value: Int, calendar: Calendar = .current) -> Day {
        Day(calendar.date(byAdding: component, value: value, to: date(calendar: calendar))!, calendar: calendar)
    }

    public func days(until other: Day, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: date(calendar: calendar), to: other.date(calendar: calendar)).day!
    }

    /// 1 = Sunday … 7 = Saturday, matching `Calendar`.
    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date(calendar: calendar))
    }

    /// A short human label relative to `today`: "Today", "Tomorrow", "Fri", "Nov 12", "Nov 12, 2027".
    public func relativeLabel(today: Day = .today, calendar: Calendar = .current) -> String {
        let offset = today.days(until: self, calendar: calendar)
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6:
            return date(calendar: calendar).formatted(.dateTime.weekday(.wide))
        default:
            if year == today.year {
                return date(calendar: calendar).formatted(.dateTime.month(.abbreviated).day())
            }
            return date(calendar: calendar).formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

extension Day: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = Day(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day \(string)")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
