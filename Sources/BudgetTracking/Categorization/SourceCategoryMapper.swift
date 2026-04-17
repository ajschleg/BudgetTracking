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

        // Plaid personal_finance_category.primary taxonomy.
        // https://plaid.com/docs/api/products/transactions/#transactions-personal-finance-category-taxonomy
        // Keys that already appear above (medical, transportation,
        // travel, entertainment) are intentionally NOT duplicated —
        // Swift dictionary literals crash on duplicate keys. The
        // existing values already point at the correct app category.
        "food_and_drink": "Dining Out",
        "general_merchandise": "Shopping",
        "general_services": "Shopping",
        "home_improvement": "Home Improvement",
        "personal_care": "Health",
        "rent_and_utilities": "Utilities",
        "loan_payments": "Money Transfers",
        "bank_fees": "Bank Adjustments",
        "transfer_in": "Money Transfers",
        "transfer_out": "Money Transfers",
        "income": "Money Transfers",

        // Plaid personal_finance_category.detailed codes that override
        // the primary bucket when they point to something more specific.
        "food_and_drink_groceries": "Groceries",
        "food_and_drink_restaurant": "Dining Out",
        "food_and_drink_fast_food": "Dining Out",
        "food_and_drink_coffee": "Dining Out",
        "food_and_drink_beer_wine_and_liquor": "Dining Out",
        "general_merchandise_gas_stations": "Gas",
        "transportation_gas": "Gas",
        "transportation_public_transit": "Transportation",
        "transportation_taxis_and_ride_shares": "Transportation",
        "rent_and_utilities_gas_and_electricity": "Utilities",
        "rent_and_utilities_internet_and_cable": "Utilities",
        "rent_and_utilities_telephone": "Utilities",
        "rent_and_utilities_water": "Utilities",
        "rent_and_utilities_sewage_and_waste_management": "Utilities",
        "medical_pharmacies_and_supplements": "Health",
        "medical_primary_care": "Health",
        "medical_dental_care": "Health",
        "home_improvement_hardware": "Home Improvement",
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
