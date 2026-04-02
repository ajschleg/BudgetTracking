import Foundation
import SwiftUI

@Observable
final class SideHustleViewModel {
    var sources: [IncomeSource] = []
    var selectedSourceId: UUID?
    var incomeTransactions: [Transaction] = []
    var sourceAssignments: [UUID: UUID] = [:]

    // Combined totals
    var monthlyNetProfit: Double = 0
    var lifetimeNetProfit: Double = 0
    var monthlySales: Double = 0
    var monthlyCosts: Double = 0
    var lifetimeSales: Double = 0
    var lifetimeCosts: Double = 0

    // Sourcing (global)
    var sourcingCategoryIds: Set<UUID> = []
    var totalSourcingCosts: Double = 0
    var allSourcingTransactions: [Transaction] = []
    var lifetimeSourcingTransactions: [Transaction] = []
    var manualSourcingTransactionIds: Set<UUID> = []
    var allCategories: [BudgetCategory] = []
    var categorySourcingTransactions: [Transaction] = []
    var manualSourcingTransactions: [Transaction] = []

    // Sheets
    var isManagingSourcingCategories = false
    var isAddingSourcingTransaction = false
    var isAddingSideHustle = false
    var isMonthlySourcingExpanded = false
    var isLifetimeSourcingExpanded = false

    var errorMessage: String?

    private var currentMonth: String = ""
    private static let sourcingCategoryIdsKey = "sourcingCategoryIds"
    private static let legacySourcingKey = "ebaySourcingCategoryIds"

    // Reference to eBay view model for eBay-specific data
    var ebayViewModel: EbayEarningsViewModel

    init(ebayViewModel: EbayEarningsViewModel) {
        self.ebayViewModel = ebayViewModel
        migrateSourcingKey()
    }

    private func migrateSourcingKey() {
        // Migrate old eBay-specific key to new global key
        if UserDefaults.standard.data(forKey: Self.sourcingCategoryIdsKey) == nil,
           let oldData = UserDefaults.standard.data(forKey: Self.legacySourcingKey) {
            UserDefaults.standard.set(oldData, forKey: Self.sourcingCategoryIdsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacySourcingKey)
        }
    }

    func load(month: String) {
        currentMonth = month

        // Load side hustle sources
        let allSources = IncomeSource.loadSaved()
        sources = allSources.filter { $0.type == .sideHustle }
        if selectedSourceId == nil, let first = sources.first {
            selectedSourceId = first.id
        }

        // Load income transactions for keyword matching
        do {
            incomeTransactions = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: month)
        } catch {
            incomeTransactions = []
        }
        sourceAssignments = IncomeSource.loadMappings()
        autoAssignUnmatched()

        // Load sourcing data
        loadSourcingCategoryIds()
        do {
            allCategories = try DatabaseManager.shared.fetchCategories()
            categorySourcingTransactions = try DatabaseManager.shared.fetchTransactionsForCategories(
                categoryIds: Array(sourcingCategoryIds), month: month
            )
            manualSourcingTransactions = try DatabaseManager.shared.fetchManualSourcingTransactions(forMonth: month)
            let manualLinks = try DatabaseManager.shared.fetchSourcingTransactions(forMonth: month)
            manualSourcingTransactionIds = Set(manualLinks.map(\.transactionId))
        } catch {
            categorySourcingTransactions = []
            manualSourcingTransactions = []
            manualSourcingTransactionIds = []
        }

        // Calculate sourcing totals
        let categoryTxnIds = Set(categorySourcingTransactions.map(\.id))
        let manualOnly = manualSourcingTransactions.filter { !categoryTxnIds.contains($0.id) }
        let categoryTotal = categorySourcingTransactions.reduce(0.0) { $0 + abs($1.amount) }
        let manualTotal = manualOnly.reduce(0.0) { $0 + abs($1.amount) }
        totalSourcingCosts = categoryTotal + manualTotal
        allSourcingTransactions = (categorySourcingTransactions + manualOnly).sorted { $0.date > $1.date }

