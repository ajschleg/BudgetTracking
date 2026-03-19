import Foundation

enum MonthDetector {
    /// Detect the target month from parsed transaction dates, filename, or fall back to current month.
    static func detectMonth(
        from rows: [ParsedRow],
        fileName: String
    ) -> String {
        // 1. Try transaction dates — use the most common month among parsed dates
        if let month = detectFromTransactionDates(rows) {
            return month
        }

        // 2. Try filename patterns
        if let month = detectFromFileName(fileName) {
            return month
        }

        // 3. Fall back to current month
        return DateHelpers.monthString()
    }

    private static func detectFromTransactionDates(_ rows: [ParsedRow]) -> String? {
        let months = rows.compactMap { row -> String? in
            guard let date = row.date else { return nil }
            return DateHelpers.monthString(from: date)
        }

        guard !months.isEmpty else { return nil }

        // Find the most common month
        var counts: [String: Int] = [:]
        for month in months {
            counts[month, default: 0] += 1
        }

        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func detectFromFileName(_ fileName: String) -> String? {
        let name = fileName.lowercased()

        // Pattern: "YYYY-MM" or "YYYYMM"
        if let match = name.range(of: #"(20\d{2})[-_]?(0[1-9]|1[0-2])"#, options: .regularExpression) {
            let matched = String(name[match])
            let digits = matched.filter(\.isNumber)
            if digits.count >= 6 {
                let year = String(digits.prefix(4))
                let month = String(digits.dropFirst(4).prefix(2))
                return "\(year)-\(month)"
            }
        }

        // Pattern: month names — "January", "Jan", "Feb", "March", etc.
        let monthNames: [(String, String)] = [
            ("january", "01"), ("jan", "01"),
            ("february", "02"), ("feb", "02"),
            ("march", "03"), ("mar", "03"),
            ("april", "04"), ("apr", "04"),
            ("may", "05"),
            ("june", "06"), ("jun", "06"),
            ("july", "07"), ("jul", "07"),
            ("august", "08"), ("aug", "08"),
            ("september", "09"), ("sep", "09"), ("sept", "09"),
            ("october", "10"), ("oct", "10"),
            ("november", "11"), ("nov", "11"),
            ("december", "12"), ("dec", "12"),
        ]

        // Check longer names first to avoid "mar" matching inside "march"
        let sorted = monthNames.sorted { $0.0.count > $1.0.count }

        for (monthName, monthNum) in sorted {
            if name.contains(monthName) {
                // Try to find a year near the month name
                if let yearMatch = name.range(of: #"20\d{2}"#, options: .regularExpression) {
                    let year = String(name[yearMatch])
                    return "\(year)-\(monthNum)"
                }
                // Use current year if no year found
                let currentYear = Calendar.current.component(.year, from: Date())
                return "\(currentYear)-\(monthNum)"
            }
        }

        // Pattern: "MM-DD-YYYY" or "MMDDYYYY" in filename
        if let match = name.range(of: #"(0[1-9]|1[0-2])[-_]?\d{2}[-_]?(20\d{2})"#, options: .regularExpression) {
            let matched = String(name[match])
            let digits = matched.filter(\.isNumber)
            if digits.count >= 8 {
                let month = String(digits.prefix(2))
                let year = String(digits.suffix(4))
                return "\(year)-\(month)"
            }
        }

        return nil
    }
}
