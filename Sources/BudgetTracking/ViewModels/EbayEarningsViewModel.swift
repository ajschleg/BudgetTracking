import Foundation
import SwiftUI

@Observable
final class EbayEarningsViewModel {
    var summary: DatabaseManager.EbayEarningsSummary?
    var orders: [EbayOrder] = []
    var orderFees: [UUID: [EbayFee]] = [:]
    var orderCOGS: [UUID: EbayCostOfGoods] = [:]
    var payouts: [EbayPayout] = []

    var isLoading = false
    var isSyncing = false
    var syncProgress: String = ""
    var errorMessage: String?

    var expandedOrderId: UUID?
    var editingCOGSOrderId: UUID?

    // Lifetime
    var lifetimeNetProfit: Double = 0
    var lifetimeSales: Double = 0
    var lifetimeCosts: Double = 0
    var lifetimeSourcingTransactions: [Transaction] = []

    // Sourcing
    var sourcingCategoryIds: Set<UUID> = []
    var categorySourcingTransactions: [Transaction] = []
    var manualSourcingTransactions: [Transaction] = []
    var manualSourcingTransactionIds: Set<UUID> = []
    var totalSourcingCosts: Double = 0
    var allCategories: [BudgetCategory] = []

    // Sheets
    var isManagingSourcingCategories = false
    var isAddingSourcingTransaction = false

    private static let sourcingCategoryIdsKey = "ebaySourcingCategoryIds"

    enum Period: String, CaseIterable {
        case monthly = "Monthly"
        case quarterly = "Quarterly"
        case yearly = "Yearly"
    }
    var selectedPeriod: Period = .monthly

    private var currentMonth: String = ""

