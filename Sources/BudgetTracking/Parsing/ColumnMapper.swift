import Foundation

enum ColumnRole {
    case date
    case description
    case amount
    case debit
    case credit
    case ignore
}

struct ColumnMapping {
    var dateIndex: Int?
    var descriptionIndex: Int?
    var amountIndex: Int?
    var debitIndex: Int?
    var creditIndex: Int?
    var detectedDateFormat: String?
}

enum ColumnMapper {
    private static let dateKeywords = ["date", "posted", "transaction date", "posting date", "trans date"]
    private static let descriptionKeywords = ["description", "memo", "payee", "name", "merchant", "details", "transaction"]
    private static let amountKeywords = ["amount", "total"]
    private static let debitKeywords = ["debit", "withdrawal", "charge"]
    private static let creditKeywords = ["credit", "deposit", "payment"]

    static func detectColumns(headers: [String], sampleRows: [[String]]) -> ColumnMapping {
        var mapping = ColumnMapping()
        let lowerHeaders = headers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        // Try header-based detection
        for (i, header) in lowerHeaders.enumerated() {
            if mapping.dateIndex == nil && dateKeywords.contains(where: { header.contains($0) }) {
                mapping.dateIndex = i
            } else if mapping.descriptionIndex == nil && descriptionKeywords.contains(where: { header.contains($0) }) {
                mapping.descriptionIndex = i
            } else if mapping.amountIndex == nil && amountKeywords.contains(where: { header.contains($0) }) {
                mapping.amountIndex = i
            } else if mapping.debitIndex == nil && debitKeywords.contains(where: { header.contains($0) }) {
                mapping.debitIndex = i
            } else if mapping.creditIndex == nil && creditKeywords.contains(where: { header.contains($0) }) {
                mapping.creditIndex = i
            }
        }

        // If header detection failed, try data-based heuristics
        if mapping.dateIndex == nil || mapping.amountIndex == nil {
            detectFromData(sampleRows: sampleRows, mapping: &mapping)
        }

        // Detect date format from sample data
        if let dateIdx = mapping.dateIndex {
            let sampleDates = sampleRows.compactMap { row -> String? in
                guard dateIdx < row.count else { return nil }
                return row[dateIdx]
            }
            mapping.detectedDateFormat = detectDateFormat(samples: sampleDates)
        }

        return mapping
    }

    private static func detectFromData(sampleRows: [[String]], mapping: inout ColumnMapping) {
        guard let firstRow = sampleRows.first else { return }

        for colIdx in 0..<firstRow.count {
            let values = sampleRows.compactMap { row -> String? in
                guard colIdx < row.count else { return nil }
                return row[colIdx].trimmingCharacters(in: .whitespaces)
            }
            guard !values.isEmpty else { continue }

            // Check if column looks like dates
            if mapping.dateIndex == nil && looksLikeDates(values) {
                mapping.dateIndex = colIdx
                continue
            }

            // Check if column looks like amounts
            if mapping.amountIndex == nil && looksLikeAmounts(values) {
                mapping.amountIndex = colIdx
                continue
            }
        }

        // Pick the longest text column as description
        if mapping.descriptionIndex == nil, let firstRow = sampleRows.first {
            var bestIdx = 0
            var bestLen = 0
            for (i, val) in firstRow.enumerated() {
                if i == mapping.dateIndex || i == mapping.amountIndex { continue }
                if val.count > bestLen {
                    bestLen = val.count
                    bestIdx = i
                }
            }
            mapping.descriptionIndex = bestIdx
        }
    }

    private static func looksLikeDates(_ values: [String]) -> Bool {
        let dateMatches = values.filter { val in
            DateHelpers.commonDateFormats.contains { fmt in
                DateHelpers.parseDate(val, format: fmt) != nil
            }
        }
        return dateMatches.count > values.count / 2
    }

    private static func looksLikeAmounts(_ values: [String]) -> Bool {
        let amountMatches = values.filter { val in
            let cleaned = val.replacingOccurrences(of: "[$,]", with: "", options: .regularExpression)
            return Double(cleaned) != nil
        }
        return amountMatches.count > values.count / 2
    }

    static func detectDateFormat(samples: [String]) -> String? {
        for format in DateHelpers.commonDateFormats {
            let matches = samples.filter { DateHelpers.parseDate($0, format: format) != nil }
            if matches.count > samples.count / 2 {
                return format
            }
        }
        return nil
    }

    static func parseAmount(_ string: String) -> Double? {
        let cleaned = string
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle parenthetical negative: (123.45) -> -123.45
        if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
            let inner = String(cleaned.dropFirst().dropLast())
            if let val = Double(inner) {
                return -val
            }
        }

        return Double(cleaned)
    }
}
