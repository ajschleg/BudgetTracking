import Foundation

@Observable
final class CategoriesViewModel {
    private static let savedDefaultsKey = "SavedDefaultCategories"

    var categories: [BudgetCategory] = []
    var rules: [CategorizationRule] = []
    var errorMessage: String?
    var hasSavedDefaults: Bool {
        UserDefaults.standard.data(forKey: Self.savedDefaultsKey) != nil
    }

    func load() {
        do {
            categories = try DatabaseManager.shared.fetchCategories()
            rules = try DatabaseManager.shared.fetchRules()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addCategory(name: String, budget: Double, colorHex: String) {
        let category = BudgetCategory(
            name: name,
            monthlyBudget: budget,
            colorHex: colorHex,
            sortOrder: categories.count
        )
        do {
            try DatabaseManager.shared.saveCategory(category)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateCategory(_ category: BudgetCategory) {
        do {
            try DatabaseManager.shared.saveCategory(category)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAsDefaults() {
        do {
            let data = try JSONEncoder().encode(categories)
            UserDefaults.standard.set(data, forKey: Self.savedDefaultsKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreDefaults() {
        do {
            if let data = UserDefaults.standard.data(forKey: Self.savedDefaultsKey),
               let saved = try? JSONDecoder().decode([BudgetCategory].self, from: data) {
                try DatabaseManager.shared.restoreCategories(saved)
            } else {
                try DatabaseManager.shared.restoreDefaultCategories()
            }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCategory(_ category: BudgetCategory) {
        do {
            try DatabaseManager.shared.deleteCategory(category)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addRule(keyword: String, categoryId: UUID, priority: Int = 0) {
        let rule = CategorizationRule(
            keyword: keyword,
            categoryId: categoryId,
            priority: priority
        )
        do {
            try DatabaseManager.shared.saveRule(rule)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteRule(_ rule: CategorizationRule) {
        do {
            try DatabaseManager.shared.deleteRule(rule)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func categoryName(for id: UUID) -> String {
        categories.first(where: { $0.id == id })?.name ?? "Unknown"
    }
}