    func load(month: String) {
        currentMonth = month
        isLoading = true
        defer { isLoading = false }

        do {
            orders = try DatabaseManager.shared.fetchEbayOrders(forMonth: month)
        } catch {
            orders = []
            errorMessage = "Failed loading orders: \(error)"
            return
        }

        do {
            payouts = try DatabaseManager.shared.fetchEbayPayouts(forMonth: month)
        } catch {
            payouts = []
            errorMessage = "Failed loading payouts: \(error)"
            return
        }

        // Load fees and COGS for each order
        orderFees = [:]
        orderCOGS = [:]
        for order in orders {
            orderFees[order.id] = (try? DatabaseManager.shared.fetchEbayFees(forOrderId: order.id)) ?? []
            orderCOGS[order.id] = try? DatabaseManager.shared.fetchCostOfGoods(forOrderId: order.id)
        }

        // Load sourcing data
        loadSourcingCategoryIds()
        do {
            allCategories = try DatabaseManager.shared.fetchCategories()
        } catch {
            allCategories = []
            errorMessage = "Failed loading categories: \(error)"
            return
        }

        do {
            categorySourcingTransactions = try DatabaseManager.shared.fetchTransactionsForCategories(
                categoryIds: Array(sourcingCategoryIds), month: month
            )
        } catch {
            categorySourcingTransactions = []
            errorMessage = "Failed loading sourcing transactions: \(error)"
            return
        }

        do {
            manualSourcingTransactions = try DatabaseManager.shared.fetchManualSourcingTransactions(forMonth: month)
            let manualLinks = try DatabaseManager.shared.fetchSourcingTransactions(forMonth: month)
            manualSourcingTransactionIds = Set(manualLinks.map(\.transactionId))
        } catch {
            manualSourcingTransactions = []
            manualSourcingTransactionIds = []
            errorMessage = "Failed loading manual sourcing: \(error)"
            return
        }

        // Calculate total sourcing (category-based + manual, avoid double-counting)
        let categoryTxnIds = Set(categorySourcingTransactions.map(\.id))
        let manualOnly = manualSourcingTransactions.filter { !categoryTxnIds.contains($0.id) }
        let categoryTotal = categorySourcingTransactions.reduce(0.0) { $0 + abs($1.amount) }
        let manualTotal = manualOnly.reduce(0.0) { $0 + abs($1.amount) }
        totalSourcingCosts = categoryTotal + manualTotal

        // Load summary and inject sourcing costs
        do {
            summary = try DatabaseManager.shared.fetchEbayEarningsSummary(forMonth: month)
            summary?.totalSourcingCosts = totalSourcingCosts
        } catch {
            summary = nil
            errorMessage = "Failed loading summary: \(error)"
            return
        }

        // Load lifetime profit
        do {
            let lifetimeData = try DatabaseManager.shared.fetchLifetimeEbaySummary()
            let lifetimeSourcingTotal = try DatabaseManager.shared.fetchLifetimeSourcingCosts(
                sourcingCategoryIds: Array(sourcingCategoryIds)
            )
            lifetimeSales = lifetimeData.sales
            lifetimeCosts = lifetimeData.fees + lifetimeData.cogs + lifetimeData.shipping + lifetimeSourcingTotal
            lifetimeNetProfit = lifetimeSales - lifetimeCosts
            lifetimeSourcingTransactions = try DatabaseManager.shared.fetchAllSourcingTransactions(
                sourcingCategoryIds: Array(sourcingCategoryIds)
            )
        } catch {
            lifetimeSales = 0
            lifetimeCosts = 0
            lifetimeNetProfit = 0
        }

        errorMessage = nil
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

    func addSourcingCategory(_ categoryId: UUID) {
        sourcingCategoryIds.insert(categoryId)
        saveSourcingCategoryIds()
        load(month: currentMonth)
    }

    func removeSourcingCategory(_ categoryId: UUID) {
        sourcingCategoryIds.remove(categoryId)
        saveSourcingCategoryIds()
        load(month: currentMonth)
    }

    func toggleSourcingCategory(_ categoryId: UUID) {
        if sourcingCategoryIds.contains(categoryId) {
            removeSourcingCategory(categoryId)
        } else {
            addSourcingCategory(categoryId)
        }
    }

    // MARK: - Manual Sourcing Transactions

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

    /// All sourcing transactions combined (category + manual, deduplicated)
    var allSourcingTransactions: [Transaction] {
        let categoryTxnIds = Set(categorySourcingTransactions.map(\.id))
        let manualOnly = manualSourcingTransactions.filter { !categoryTxnIds.contains($0.id) }
        return (categorySourcingTransactions + manualOnly).sorted { $0.date > $1.date }
    }

    func totalFees(for orderId: UUID) -> Double {
        (orderFees[orderId] ?? []).reduce(0) { $0 + $1.amount }
    }

    func netProfit(for order: EbayOrder) -> Double {
        let fees = totalFees(for: order.id)
        let cogs = orderCOGS[order.id]
        let costAmount = cogs?.costAmount ?? 0
        let shippingCost = cogs?.shippingCost ?? 0
        return order.saleAmount - fees - costAmount - shippingCost
    }

    // MARK: - Payout Matching

    func autoMatchPayouts() {
        do {
            let unmatched = payouts.filter { $0.matchedTransactionId == nil }
            for payout in unmatched {
                // Try exact match first (within $0.01, 3 days)
                if let match = try DatabaseManager.shared.findMatchingBankTransaction(
                    amount: payout.amount,
                    approximateDate: payout.payoutDate,
                    dateTolerance: 3 * 24 * 3600,
                    amountTolerance: 0.01
                ) {
                    // Make sure this transaction isn't already matched to another payout
                    let alreadyMatched = payouts.contains { $0.matchedTransactionId == match.id }
                    if !alreadyMatched {
                        try DatabaseManager.shared.updatePayoutMatch(payout.id, matchedTransactionId: match.id)
                    }
                } else if let match = try DatabaseManager.shared.findMatchingBankTransaction(
                    amount: payout.amount,
                    approximateDate: payout.payoutDate,
                    dateTolerance: 5 * 24 * 3600,
                    amountTolerance: 0.50
                ) {
                    let alreadyMatched = payouts.contains { $0.matchedTransactionId == match.id }
                    if !alreadyMatched {
                        try DatabaseManager.shared.updatePayoutMatch(payout.id, matchedTransactionId: match.id)
                    }
                }
            }
            // Reload payouts to reflect matches
            payouts = try DatabaseManager.shared.fetchEbayPayouts(forMonth: currentMonth)
            summary = try DatabaseManager.shared.fetchEbayEarningsSummary(forMonth: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func manuallyMatchPayout(_ payoutId: UUID, to transactionId: UUID) {
        do {
            try DatabaseManager.shared.updatePayoutMatch(payoutId, matchedTransactionId: transactionId)
            payouts = try DatabaseManager.shared.fetchEbayPayouts(forMonth: currentMonth)
            summary = try DatabaseManager.shared.fetchEbayEarningsSummary(forMonth: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmatchPayout(_ payoutId: UUID) {
        do {
            try DatabaseManager.shared.updatePayoutMatch(payoutId, matchedTransactionId: nil)
            payouts = try DatabaseManager.shared.fetchEbayPayouts(forMonth: currentMonth)
            summary = try DatabaseManager.shared.fetchEbayEarningsSummary(forMonth: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - COGS

    func saveCOGS(for orderId: UUID, costAmount: Double, shippingCost: Double, notes: String?) {
        do {
            var cogs = orderCOGS[orderId] ?? EbayCostOfGoods(ebayOrderId: orderId)
            cogs.costAmount = costAmount
            cogs.shippingCost = shippingCost
            cogs.notes = notes
            try DatabaseManager.shared.saveCostOfGoods(cogs)
            orderCOGS[orderId] = cogs
            // Refresh summary
            summary = try DatabaseManager.shared.fetchEbayEarningsSummary(forMonth: currentMonth)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
