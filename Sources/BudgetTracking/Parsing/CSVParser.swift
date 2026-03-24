import Foundation
import CodableCSV

struct CSVStatementParser: StatementParser {
    let delimiter: String

    func parse(fileURL: URL, bankProfile: BankProfile?) throws -> [ParsedRow] {
        guard fileURL.startAccessingSecurityScopedResource() || true else {
            throw ParserError.parseFailure("Cannot access file")
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        // Read file content and strip trailing commas from each line.
        // Some exports (e.g. Chase yearly activity) have trailing commas that
        // create extra fields, causing a header/field count mismatch.
        // Normalize \r\n → \n first, then split, to avoid creating empty lines.
        let rawContent = try String(contentsOf: fileURL, encoding: .utf8)
        let normalized = rawContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Determine the delimiter character used in the file.
        let delimChar: Character = delimiter == "\t" ? "\t" : ","

        // Count fields in the header line to know how many columns are expected.
        let headerFieldCount = lines.first.map { line in
            line.filter { $0 == delimChar }.count + 1
        } ?? 0

        let cleanedContent = lines
            .map { line -> String in
                // Strip at most one trailing comma (with optional whitespace) per line,
                // but only if the line has MORE fields than the header. This avoids
                // removing a legitimate empty trailing field (e.g. an empty Memo column)
                // that matches a real header column.
                guard line.hasSuffix(",") || line.hasSuffix(", ") else { return line }
                let lineFieldCount = line.filter { $0 == delimChar }.count + 1
                guard lineFieldCount > headerFieldCount else { return line }
                var s = line
                while s.last?.isWhitespace == true { s.removeLast() }
                if s.last == "," { s.removeLast() }
                return s
            }
            .joined(separator: "\n")

        let reader = try CSVReader(input: cleanedContent) {
            $0.delimiters.field = delimiter == "\t" ? "\t" : ","
            $0.headerStrategy = .firstLine
        }

        let headers = reader.headers

        // Read all rows
        var rawRows: [[String]] = []
        while let row = try reader.readRow() {
            rawRows.append(row)
        }

        guard !rawRows.isEmpty, !headers.isEmpty else {
            throw ParserError.noData
        }

        // Use bank profile or auto-detect columns
        let mapping: ColumnMapping
        if let profile = bankProfile {
            mapping = mappingFromProfile(profile, headers: headers)
        } else {
            let sampleRows = Array(rawRows.prefix(10))
            mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)
        }

        let dateFormat = mapping.detectedDateFormat ?? bankProfile?.dateFormat ?? "MM/dd/yyyy"

        // Parse rows
        return rawRows.compactMap { row -> ParsedRow? in
            var rawCols: [String: String] = [:]
            for (i, header) in headers.enumerated() where i < row.count {
                rawCols[header] = row[i]
            }

            var date: Date?
            if let dateIdx = mapping.dateIndex, dateIdx < row.count {
                date = DateHelpers.parseDate(row[dateIdx].trimmingCharacters(in: .whitespaces), format: dateFormat)
            }

            var description: String?
            if let descIdx = mapping.descriptionIndex, descIdx < row.count {
                description = row[descIdx].trimmingCharacters(in: .whitespaces)
            }

            var amount: Double?
            if let amtIdx = mapping.amountIndex, amtIdx < row.count {
                amount = ColumnMapper.parseAmount(row[amtIdx])
            } else if let debitIdx = mapping.debitIndex, let creditIdx = mapping.creditIndex {
                let debit = debitIdx < row.count ? ColumnMapper.parseAmount(row[debitIdx]) : nil
                let credit = creditIdx < row.count ? ColumnMapper.parseAmount(row[creditIdx]) : nil
                if let d = debit, d != 0 {
                    amount = -abs(d)
                } else if let c = credit, c != 0 {
                    amount = abs(c)
                }
            }

            var merchant: String?
            if let merchantIdx = mapping.merchantIndex, merchantIdx < row.count {
                let val = row[merchantIdx].trimmingCharacters(in: .whitespaces)
                if !val.isEmpty { merchant = val }
            }

            var sourceCategory: String?
            if let catIdx = mapping.sourceCategoryIndex, catIdx < row.count {
                let val = row[catIdx].trimmingCharacters(in: .whitespaces)
                if !val.isEmpty { sourceCategory = val }
            }

            return ParsedRow(
                date: date, description: description, amount: amount,
                merchant: merchant, sourceCategory: sourceCategory,
                rawColumns: rawCols
            )
        }
    }

    private func mappingFromProfile(_ profile: BankProfile, headers: [String]) -> ColumnMapping {
        var mapping = ColumnMapping()
        if let col = profile.dateColumn, let idx = headers.firstIndex(of: col) {
            mapping.dateIndex = idx
        }
        if let col = profile.descriptionColumn, let idx = headers.firstIndex(of: col) {
            mapping.descriptionIndex = idx
        }
        if let col = profile.amountColumn, let idx = headers.firstIndex(of: col) {
            mapping.amountIndex = idx
        }
        if let col = profile.debitColumn, let idx = headers.firstIndex(of: col) {
            mapping.debitIndex = idx
        }
        if let col = profile.creditColumn, let idx = headers.firstIndex(of: col) {
            mapping.creditIndex = idx
        }
        mapping.detectedDateFormat = profile.dateFormat
        return mapping
    }
}
