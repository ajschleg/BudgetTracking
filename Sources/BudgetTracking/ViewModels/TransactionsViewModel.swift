import Foundation

@Observable
final class TransactionsViewModel {
    var transactions: [Transaction] = []
    var categories: [BudgetCategory] = []
    var searchText: String = ""
    var selectedCategoryFilter: UUID?
    var showOnlyUncategorized: Bool = false
    var errorMessage: String?
    var lastBulkUpdateCount: Int = 0

    private var currentMonth: String = ""

    var filteredTransactions: [Transaction] {
        var result = transactions
        if !searchText.isEmpty {
            result = result.filter {
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
        if showOnlyUncategorized {
            result = result.filter { $0.categoryId == nil }
        } else if let catId = selectedCategoryFilter {
            result = result.filter { $0.categoryId == catId }
        }
        return result
    }

    var uncategorizedCount: Int {
        transactions.filter { $0.categoryId == nil }.count
    }

    func load(month: String) {
        currentMonth = month
        do {
            transactions = try DatabaseManager.shared.fetchTransactions(forMonth: month)
            categories = try DatabaseManager.shared.fetchCategories()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateCategory(for transactionId: UUID, to categoryId: UUID) {
        do {
            try DatabaseManager.shared.updateTransactionCategory(
                transactionId, categoryId: categoryId, isManual: true
            )

            // Find the transaction to learn from
            guard let transaction = transactions.first(where: { $0.id == transactionId }) else {
                return
            }

            // Learn rule and bulk-update all similar transactions
            let bulkCount = RuleLearner.learnFromOverride(
                transaction: transaction, newCategoryId: categoryId
            )
            lastBulkUpdateCount = bulkCount

            // Reload all transactions to reflect bulk changes
            load(month: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-apply all categorization rules to every transaction in the database.
    /// Any transaction where a rule matches and the category differs will be
    /// updated. Returns the number of transactions that changed category.
    @discardableResult
    func reapplyRules() -> Int {
        do {
            let rules = try DatabaseManager.shared.fetchRules()
            let cats = try DatabaseManager.shared.fetchCategories()
            let engine = CategorizationEngine(rules: rules, categories: cats)

            let candidates = try DatabaseManager.shared.fetchAllActiveTransactions()

            print("[ReapplyRules] Rules count: \(rules.count)")
            for rule in rules {
                print("[ReapplyRules]   Rule: keyword=\"\(rule.keyword)\" categoryId=\(rule.categoryId)")
            }
            print("[ReapplyRules] Total candidates: \(candidates.count)")

            // Debug: find Zelle transactions specifically
            let zelleMatches = candidates.filter { $0.description.uppercased().contains("ZELLE") }
            print("[ReapplyRules] Zelle transactions found: \(zelleMatches.count)")
            for z in zelleMatches.prefix(5) {
                let desc = z.description
                let upper = desc.uppercased()
                let ruleMatch = engine.categorize(description: desc, merchant: z.merchant)
                print("[ReapplyRules]   desc=\"\(desc)\" month=\(z.month) categoryId=\(String(describing: z.categoryId)) ruleMatch=\(String(describing: ruleMatch?.keyword))")
                // Check each rule manually
                for rule in rules {
                    let contains = upper.contains(rule.keyword.uppercased())
                    if rule.keyword.uppercased().contains("ZELLE") || contains {
                        print("[ReapplyRules]     vs rule keyword=\"\(rule.keyword)\" upper=\"\(rule.keyword.uppercased())\" contains=\(contains)")
                    }
                }
            }

            var count = 0
            for txn in candidates {
                if let rule = engine.categorize(description: txn.description, merchant: txn.merchant) {
                    // Only update if the category actually changes
                    guard rule.categoryId != txn.categoryId else { continue }
                    try DatabaseManager.shared.updateTransactionCategory(
                        txn.id, categoryId: rule.categoryId, isManual: false
                    )
                    try DatabaseManager.shared.incrementRuleMatchCount(rule.id)
                    count += 1
                }
            }

            print("[ReapplyRules] Updated count: \(count)")
            load(month: currentMonth)
            return count
        } catch {
            print("[ReapplyRules] ERROR: \(error)")
            errorMessage = error.localizedDescription
            return 0
        }
    }

    func categoryName(for id: UUID?) -> String {
        guard let id else { return "Uncategorized" }
        return categories.first(where: { $0.id == id })?.name ?? "Uncategorized"
    }
}
