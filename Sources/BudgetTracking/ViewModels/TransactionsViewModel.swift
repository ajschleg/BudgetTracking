import Foundation

@Observable
final class TransactionsViewModel {
    var transactions: [Transaction] = []
    var categories: [BudgetCategory] = []
    var searchText: String = ""
    var selectedCategoryFilter: UUID?
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
        if let catId = selectedCategoryFilter {
            result = result.filter { $0.categoryId == catId }
        }
        return result
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

    func categoryName(for id: UUID?) -> String {
        guard let id else { return "Uncategorized" }
        return categories.first(where: { $0.id == id })?.name ?? "Uncategorized"
    }
}
