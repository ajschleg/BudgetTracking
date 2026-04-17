import Foundation

actor PlaidService {

    private var baseURL: URL {
        let urlString = UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080"
        return URL(string: urlString)!
    }

    /// Shared secret between this app and the server. Sent as X-App-Token
    /// on every /api/* request so the server can reject unauthenticated
    /// callers hitting its public ngrok URL. Stored in UserDefaults for
    /// simplicity — swap for Keychain if this ever leaves a personal app.
    static var appToken: String {
        UserDefaults.standard.string(forKey: "plaidAppToken") ?? ""
    }

    // MARK: - Response Types

    struct LinkTokenResponse: Codable {
        let link_token: String
    }

    struct ExchangeResponse: Codable {
        let item_id: String
        let institution: String
        let accounts: [AccountResponse]
    }

    struct AccountResponse: Codable {
        let id: String
        let plaid_account_id: String
        let name: String?
        let official_name: String?
        let type: String?
        let subtype: String?
        let mask: String?
    }

    struct AccountsResponse: Codable {
        let accounts: [AccountListItem]
    }

    struct AccountListItem: Codable {
        let id: String
        let plaid_item_id: String
        let plaid_account_id: String
        let name: String?
        let official_name: String?
        let type: String?
        let subtype: String?
        let mask: String?
        let institution_name: String?
        let last_synced_at: String?
    }

    struct SyncResponse: Codable {
        let added: [PlaidTransaction]
        let modified: [PlaidTransaction]
        let removed: [RemovedTransaction]
    }

    struct PlaidTransaction: Codable {
        let transaction_id: String
        let account_id: String
        let item_id: String
        let institution_name: String?
        let name: String
        let merchant_name: String?
        let amount: Double // Plaid: positive = expense, negative = income
        let date: String // "2026-03-15"
        let pending: Bool
        let category: String?
        let category_detailed: String?
    }

    struct RemovedTransaction: Codable {
        let transaction_id: String
        let item_id: String
    }

    struct SuccessResponse: Codable {
        let success: Bool
    }

    // MARK: - Error Types

    enum PlaidServiceError: LocalizedError {
        case serverUnreachable
        case invalidResponse
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .serverUnreachable: return "Cannot connect to the Plaid server. Make sure it's running."
            case .invalidResponse: return "Invalid response from server."
            case .serverError(let message): return "Server error: \(message)"
            }
        }
    }

    // MARK: - API Methods

    func createLinkToken() async throws -> String {
        let response: LinkTokenResponse = try await post(path: "/api/link/create")
        return response.link_token
    }

    func exchangePublicToken(_ publicToken: String, institution: [String: String]?) async throws -> ExchangeResponse {
        var body: [String: Any] = ["public_token": publicToken]
        if let institution {
            body["institution"] = institution
        }
        return try await post(path: "/api/link/exchange", body: body)
    }

    /// Exchange token using institution metadata from the native iOS LinkKit SDK.
    /// Accepts the LinkKit institution type directly for cleaner iOS integration.
    func exchangeToken(publicToken: String, institution: (name: String, id: String)) async throws -> ExchangeResponse {
        let body: [String: Any] = [
            "public_token": publicToken,
            "institution": [
                "institution_id": institution.id,
                "name": institution.name,
            ],
        ]
        return try await post(path: "/api/link/exchange", body: body)
    }

    func syncTransactions() async throws -> SyncResponse {
        return try await post(path: "/api/transactions/sync")
    }

    func fetchAccounts() async throws -> [AccountListItem] {
        let response: AccountsResponse = try await get(path: "/api/accounts")
        return response.accounts
    }

    func removeItem(_ itemId: String) async throws {
        let _: SuccessResponse = try await delete(path: "/api/items/\(itemId)")
    }

    // MARK: - HTTP Helpers

    private func get<T: Codable>(path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuth(&request)
        return try await execute(request)
    }

    private func post<T: Codable>(path: String, body: [String: Any]? = nil) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuth(&request)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await execute(request)
    }

    private func delete<T: Codable>(path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuth(&request)
        return try await execute(request)
    }

    /// Attach the shared app token so the server accepts us.
    private func addAuth(_ request: inout URLRequest) {
        let token = PlaidService.appToken
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-App-Token")
        }
    }

    private func execute<T: Codable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PlaidServiceError.serverUnreachable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlaidServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorBody["error"] as? String {
                throw PlaidServiceError.serverError(message)
            }
            throw PlaidServiceError.serverError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlaidServiceError.invalidResponse
        }
    }
}
