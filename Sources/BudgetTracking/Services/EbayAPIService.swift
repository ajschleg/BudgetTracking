import Foundation

actor EbayAPIService {

    private let baseURL = URL(string: "https://apiz.ebay.com/sell/finances/v1")!
    private let sandboxBaseURL = URL(string: "https://apiz.sandbox.ebay.com/sell/finances/v1")!

    var useSandbox: Bool = false

    private var effectiveBaseURL: URL {
        useSandbox ? sandboxBaseURL : baseURL
    }

    // MARK: - Error Types

    enum EbayAPIError: LocalizedError {
        case notAuthenticated
        case tokenExpired
        case invalidResponse
        case httpError(statusCode: Int, body: String)
        case rateLimited
        case apiError(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not authenticated with eBay. Please connect your account."
            case .tokenExpired: return "eBay session expired. Please reconnect your account."
            case .invalidResponse: return "Invalid response from eBay API."
            case .httpError(let code, let body): return "eBay API error (\(code)): \(body)"
            case .rateLimited: return "eBay API rate limit reached. Please try again later."
            case .apiError(_, let message): return "eBay error: \(message)"
            }
        }
    }

    // MARK: - Response Types

    struct TransactionsResponse: Codable {
        let transactions: [EbayAPITransaction]?
        let total: Int?
        let limit: Int?
        let offset: Int?
    }

    struct EbayAPITransaction: Codable {
        let transactionId: String?
        let transactionType: String?
        let orderId: String?
        let transactionDate: String?
        let amount: Amount?
        let totalFeeBasisAmount: Amount?
        let totalFeeAmount: Amount?
        let orderLineItems: [OrderLineItem]?
        let buyer: Buyer?
        let paymentsEntity: String?
    }

    struct OrderLineItem: Codable {
        let lineItemId: String?
        let title: String?
        let quantity: Int?
        let purchaseQuantity: Int?
        let fees: [Fee]?
        let itemId: String?
    }

    struct Fee: Codable {
        let feeType: String?
        let amount: Amount?
        let feeMemo: String?
    }

    struct Amount: Codable {
        let value: String?
        let currency: String?
        let convertedFromValue: String?
        let convertedFromCurrency: String?

        var doubleValue: Double {
            guard let value else { return 0 }
            return Double(value) ?? 0
        }
    }

    struct Buyer: Codable {
        let username: String?
    }

    struct PayoutsResponse: Codable {
        let payouts: [EbayAPIPayout]?
        let total: Int?
        let limit: Int?
        let offset: Int?
    }

    struct EbayAPIPayout: Codable {
        let payoutId: String?
        let payoutDate: String?
        let amount: Amount?
        let payoutStatus: String?
        let payoutInstrument: PayoutInstrument?
    }

    struct PayoutInstrument: Codable {
        let instrumentType: String?
        let nickname: String?
        let accountLastFourDigits: String?
    }

    struct FundsSummary: Codable {
        let totalAvailable: Amount?
        let processingAmount: Amount?
        let onHoldAmount: Amount?
    }

    struct FundsSummaryResponse: Codable {
        let fundsSummary: FundsSummary?
    }

    // MARK: - API Methods

    func getTransactions(
        accessToken: String,
        startDate: Date,
        endDate: Date,
        transactionType: String? = nil,
        offset: Int = 0,
        limit: Int = 200
    ) async throws -> TransactionsResponse {
        var url = effectiveBaseURL.appendingPathComponent("transaction")
        var queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        let dateFilter = buildDateFilter(startDate: startDate, endDate: endDate)
        queryItems.append(URLQueryItem(name: "filter", value: "transactionDate:\(dateFilter)"))

        if let transactionType {
            queryItems.append(URLQueryItem(name: "filter", value: "transactionType:{\(transactionType)}"))
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        url = components.url!

        return try await makeRequest(url: url, accessToken: accessToken)
    }

    func getAllTransactions(
        accessToken: String,
        startDate: Date,
        endDate: Date,
        transactionType: String? = nil
    ) async throws -> [EbayAPITransaction] {
        var all: [EbayAPITransaction] = []
        var offset = 0
        let limit = 200

        while true {
            let response = try await getTransactions(
                accessToken: accessToken,
                startDate: startDate,
                endDate: endDate,
                transactionType: transactionType,
                offset: offset,
                limit: limit
            )
            let transactions = response.transactions ?? []
            all.append(contentsOf: transactions)

            let total = response.total ?? 0
            offset += limit
            if offset >= total || transactions.isEmpty {
                break
            }
        }
        return all
    }

    func getPayouts(
        accessToken: String,
        startDate: Date,
        endDate: Date,
        offset: Int = 0,
        limit: Int = 200
    ) async throws -> PayoutsResponse {
        var url = effectiveBaseURL.appendingPathComponent("payout")
        var queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        let dateFilter = buildDateFilter(startDate: startDate, endDate: endDate)
        queryItems.append(URLQueryItem(name: "filter", value: "payoutDate:\(dateFilter)"))

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        url = components.url!

        return try await makeRequest(url: url, accessToken: accessToken)
    }

    func getAllPayouts(
        accessToken: String,
        startDate: Date,
        endDate: Date
    ) async throws -> [EbayAPIPayout] {
        var all: [EbayAPIPayout] = []
        var offset = 0
        let limit = 200

        while true {
            let response = try await getPayouts(
                accessToken: accessToken,
                startDate: startDate,
                endDate: endDate,
                offset: offset,
                limit: limit
            )
            let payouts = response.payouts ?? []
            all.append(contentsOf: payouts)

            let total = response.total ?? 0
            offset += limit
            if offset >= total || payouts.isEmpty {
                break
            }
        }
        return all
    }

    func getSellerFundsSummary(accessToken: String) async throws -> FundsSummary {
        let url = effectiveBaseURL.appendingPathComponent("seller_funds_summary")
        let response: FundsSummaryResponse = try await makeRequest(url: url, accessToken: accessToken)
        guard let summary = response.fundsSummary else {
            throw EbayAPIError.invalidResponse
        }
        return summary
    }

    // MARK: - Fulfillment API (for item titles)

    private let fulfillmentBaseURL = URL(string: "https://api.ebay.com/sell/fulfillment/v1")!
    private let sandboxFulfillmentBaseURL = URL(string: "https://api.sandbox.ebay.com/sell/fulfillment/v1")!

    private var effectiveFulfillmentBaseURL: URL {
        useSandbox ? sandboxFulfillmentBaseURL : fulfillmentBaseURL
    }

    struct FulfillmentOrderResponse: Codable {
        let orderId: String?
        let lineItems: [FulfillmentLineItem]?
    }

    struct FulfillmentLineItem: Codable {
        let lineItemId: String?
        let title: String?
        let quantity: Int?
        let lineItemCost: Amount?
        let legacyItemId: String?
        let sku: String?
    }

    /// Fetch order details from the Fulfillment API to get item titles.
    func getOrder(accessToken: String, orderId: String) async throws -> FulfillmentOrderResponse {
        let url = effectiveFulfillmentBaseURL.appendingPathComponent("order/\(orderId)")
        return try await makeRequest(url: url, accessToken: accessToken)
    }

    /// Fetch item titles for a batch of order IDs. Returns a map of orderId -> [title].
    func fetchItemTitles(accessToken: String, orderIds: [String]) async -> [String: [String]] {
        var result: [String: [String]] = [:]
        for orderId in orderIds {
            do {
                let order = try await getOrder(accessToken: accessToken, orderId: orderId)
                let titles = order.lineItems?.compactMap { $0.title } ?? []
                result[orderId] = titles
            } catch {
                // Skip orders we can't fetch — keep "Unknown Item" for those
                continue
            }
        }
        return result
    }

    // MARK: - Helpers

    private func makeRequest<T: Codable>(url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EbayAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        case 401:
            throw EbayAPIError.tokenExpired
        case 429:
            throw EbayAPIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw EbayAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func buildDateFilter(startDate: Date, endDate: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = formatter.string(from: startDate)
        let end = formatter.string(from: endDate)
        return "[\(start)..\(end)]"
    }

    // MARK: - Date Parsing

    static func parseEbayDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        // Fallback without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}
