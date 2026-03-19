import Foundation
import CoreXLSX

struct XLSXStatementParser: StatementParser {
    func parse(fileURL: URL, bankProfile: BankProfile?) throws -> [ParsedRow] {
        guard fileURL.startAccessingSecurityScopedResource() || true else {
            throw ParserError.parseFailure("Cannot access file")
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }

        guard let file = XLSXFile(filepath: fileURL.path) else {
            throw ParserError.parseFailure("Could not open XLSX file")
        }
        let sharedStrings = try file.parseSharedStrings()

        guard let workbook = try? file.parseWorkbooks().first,
              let sheetPath = try file.parseWorksheetPathsAndNames(workbook: workbook).first?.path
        else {
            throw ParserError.noData
        }

        let worksheet = try file.parseWorksheet(at: sheetPath)
        guard let rows = worksheet.data?.rows, rows.count > 1 else {
            throw ParserError.noData
        }

        // First row is headers
        let headerRow = rows[0]
        let headers = headerRow.cells.map { cell -> String in
            sharedStrings.flatMap { cell.stringValue($0) } ?? (cell.value ?? "")
        }

        // Data rows
        var dataRows: [[String]] = []
        for row in rows.dropFirst() {
            let values = row.cells.map { cell -> String in
                sharedStrings.flatMap { cell.stringValue($0) } ?? (cell.value ?? "")
            }
            dataRows.append(values)
        }

        guard !dataRows.isEmpty else {
            throw ParserError.noData
        }

        // Detect columns
        let mapping: ColumnMapping
        if let profile = bankProfile {
            mapping = mappingFromProfile(profile, headers: headers)
        } else {
            let sampleRows = Array(dataRows.prefix(10))
            mapping = ColumnMapper.detectColumns(headers: headers, sampleRows: sampleRows)
        }

        let dateFormat = mapping.detectedDateFormat ?? bankProfile?.dateFormat ?? "MM/dd/yyyy"

        return dataRows.compactMap { row -> ParsedRow? in
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
            }

            return ParsedRow(date: date, description: description, amount: amount, rawColumns: rawCols)
        }
    }

    private func mappingFromProfile(_ profile: BankProfile, headers: [String]) -> ColumnMapping {
        var mapping = ColumnMapping()
        if let col = profile.dateColumn, let idx = headers.firstIndex(of: col) { mapping.dateIndex = idx }
        if let col = profile.descriptionColumn, let idx = headers.firstIndex(of: col) { mapping.descriptionIndex = idx }
        if let col = profile.amountColumn, let idx = headers.firstIndex(of: col) { mapping.amountIndex = idx }
        if let col = profile.debitColumn, let idx = headers.firstIndex(of: col) { mapping.debitIndex = idx }
        if let col = profile.creditColumn, let idx = headers.firstIndex(of: col) { mapping.creditIndex = idx }
        mapping.detectedDateFormat = profile.dateFormat
        return mapping
    }
}
