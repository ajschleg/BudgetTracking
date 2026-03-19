import Foundation

@Observable
final class TransactionsViewModel {
    var transactions: [Transaction] = []
    var categories: [BudgetCategory] = []
    var searchText: String = ""
    var selectedCategoryFilter: UUID?
    var errorMessage: String?

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
            // Update local state
            if let idx = transactions.firstIndex(where: { $0.id == transactionId }) {
                transactions[idx].categoryId = categoryId
                transactions[idx].isManuallyCategorized = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func categoryName(for id: UUID?) -> String {
        guard let id else { return "Uncategorized" }
        return categories.first(where: { $0.id == id })?.name ?? "Uncategorized"
    }
}
