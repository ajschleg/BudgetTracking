import Foundation

/// Maps bank-provided category names (e.g., Apple Card's "Category" column)
/// to the app's BudgetCategory IDs.
enum SourceCategoryMapper {
    /// Known mappings from common bank category names to our category names.
    /// Keys are lowercased source category names.
    private static let categoryMap: [String: String] = [
        // Apple Card categories
        "grocery": "Groceries",
        "groceries": "Groceries",
        "food & drink": "Dining Out",
        "restaurants": "Dining Out",
        "restaurant": "Dining Out",
        "food": "Dining Out",
        "dining": "Dining Out",
        "gas": "Gas",
        "fuel": "Gas",
        "gas station": "Gas",
        "entertainment": "Entertainment",
        "streaming": "Entertainment",
        "music": "Entertainment",
        "shopping": "Shopping",
        "merchandise": "Shopping",
        "retail": "Shopping",
        "clothing": "Shopping",
        "health": "Health",
        "medical": "Health",
        "healthcare": "Health",
        "pharmacy": "Health",
        "transportation": "Transportation",
        "transit": "Transportation",
        "travel": "Transportation",
        "rideshare": "Transportation",
        "car-rentals": "Transportation",
        "hotels": "Shopping",
        "utilities": "Utilities",
        "bills": "Utilities",
        "phone": "Utilities",
        "internet": "Utilities",
        "alcohol": "Dining Out",

        // Common bank category names
        "auto & transport": "Transportation",
        "gas & fuel": "Gas",
        "groceries & supermarkets": "Groceries",
        "food & dining": "Dining Out",
        "health & fitness": "Health",
        "bills & utilities": "Utilities",
        "home improvement": "Shopping",
    ]

    /// Map a source category string to a BudgetCategory ID.
    /// Returns nil if no mapping is found or the category doesn't exist.
    static func mapToCategory(
        sourceCategory: String,
        categories: [BudgetCategory]
    ) -> UUID? {
        let key = sourceCategory.lowercased().trimmingCharacters(in: .whitespaces)

        // Skip non-categorizable types
        let skipTypes = ["payment", "credit", "debit", "transfer", "adjustment"]
        if skipTypes.contains(key) { return nil }

        // Look up our category name from the map
        guard let ourCategoryName = categoryMap[key] else { return nil }

        // Find the matching BudgetCategory
        return categories.first(where: {
            $0.name.lowercased() == ourCategoryName.lowercased()
        })?.id
    }
}
