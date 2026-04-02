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
        var payoutCount: Int = 0
        var matchedPayoutCount: Int = 0

        var netEarnings: Double {
            totalSales - totalFees - totalCOGS - totalShipping
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
