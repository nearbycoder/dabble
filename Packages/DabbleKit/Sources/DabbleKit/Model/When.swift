import Foundation

/// The answer to "When?" — Things' scheduling vocabulary.
public enum When: Hashable, Sendable {
    case today
    case evening
    case anytime
    case someday
    case date(Day)
    /// Back to the inbox (loose to-dos only).
    case inbox

    /// Parses what people type into a When field: "today", "tonight", "tom",
    /// "fri", "next week", "in 3 days", "12/25", "Dec 25", "2027-01-15", …
    public static func parse(_ input: String, today: Day = .today, calendar: Calendar = .current) -> When? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        func matches(_ words: String...) -> Bool {
            words.contains { $0.hasPrefix(text) && text.count >= min(3, $0.count) || $0 == text }
        }

        if matches("today", "now") { return .today }
        if matches("tonight", "this evening", "evening") { return .evening }
        if matches("tomorrow") || text == "tmr" || text == "tmrw" { return .date(today.adding(days: 1, calendar: calendar)) }
        if matches("anytime") { return .anytime }
        if matches("someday", "later") { return .someday }
        if matches("inbox") { return .inbox }
        if text == "next week" { return .date(nextWeekday(2, after: today, calendar: calendar, skipWeek: false)) }
        if text == "next month" {
            let next = today.adding(.month, 1, calendar: calendar)
            return .date(Day(year: next.year, month: next.month, day: 1))
        }
        if text == "weekend" || text == "this weekend" {
            return .date(nextWeekday(7, after: today, calendar: calendar, skipWeek: false, includeToday: true))
        }

        // "in 3 days", "3 days", "in 2 weeks", "in a month"
        let relative = text.replacingOccurrences(of: "in ", with: "").replacingOccurrences(of: "an ", with: "1 ").replacingOccurrences(of: "a ", with: "1 ")
        let parts = relative.split(separator: " ")
        if parts.count == 2, let count = Int(parts[0]) {
            let unit = parts[1]
            if unit.hasPrefix("d") { return .date(today.adding(days: count, calendar: calendar)) }
            if unit.hasPrefix("w") { return .date(today.adding(days: 7 * count, calendar: calendar)) }
            if unit.hasPrefix("m") { return .date(today.adding(.month, count, calendar: calendar)) }
            if unit.hasPrefix("y") { return .date(today.adding(.year, count, calendar: calendar)) }
        }

        // Weekday names, optionally prefixed with "next".
        var weekdayText = text
        var skipWeek = false
        if weekdayText.hasPrefix("next ") {
            weekdayText.removeFirst(5)
            skipWeek = true
        }
        if weekdayText.count >= 2, let index = weekdayIndex(weekdayText, calendar: calendar) {
            return .date(nextWeekday(index + 1, after: today, calendar: calendar, skipWeek: skipWeek))
        }

        if let day = Day(text) { return .date(day) }
        if let day = parseCalendarDate(text, today: today, calendar: calendar) { return .date(day) }
        return nil
    }

    static let englishWeekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// 0-based weekday (Sunday = 0) for a full or abbreviated name, in English or the calendar's language.
    static func weekdayIndex(_ text: String, calendar: Calendar = .current) -> Int? {
        let lowered = text.lowercased()
        let localized = calendar.standaloneWeekdaySymbols.map { $0.lowercased() }
        return englishWeekdays.firstIndex { $0.hasPrefix(lowered) } ?? localized.firstIndex { $0.hasPrefix(lowered) }
    }

    private static func nextWeekday(_ weekday: Int, after today: Day, calendar: Calendar, skipWeek: Bool, includeToday: Bool = false) -> Day {
        var offset = (weekday - today.weekday(calendar: calendar) + 7) % 7
        if offset == 0 && !includeToday { offset = 7 }
        if skipWeek && offset < 7 { offset += 7 }
        return today.adding(days: offset, calendar: calendar)
    }

    /// "12/25", "12/25/2027", "dec 25", "25 dec", "december 25 2027".
    private static func parseCalendarDate(_ text: String, today: Day, calendar: Calendar) -> Day? {
        let numeric = text.split(whereSeparator: { $0 == "/" || $0 == "." }).compactMap { Int($0) }
        if numeric.count >= 2, text.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "." }) {
            let month = numeric[0], day = numeric[1]
            var year = numeric.count > 2 ? numeric[2] : today.year
            if year < 100 { year += 2000 }
            return validated(year: year, month: month, day: day, explicitYear: numeric.count > 2, today: today, calendar: calendar)
        }

        let tokens = text.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        let months = calendar.monthSymbols.map { $0.lowercased() }
        var month: Int?
        var numbers: [Int] = []
        for token in tokens {
            if let number = Int(token.trimmingCharacters(in: CharacterSet.letters)) {
                numbers.append(number)
            } else if token.count >= 3, let index = months.firstIndex(where: { $0.hasPrefix(token) }) {
                month = index + 1
            }
        }
        guard let month, let day = numbers.first else { return nil }
        let year = numbers.count > 1 ? numbers[1] : today.year
        return validated(year: year, month: month, day: day, explicitYear: numbers.count > 1, today: today, calendar: calendar)
    }

    private static func validated(year: Int, month: Int, day: Int, explicitYear: Bool, today: Day, calendar: Calendar) -> Day? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        var result = Day(date, calendar: calendar)
        guard result.month == month else { return nil } // rejects Feb 30
        if !explicitYear && result < today {
            result = Day(year: year + 1, month: month, day: day)
        }
        return result
    }

    public var label: String {
        switch self {
        case .today: "Today"
        case .evening: "This Evening"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .inbox: "Inbox"
        case .date(let day): day.relativeLabel()
        }
    }
}
