import Foundation

struct CategorizationEngine {
    let rules: [CategorizationRule]
    let categories: [BudgetCategory]

    func categorize(description: String) -> CategorizationRule? {
        let upper = description.uppercased()
        // Rules are already sorted by priority descending
        return rules.first { rule in
            upper.contains(rule.keyword.uppercased())
        }
    }

    func categorizeAll(transactions: inout [Transaction]) {
        for i in 0..<transactions.count {
            guard !transactions[i].isManuallyCategorized else { continue }
            if let rule = categorize(description: transactions[i].description) {
                transactions[i].categoryId = rule.categoryId
            }
        }
    }
}
