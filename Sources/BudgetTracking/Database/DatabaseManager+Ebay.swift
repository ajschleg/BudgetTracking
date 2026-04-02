import Foundation
import GRDB

// MARK: - eBay Earnings Queries

extension DatabaseManager {

    // MARK: - Orders

    func fetchEbayOrders(forMonth month: String) throws -> [EbayOrder] {
        try dbQueue.read { db in
            try EbayOrder
                .filter(EbayOrder.Columns.month == month)
                .filter(EbayOrder.Columns.isDeleted == false)
                .order(EbayOrder.Columns.saleDate.desc)
                .fetchAll(db)
        }
    }

    func fetchEbayOrder(byEbayOrderId ebayOrderId: String) throws -> EbayOrder? {
        try dbQueue.read { db in
            try EbayOrder
                .filter(EbayOrder.Columns.ebayOrderId == ebayOrderId)
                .filter(EbayOrder.Columns.isDeleted == false)
                .fetchOne(db)
        }
    }

    func saveEbayOrders(_ orders: [EbayOrder]) throws {
        try dbQueue.write { db in
            for var order in orders {
                // Check if order with same ebayOrderId already exists
                if let existing = try EbayOrder
                    .filter(EbayOrder.Columns.ebayOrderId == order.ebayOrderId)
                    .fetchOne(db) {
                    order.id = existing.id // Reuse the existing UUID
                }
                order.lastModifiedAt = Date()
                try order.save(db)
            }
        }
        notifyDataChanged()
    }

    // MARK: - Fees

    func fetchEbayFees(forOrderId orderId: UUID) throws -> [EbayFee] {
        try dbQueue.read { db in
            try EbayFee
                .filter(EbayFee.Columns.ebayOrderId == orderId.uuidString)
                .filter(EbayFee.Columns.isDeleted == false)
                .fetchAll(db)
        }
    }