        // Compute combined monthly totals
        computeMonthlyTotals(month: month)
        computeLifetimeTotals()
    }

    private func computeMonthlyTotals(month: String) {
        var sales = 0.0
        var costs = 0.0

        // eBay contribution
        if let summary = ebayViewModel.summary {
            sales += summary.totalSales
            costs += summary.totalFees + summary.totalCOGS + summary.totalShipping
        }

        // Generic side hustle income (keyword-matched)
        let sourceIds = Set(sources.filter { !$0.isEbay }.map(\.id))
        let genericIncome = incomeTransactions
            .filter { txn in
                guard let srcId = sourceAssignments[txn.id] else { return false }
                return sourceIds.contains(srcId)
            }
            .reduce(0.0) { $0 + $1.amount }
        sales += genericIncome

        // Sourcing costs (global)
        costs += totalSourcingCosts

        monthlySales = sales
        monthlyCosts = costs
        monthlyNetProfit = sales - costs
    }

    private func computeLifetimeTotals() {
        do {
            let ebayLifetime = try DatabaseManager.shared.fetchLifetimeEbaySummary()
            let lifetimeSourcingTotal = try DatabaseManager.shared.fetchLifetimeSourcingCosts(
                sourcingCategoryIds: Array(sourcingCategoryIds)
            )

            // eBay lifetime
            lifetimeSales = ebayLifetime.sales
            lifetimeCosts = ebayLifetime.fees + ebayLifetime.cogs + ebayLifetime.shipping

            // TODO: Add lifetime income from generic side hustles across all months

            // Sourcing (global lifetime)
            lifetimeCosts += lifetimeSourcingTotal
            lifetimeNetProfit = lifetimeSales - lifetimeCosts

            lifetimeSourcingTransactions = try DatabaseManager.shared.fetchAllSourcingTransactions(
                sourcingCategoryIds: Array(sourcingCategoryIds)
            )
        } catch {
            lifetimeSales = 0
            lifetimeCosts = 0
            lifetimeNetProfit = 0
            lifetimeSourcingTransactions = []
        }
    }

    // MARK: - Keyword Auto-Assignment

    private func autoAssignUnmatched() {
        var changed = false
        for txn in incomeTransactions {
            guard sourceAssignments[txn.id] == nil else { continue }
            for source in sources {
                let matched = source.keywords.contains { keyword in
                    txn.description.localizedCaseInsensitiveContains(keyword)
                }
                if matched {
                    sourceAssignments[txn.id] = source.id
                    changed = true
                    break
                }
            }
        }
        if changed {
            IncomeSource.saveMappings(sourceAssignments)
        }
    }

    // MARK: - Source for Transaction

    func transactions(for sourceId: UUID) -> [Transaction] {
        incomeTransactions.filter { sourceAssignments[$0.id] == sourceId }
    }

    func total(for sourceId: UUID) -> Double {
        let auto = transactions(for: sourceId).reduce(0) { $0 + $1.amount }
        let manual = manualIncomeTransactions(for: sourceId).filter { txn in
            sourceAssignments[txn.id] != sourceId // avoid double-counting auto-matched
        }.reduce(0) { $0 + $1.amount }
        return auto + manual
    }

    // MARK: - Manual Income Transactions

    private static let manualIncomeMappingsKey = "sideHustleManualIncomeMappings"

    /// Get manually linked income transactions for a source
    func manualIncomeTransactions(for sourceId: UUID) -> [Transaction] {
        let mappings = loadManualIncomeMappings()
        let txnIds = mappings.filter { $0.value == sourceId }.map(\.key)
        return incomeTransactions.filter { txnIds.contains($0.id) }
    }

    func addManualIncomeTransaction(_ transactionId: UUID, to sourceId: UUID) {
        var mappings = loadManualIncomeMappings()
        mappings[transactionId] = sourceId
        saveManualIncomeMappings(mappings)
        // Also add to source assignments so it shows in totals
        sourceAssignments[transactionId] = sourceId
        IncomeSource.saveMappings(sourceAssignments)
        load(month: currentMonth)
    }

    func removeManualIncomeTransaction(_ transactionId: UUID, from sourceId: UUID) {
        var mappings = loadManualIncomeMappings()
        mappings.removeValue(forKey: transactionId)
        saveManualIncomeMappings(mappings)
        // Also remove from source assignments if it was manually added
        if sourceAssignments[transactionId] == sourceId {
            sourceAssignments.removeValue(forKey: transactionId)
            IncomeSource.saveMappings(sourceAssignments)
        }
        load(month: currentMonth)
    }

    func isManualIncome(_ transactionId: UUID, for sourceId: UUID) -> Bool {
        let mappings = loadManualIncomeMappings()
        return mappings[transactionId] == sourceId
    }

    private func loadManualIncomeMappings() -> [UUID: UUID] {
        guard let data = UserDefaults.standard.data(forKey: Self.manualIncomeMappingsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var result: [UUID: UUID] = [:]
        for (txnKey, sourceKey) in dict {
            if let txnId = UUID(uuidString: txnKey), let sourceId = UUID(uuidString: sourceKey) {
                result[txnId] = sourceId
            }
        }
        return result
    }

    private func saveManualIncomeMappings(_ mappings: [UUID: UUID]) {
        var dict: [String: String] = [:]
        for (txnId, sourceId) in mappings {
            dict[txnId.uuidString] = sourceId.uuidString
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.manualIncomeMappingsKey)
        }
    }

    // MARK: - Side Hustle Management

    func addSideHustle(name: String, keywords: [String]) {
        var allSources = IncomeSource.loadSaved()
        let source = IncomeSource(name: name, keywords: keywords, isDefault: false, type: .sideHustle)
        allSources.append(source)
        IncomeSource.save(allSources)
        selectedSourceId = source.id
        load(month: currentMonth)
    }

    func deleteSideHustle(_ sourceId: UUID) {
        var allSources = IncomeSource.loadSaved()
        allSources.removeAll { $0.id == sourceId }
        IncomeSource.save(allSources)
        if selectedSourceId == sourceId {
            selectedSourceId = sources.first?.id
        }
        load(month: currentMonth)
    }

    // MARK: - Sourcing Categories

    private func loadSourcingCategoryIds() {
        guard let data = UserDefaults.standard.data(forKey: Self.sourcingCategoryIdsKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            sourcingCategoryIds = []
            return
        }
        sourcingCategoryIds = Set(ids.compactMap { UUID(uuidString: $0) })
    }

    private func saveSourcingCategoryIds() {
        let strings = sourcingCategoryIds.map(\.uuidString)
        if let data = try? JSONEncoder().encode(strings) {
            UserDefaults.standard.set(data, forKey: Self.sourcingCategoryIdsKey)
        }
    }

    func toggleSourcingCategory(_ categoryId: UUID) {
        if sourcingCategoryIds.contains(categoryId) {
            sourcingCategoryIds.remove(categoryId)
        } else {
            sourcingCategoryIds.insert(categoryId)
        }
        saveSourcingCategoryIds()
        load(month: currentMonth)
    }

    // MARK: - Manual Sourcing

    func addManualSourcingTransaction(_ transactionId: UUID) {
        do {
            let record = EbaySourcingTransaction(transactionId: transactionId, month: currentMonth)
            try DatabaseManager.shared.saveSourcingTransaction(record)
            load(month: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeManualSourcingTransaction(_ transactionId: UUID) {
        do {
            try DatabaseManager.shared.removeSourcingTransaction(transactionId: transactionId, month: currentMonth)
            load(month: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isManualSourcing(_ transactionId: UUID) -> Bool {
        manualSourcingTransactionIds.contains(transactionId)
    }
}
