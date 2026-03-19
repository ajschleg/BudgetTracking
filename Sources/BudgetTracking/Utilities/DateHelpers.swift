import Foundation

enum DateHelpers {
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()

    static func monthString(from date: Date = Date()) -> String {
        monthFormatter.string(from: date)
    }

    static func displayMonth(_ monthString: String) -> String {
        guard let date = monthFormatter.date(from: monthString) else {
            return monthString
        }
        return displayFormatter.string(from: date)
    }

    static func previousMonth(from monthString: String) -> String {
        guard let date = monthFormatter.date(from: monthString),
              let prev = Calendar.current.date(byAdding: .month, value: -1, to: date)
        else { return monthString }
        return self.monthString(from: prev)
    }

    static func nextMonth(from monthString: String) -> String {
        guard let date = monthFormatter.date(from: monthString),
              let next = Calendar.current.date(byAdding: .month, value: 1, to: date)
        else { return monthString }
        return self.monthString(from: next)
    }

    static func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func parseDate(_ string: String, format: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: string)
    }

    static let commonDateFormats = [
        "MM/dd/yyyy",
        "M/d/yyyy",
        "yyyy-MM-dd",
        "MM-dd-yyyy",
        "dd/MM/yyyy",
        "MM/dd/yy",
        "M/d/yy",
        "yyyy/MM/dd",
    ]
}