    func fetchTotalEbayFees(forMonth month: String) throws -> Double {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(f.amount), 0) AS total
                FROM ebayFee f
                JOIN ebayOrder o ON f.ebayOrderId = o.id
                WHERE o.month = ? AND o.isDeleted = 0 AND f.isDeleted = 0
                """, arguments: [month])
            return row?["total"] as? Double ?? 0
        }
    }

    func saveEbayFees(_ fees: [EbayFee]) throws {
        try dbQueue.write { db in
            for var fee in fees {
                // Check if this fee already exists for this order+type
                if let existing = try EbayFee
                    .filter(EbayFee.Columns.ebayOrderId == fee.ebayOrderId.uuidString)
                    .filter(EbayFee.Columns.feeType == fee.feeType)
                    .fetchOne(db) {
                    fee.id = existing.id
                }
                fee.lastModifiedAt = Date()
                try fee.save(db)
            }
        }
        notifyDataChanged()
    }

    // MARK: - Payouts

    func fetchEbayPayouts(forMonth month: String) throws -> [EbayPayout] {
        try dbQueue.read { db in
            try EbayPayout
                .filter(EbayPayout.Columns.month == month)
                .filter(EbayPayout.Columns.isDeleted == false)
                .order(EbayPayout.Columns.payoutDate.desc)
                .fetchAll(db)
        }
    }

    func saveEbayPayouts(_ payouts: [EbayPayout]) throws {
        try dbQueue.write { db in
            for var payout in payouts {
                if let existing = try EbayPayout
                    .filter(EbayPayout.Columns.ebayPayoutId == payout.ebayPayoutId)
                    .fetchOne(db) {
                    payout.id = existing.id
                    payout.matchedTransactionId = payout.matchedTransactionId ?? existing.matchedTransactionId
                }
                payout.lastModifiedAt = Date()
                try payout.save(db)
            }
        }
        notifyDataChanged()
    }

    func updatePayoutMatch(_ payoutId: UUID, matchedTransactionId: UUID?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE ebayPayout SET matchedTransactionId = ?, lastModifiedAt = ?
                    WHERE id = ?
                    """,
                arguments: [matchedTransactionId?.uuidString, Date(), payoutId.uuidString]
            )
        }
        notifyDataChanged()
    }

    // MARK: - Cost of Goods

    func fetchCostOfGoods(forOrderId orderId: UUID) throws -> EbayCostOfGoods? {
        try dbQueue.read { db in
            try EbayCostOfGoods
                .filter(EbayCostOfGoods.Columns.ebayOrderId == orderId.uuidString)
                .filter(EbayCostOfGoods.Columns.isDeleted == false)
                .fetchOne(db)
        }
    }

    func saveCostOfGoods(_ cogs: EbayCostOfGoods) throws {
        try dbQueue.write { db in
            var record = cogs
            record.lastModifiedAt = Date()
            try record.save(db)
        }
        notifyDataChanged()
    }

    // MARK: - Earnings Summary

    struct EbayEarningsSummary {
        var totalSales: Double = 0
        var totalFees: Double = 0
        var totalCOGS: Double = 0
        var totalShipping: Double = 0
        var totalSourcingCosts: Double = 0
        var payoutCount: Int = 0
        var matchedPayoutCount: Int = 0

        var netEarnings: Double {
            totalSales - totalFees - totalCOGS - totalShipping - totalSourcingCosts
        }

        var effectiveFeeRate: Double {
            guard totalSales > 0 else { return 0 }
            return totalFees / totalSales
        }
    }

    func fetchEbayEarningsSummary(forMonth month: String) throws -> EbayEarningsSummary {
        try dbQueue.read { db in
            var summary = EbayEarningsSummary()

            // Total sales
            let salesRow = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(saleAmount), 0) AS total
                FROM ebayOrder WHERE month = ? AND isDeleted = 0
                """, arguments: [month])
            summary.totalSales = salesRow?["total"] as? Double ?? 0

            // Total fees
            let feesRow = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(f.amount), 0) AS total
                FROM ebayFee f
                JOIN ebayOrder o ON f.ebayOrderId = o.id
                WHERE o.month = ? AND o.isDeleted = 0 AND f.isDeleted = 0
                """, arguments: [month])
            summary.totalFees = feesRow?["total"] as? Double ?? 0

            // Total COGS and shipping
            let cogsRow = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(c.costAmount), 0) AS totalCost,
                       COALESCE(SUM(c.shippingCost), 0) AS totalShipping
                FROM ebayCostOfGoods c
                JOIN ebayOrder o ON c.ebayOrderId = o.id
                WHERE o.month = ? AND o.isDeleted = 0 AND c.isDeleted = 0
                """, arguments: [month])
            summary.totalCOGS = cogsRow?["totalCost"] as? Double ?? 0
            summary.totalShipping = cogsRow?["totalShipping"] as? Double ?? 0

            // Payout counts
            let payoutRow = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN matchedTransactionId IS NOT NULL THEN 1 ELSE 0 END) AS matched
                FROM ebayPayout WHERE month = ? AND isDeleted = 0
                """, arguments: [month])
            summary.payoutCount = (payoutRow?["total"] as? Int) ?? 0
            summary.matchedPayoutCount = (payoutRow?["matched"] as? Int) ?? 0

            return summary
        }
    }

    // MARK: - Lifetime Summary

    struct LifetimeEbaySummary {
        var sales: Double = 0
        var fees: Double = 0
        var cogs: Double = 0
        var shipping: Double = 0
    }

    func fetchLifetimeEbaySummary() throws -> LifetimeEbaySummary {
        try dbQueue.read { db in
            var result = LifetimeEbaySummary()

            let salesRow = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(saleAmount), 0) AS total
                FROM ebayOrder WHERE isDeleted = 0
                """)
            result.sales = salesRow?["total"] as? Double ?? 0

            let feesRow = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(f.amount), 0) AS total
                FROM ebayFee f
                JOIN ebayOrder o ON f.ebayOrderId = o.id
                WHERE o.isDeleted = 0 AND f.isDeleted = 0
                """)
            result.fees = feesRow?["total"] as? Double ?? 0

            let cogsRow = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(c.costAmount), 0) AS totalCost,
                       COALESCE(SUM(c.shippingCost), 0) AS totalShipping
                FROM ebayCostOfGoods c
                JOIN ebayOrder o ON c.ebayOrderId = o.id
                WHERE o.isDeleted = 0 AND c.isDeleted = 0
                """)
            result.cogs = cogsRow?["totalCost"] as? Double ?? 0
            result.shipping = cogsRow?["totalShipping"] as? Double ?? 0

            return result
        }
    }

    /// Fetch lifetime sourcing costs across all months from sourcing categories + manual links.
    func fetchLifetimeSourcingCosts(sourcingCategoryIds: [UUID]) throws -> Double {
        var total = 0.0

        // Category-based sourcing (all time) — use GRDB query builder for correct UUID handling
        if !sourcingCategoryIds.isEmpty {
            let categoryTransactions = try dbQueue.read { db in
                try Transaction
                    .filter(sourcingCategoryIds.contains(Transaction.Columns.categoryId))
                    .filter(Transaction.Columns.amount < 0)
                    .filter(Transaction.Columns.isDeleted == false)
                    .fetchAll(db)
            }
            total += categoryTransactions.reduce(0.0) { $0 + abs($1.amount) }
        }

        // Manual sourcing (all time, excluding those already in category sourcing)
        let manualTransactions = try dbQueue.read { db in
            try Transaction.fetchAll(db, sql: """
                SELECT t.* FROM "transaction" t
                JOIN ebaySourcingTransaction s ON t.id = s.transactionId
                WHERE s.isDeleted = 0 AND t.isDeleted = 0
                """)
        }
        let categoryTxnIds = Set(
            sourcingCategoryIds.isEmpty ? [] :
            try dbQueue.read { db in
                try Transaction
                    .filter(sourcingCategoryIds.contains(Transaction.Columns.categoryId))
                    .filter(Transaction.Columns.amount < 0)
                    .filter(Transaction.Columns.isDeleted == false)
                    .fetchAll(db)
            }.map(\.id)
        )
        let manualOnly = manualTransactions.filter { !categoryTxnIds.contains($0.id) }
        total += manualOnly.reduce(0.0) { $0 + abs($1.amount) }

        return total
    }

    // MARK: - Sourcing Transactions

    /// Fetch all lifetime sourcing transactions (category-based + manual, deduplicated).
    func fetchAllSourcingTransactions(sourcingCategoryIds: [UUID]) throws -> [Transaction] {
        var all: [Transaction] = []
        var seenIds = Set<UUID>()

        // Category-based (all time)
        if !sourcingCategoryIds.isEmpty {
            let categoryTxns = try dbQueue.read { db in
                try Transaction
                    .filter(sourcingCategoryIds.contains(Transaction.Columns.categoryId))
                    .filter(Transaction.Columns.amount < 0)
                    .filter(Transaction.Columns.isDeleted == false)
                    .order(Transaction.Columns.date.desc)
                    .fetchAll(db)
            }
            for txn in categoryTxns {
                seenIds.insert(txn.id)
                all.append(txn)
            }
        }

        // Manual (all time)
        let manualTxns = try dbQueue.read { db in
            try Transaction.fetchAll(db, sql: """
                SELECT t.* FROM "transaction" t
                JOIN ebaySourcingTransaction s ON t.id = s.transactionId
                WHERE s.isDeleted = 0 AND t.isDeleted = 0
                ORDER BY t.date DESC
                """)
        }
        for txn in manualTxns where !seenIds.contains(txn.id) {
            all.append(txn)
        }

        return all.sorted { $0.date > $1.date }
    }

    /// Fetch all expense transactions for the given category IDs in a month.
    func fetchTransactionsForCategories(categoryIds: [UUID], month: String) throws -> [Transaction] {
        guard !categoryIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            return try Transaction
                .filter(categoryIds.contains(Transaction.Columns.categoryId))
                .filter(Transaction.Columns.month == month)
                .filter(Transaction.Columns.amount < 0)
                .filter(Transaction.Columns.isDeleted == false)
                .order(Transaction.Columns.date.desc)
                .fetchAll(db)
        }
    }

    /// Fetch all manually linked sourcing transaction records for a month.
    func fetchSourcingTransactions(forMonth month: String) throws -> [EbaySourcingTransaction] {
        try dbQueue.read { db in
            try EbaySourcingTransaction
                .filter(EbaySourcingTransaction.Columns.month == month)
                .filter(EbaySourcingTransaction.Columns.isDeleted == false)
                .fetchAll(db)
        }
    }

    /// Fetch the actual Transaction objects for manually linked sourcing entries.
    func fetchManualSourcingTransactions(forMonth month: String) throws -> [Transaction] {
        try dbQueue.read { db in
            try Transaction.fetchAll(db, sql: """
                SELECT t.* FROM "transaction" t
                JOIN ebaySourcingTransaction s ON t.id = s.transactionId
                WHERE s.month = ? AND s.isDeleted = 0 AND t.isDeleted = 0
                ORDER BY t.date DESC
                """, arguments: [month])
        }
    }

    /// Link a transaction as a manual sourcing cost.
    func saveSourcingTransaction(_ record: EbaySourcingTransaction) throws {
        try dbQueue.write { db in
            var r = record
            r.lastModifiedAt = Date()
            try r.save(db)
        }
        notifyDataChanged()
    }

    /// Remove a manual sourcing link by transaction ID.
    func removeSourcingTransaction(transactionId: UUID, month: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM ebaySourcingTransaction
                    WHERE transactionId = ? AND month = ?
                    """,
                arguments: [transactionId.uuidString, month]
            )
        }
        notifyDataChanged()
    }

    /// Check if a transaction is manually linked as sourcing.
    func isSourcingTransaction(transactionId: UUID) throws -> Bool {
        try dbQueue.read { db in
            let count = try EbaySourcingTransaction
                .filter(EbaySourcingTransaction.Columns.transactionId == transactionId.uuidString)
                .filter(EbaySourcingTransaction.Columns.isDeleted == false)
                .fetchCount(db)
            return count > 0
        }
    }

    // MARK: - Payout Matching

    func findMatchingBankTransaction(
        amount: Double,
        approximateDate: Date,
        dateTolerance: TimeInterval = 3 * 24 * 3600,
        amountTolerance: Double = 0.01
    ) throws -> Transaction? {
        try dbQueue.read { db in
            let minDate = approximateDate.addingTimeInterval(-dateTolerance)
            let maxDate = approximateDate.addingTimeInterval(dateTolerance)
            let minAmount = amount - amountTolerance
            let maxAmount = amount + amountTolerance

            return try Transaction
                .filter(sql: """
                    amount > 0
                    AND amount BETWEEN ? AND ?
                    AND date BETWEEN ? AND ?
                    AND isDeleted = 0
                    AND (UPPER(description) LIKE '%EBAY%'
                         OR UPPER(description) LIKE '%EB *%'
                         OR UPPER(description) LIKE '%EBAY INC%'
                         OR UPPER(description) LIKE '%EBAY COMMERCE%')
                    """, arguments: [minAmount, maxAmount, minDate, maxDate])
                .order(sql: "ABS(julianday(date) - julianday(?)) ASC", arguments: [approximateDate])
                .fetchOne(db)
        }
    }
}
