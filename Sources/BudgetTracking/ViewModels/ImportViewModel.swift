import Foundation
import UniformTypeIdentifiers

enum ImportState {
    case idle
    case parsing
    case preview(rows: [ParsedRow], fileName: String, fileSize: Int64)
    case columnMapping(rows: [ParsedRow], columns: [String], fileName: String, fileSize: Int64)
    case importing
    case done(count: Int)
    case error(String)
}

enum DuplicateAction {
    case importAnyway
    case replace
    case cancel
}

@Observable
final class ImportViewModel {
    var state: ImportState = .idle
    var importedFiles: [ImportedFile] = []
    var showDuplicateAlert = false
    var duplicateFile: ImportedFile?
    var pendingFileURL: URL?
    var errorMessage: String?

    /// Set by the import flow when a month is auto-detected from file contents/name.
    /// The view should observe this and update the month selector.
    var detectedMonth: String?

    /// When a multi-month file is imported, contains the months and counts.
    var importedMonthBreakdown: [(month: String, count: Int)] = []


    // Column mapping state
    var dateColumnIndex: Int?
    var descriptionColumnIndex: Int?
    var amountColumnIndex: Int?
    var selectedDateFormat: String = "MM/dd/yyyy"

    // Sign convention: when true, positive amounts = money spent (e.g., Apple Card)
    var positiveIsSpending: Bool = false

    func loadImportedFiles(month: String) {
        do {
            importedFiles = try DatabaseManager.shared.fetchImportedFiles(forMonth: month)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleFileDrop(urls: [URL], month: String) {
        guard let url = urls.first else { return }
        processFile(url: url, month: month)
    }

    func processFile(url: URL, month: String) {
        state = .parsing

        let fileName = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        // Check for duplicate — check both the selected month and multi-month (nil)
        do {
            let existing = try DatabaseManager.shared.findDuplicateFile(
                name: fileName, size: fileSize, month: month
            ) ?? DatabaseManager.shared.findDuplicateFile(
                name: fileName, size: fileSize, month: nil
            )
            if let existing {
                duplicateFile = existing
                pendingFileURL = url
                showDuplicateAlert = true
                state = .idle
                return
            }
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        parseFile(url: url, fileName: fileName, fileSize: fileSize)
    }

    func handleDuplicateAction(_ action: DuplicateAction, month: String) {
        guard let url = pendingFileURL else { return }
        let fileName = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        switch action {
        case .importAnyway:
            parseFile(url: url, fileName: fileName, fileSize: fileSize)
        case .replace:
            if let existing = duplicateFile {
                do {
                    try DatabaseManager.shared.deleteImportedFile(existing)
                    loadImportedFiles(month: month)
                } catch {
                    state = .error(error.localizedDescription)
                    return
                }
            }
            parseFile(url: url, fileName: fileName, fileSize: fileSize)
        case .cancel:
            state = .idle
        }
        duplicateFile = nil
        pendingFileURL = nil
    }

    private func parseFile(url: URL, fileName: String, fileSize: Int64) {
        do {
            let parser = try StatementParserFactory.parser(for: url)
            let rows = try parser.parse(fileURL: url, bankProfile: nil)

            if rows.isEmpty {
                state = .error("No transactions found in file")
                return
            }

            // Auto-detect sign convention: if most amounts are positive, likely "positive = spending"
            let amounts = rows.compactMap(\.amount)
            let positiveCount = amounts.filter({ $0 > 0 }).count
            if amounts.count > 0 && Double(positiveCount) / Double(amounts.count) > 0.7 {
                positiveIsSpending = true
            } else {
                positiveIsSpending = false
            }

            // Auto-detect the target month from transaction dates or filename
            detectedMonth = MonthDetector.detectMonth(from: rows, fileName: fileName)

            // Check if most rows have auto-detected date and amount.
            // For PDFs and structured formats, go straight to preview.
            let ext = url.pathExtension.lowercased()
            let nonCsvFormats = ["pdf", "ofx", "qfx", "qif"]
            let detectedCount = rows.filter({ $0.date != nil && $0.amount != nil }).count

            if nonCsvFormats.contains(ext) || detectedCount > rows.count / 2 {
                // Enough data auto-detected — show preview
                state = .preview(rows: rows, fileName: fileName, fileSize: fileSize)
            } else {
                let columns = Array(rows[0].rawColumns.keys.sorted())
                state = .columnMapping(
                    rows: rows, columns: columns,
                    fileName: fileName, fileSize: fileSize
                )
            }
        } catch {
            state = .error("Failed to parse file: \(error.localizedDescription)")
        }
    }

    func confirmImport(rows: [ParsedRow], fileName: String, fileSize: Int64, month: String) {
        state = .importing

        do {
            let categories = try DatabaseManager.shared.fetchCategories()
            let rules = try DatabaseManager.shared.fetchRules()
            let engine = CategorizationEngine(rules: rules, categories: categories)

            // Determine if this file spans multiple months
            var monthCounts: [String: Int] = [:]
            for row in rows {
                if let date = row.date {
                    let m = DateHelpers.monthString(from: date)
                    monthCounts[m, default: 0] += 1
                }
            }

            let isMultiMonth = monthCounts.count > 1
            let fileMonth: String? = isMultiMonth ? nil : (monthCounts.keys.first ?? month)

            let importedFile = ImportedFile(
                fileName: fileName,
                fileSize: fileSize,
                month: fileMonth,
                transactionCount: rows.count
            )
            try DatabaseManager.shared.saveImportedFile(importedFile)

            var transactions: [Transaction] = []
            for row in rows {
                guard let date = row.date, let rawAmount = row.amount else { continue }
                // Normalize: internally negative = money spent, positive = money received
                let amount = positiveIsSpending ? -rawAmount : rawAmount
                // Derive month from the transaction's own date
                let txnMonth = DateHelpers.monthString(from: date)
                var txn = Transaction(
                    date: date,
                    description: row.description ?? "Unknown",
                    merchant: row.merchant,
                    amount: amount,
                    month: txnMonth,
                    importedFileId: importedFile.id
                )
                // 1. Try source category from the bank (e.g., Apple Card "Category" column)
                if let sourceCategory = row.sourceCategory,
                   let catId = SourceCategoryMapper.mapToCategory(
                       sourceCategory: sourceCategory, categories: categories
                   )
                {
                    txn.categoryId = catId
                }
                // 2. Fall back to keyword rules
                else if let match = engine.categorize(
                    description: txn.description,
                    merchant: row.merchant
                ) {
                    txn.categoryId = match.categoryId
                    try DatabaseManager.shared.incrementRuleMatchCount(match.id)
                }
                transactions.append(txn)
            }

            try DatabaseManager.shared.saveTransactions(transactions)

            if isMultiMonth {
                importedMonthBreakdown = monthCounts
                    .sorted { $0.key < $1.key }
                    .map { (month: $0.key, count: $0.value) }
            } else {
                importedMonthBreakdown = []
            }

            loadImportedFiles(month: month)
            state = .done(count: transactions.count)
        } catch {
            state = .error("Import failed: \(error.localizedDescription)")
        }
    }

    func deleteImportedFile(_ file: ImportedFile, month: String) {
        do {
            try DatabaseManager.shared.deleteImportedFile(file)
            loadImportedFiles(month: month)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        state = .idle
        dateColumnIndex = nil
        descriptionColumnIndex = nil
        amountColumnIndex = nil
        positiveIsSpending = false
        detectedMonth = nil
        importedMonthBreakdown = []
    }
}
