import Foundation

struct QIFStatementParser: StatementParser {
    func parse(fileURL: URL, bankProfile: BankProfile?) throws -> [ParsedRow] {
        guard fileURL.startAccessingSecurityScopedResource() || true else {
            throw ParserError.parseFailure("Cannot access file")
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var rows: [ParsedRow] = []
        var currentDate: Date?
        var currentAmount: Double?
        var currentDescription: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let code = trimmed.prefix(1)
            let value = String(trimmed.dropFirst())

            switch code {
            case "D": // Date
                currentDate = parseQIFDate(value)
            case "T", "U": // Amount
                currentAmount = ColumnMapper.parseAmount(value)
            case "P": // Payee
                currentDescription = value.trimmingCharacters(in: .whitespaces)
            case "M": // Memo — use as fallback description
                if currentDescription == nil || currentDescription?.isEmpty == true {
                    currentDescription = value.trimmingCharacters(in: .whitespaces)
                }
            case "^": // End of record
                var rawCols: [String: String] = [:]
                if let d = currentDate { rawCols["Date"] = DateHelpers.shortDate(d) }
                if let a = currentAmount { rawCols["Amount"] = String(a) }
                if let p = currentDescription { rawCols["Payee"] = p }

                rows.append(ParsedRow(
                    date: currentDate,
                    description: currentDescription,
                    amount: currentAmount,
                    rawColumns: rawCols
                ))
                currentDate = nil
                currentAmount = nil
                currentDescription = nil
            default:
                break
            }
        }

        guard !rows.isEmpty else {
            throw ParserError.noData
        }

        return rows
    }

    private func parseQIFDate(_ string: String) -> Date? {
        // QIF dates can be M/D/YY, M/D'YY, M/D/YYYY, etc.
        let cleaned = string
            .replacingOccurrences(of: "'", with: "/")
            .replacingOccurrences(of: "-", with: "/")

        for format in ["M/d/yyyy", "M/d/yy", "MM/dd/yyyy", "MM/dd/yy"] {
            if let date = DateHelpers.parseDate(cleaned, format: format) {
                return date
            }
        }
        return nil
    }
}
