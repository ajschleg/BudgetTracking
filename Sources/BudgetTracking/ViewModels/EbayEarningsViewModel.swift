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
            summary = try DatabaseManager.shared.fetchEbayEarningsSummary(forMonth: month)
            orders = try DatabaseManager.shared.fetchEbayOrders(forMonth: month)
            payouts = try DatabaseManager.shared.fetchEbayPayouts(forMonth: month)

            // Load fees and COGS for each order
            orderFees = [:]
            orderCOGS = [:]
            for order in orders {
                orderFees[order.id] = try DatabaseManager.shared.fetchEbayFees(forOrderId: order.id)
                orderCOGS[order.id] = try DatabaseManager.shared.fetchCostOfGoods(forOrderId: order.id)
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
