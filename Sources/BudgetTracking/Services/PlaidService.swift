import Foundation

actor PlaidService {

    private var baseURL: URL {
        let urlString = UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080"
        return URL(string: urlString)!
    }

    /// Shared secret between this app and the server. Sent as X-App-Token
    /// on every /api/* request so the server can reject unauthenticated
    /// callers hitting its public ngrok URL. Stored in the macOS Keychain
    /// so it is OS-encrypted and survives app reinstalls.
    ///
    /// Migrates from the legacy UserDefaults location on first read so
    /// existing installs do not have to re-enter the token.
    static var appToken: String {
        get {
            if let keychain = KeychainStore.get(forKey: Self.appTokenKey) {
                return keychain
            }
            // Legacy migration: promote any value in UserDefaults into
            // the Keychain, then clear the plaintext copy.
            if let legacy = UserDefaults.standard.string(forKey: "plaidAppToken"),
               !legacy.isEmpty {
                KeychainStore.set(legacy, forKey: Self.appTokenKey)
                UserDefaults.standard.removeObject(forKey: "plaidAppToken")
                return legacy
            }
            return ""
        }
        set { KeychainStore.set(newValue, forKey: Self.appTokenKey) }
    }

    private static let appTokenKey = "com.schlegel.BudgetTracking.plaidAppToken"

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
        // Balance columns (nullable; populated by /balances/refresh)
        let balance_current: Double?
        let balance_available: Double?
        let balance_limit: Double?
        let balance_iso_currency_code: String?
        let balance_fetched_at: String?
        // Identity columns (nullable; populated on link or /identity/refresh)
        let owner_name: String?
        let owner_email: String?
        let owner_phone: String?
        let identity_fetched_at: String?
    }

    /// POST /api/transactions/sync triggers a server-side Plaid ingest
    /// and returns counts; rows arrive via /api/transactions/changes.
    struct SyncResponse: Codable {
        let ingested: IngestedCounts?
    }

    struct IngestedCounts: Codable {
        let added: Int
        let modified: Int
        let removed: Int
        let skipped: Int
    }



    // MARK: - Server Transaction Store (server-hub sync)

    /// One row from the server's transactions table — the source of truth.
    /// Amounts are already in the app's sign convention (negative = expense);
    /// the server negated Plaid's convention once at ingestion.
    struct ServerTransactionChange: Codable {
        let id: String
        let external_id: String?
        let account_id: String?
        let item_id: String?
        let date: String          // "YYYY-MM-DD"
        let month: String         // "YYYY-MM"
        let description: String
        let merchant: String?
        let amount: Double        // app sign convention
        let category_id: String?
        let is_manually_categorized: Bool
        let plaid_category: String?
        let plaid_category_detailed: String?
        let imported_file_id: String?
        let source: String        // plaid | import | manual
        let is_deleted: Bool
        let updated_at: String    // server ISO-8601 ms timestamp — LWW authority
        let change_seq: Int
    }

    struct ChangesResponse: Codable {
        let changes: [ServerTransactionChange]
        let next_seq: Int
        let has_more: Bool
    }

    /// Row shape for POST /api/transactions (seed, manual entries, imports).
    /// The server derives month from date and skips ids/external_ids it has
    /// already seen, so retries and overlapping seeds are always safe.
    struct ServerTransactionUpload: Codable {
        let id: String
        let date: String
        let description: String
        let merchant: String?
        let amount: Double
        let category_id: String?
        let is_manually_categorized: Bool
        let external_id: String?
        let imported_file_id: String?
        let source: String
        let is_deleted: Bool
    }

    struct CreateTransactionsResponse: Codable {
        let inserted: Int
        let skipped: Int
        let max_change_seq: Int
    }

    struct BatchPatchResponse: Codable {
        let updated: Int
        let not_found: [String]
    }

    // MARK: - Generic Record Store (Phase 3: categories/rules/snapshots/profiles/files)

    /// One row from the server's generic record feed. The payload is an
    /// opaque content-only JSON encoding of the Swift model (sync fields
    /// normalized out — see DatabaseManager+ServerRecords); updated_at is
    /// the LWW authority, exactly like transactions.
    struct RecordChange: Codable {
        let record_type: String
        let id: String
        let payload: String
        let is_deleted: Bool
        let updated_at: String
        let change_seq: Int
    }

    struct RecordChangesResponse: Codable {
        let changes: [RecordChange]
        let next_seq: Int
        let has_more: Bool
    }

    struct RecordUpload: Codable {
        let record_type: String
        let id: String
        let payload: String
        let is_deleted: Bool
    }

    struct RecordBulkResponse: Codable {
        let upserted: Int
        let skipped: Int
    }

    struct SuccessResponse: Codable {
        let success: Bool
    }

    // MARK: - Balance Response Types

    struct BalancesRefreshResponse: Codable {
        let refreshed: [RefreshedItem]
        let skipped: [SkippedItem]
        let errors: [BalanceError]
    }

    struct RefreshedItem: Codable {
        let item_id: String
        let institution_name: String?
        let accounts: [RefreshedAccount]
    }

    struct RefreshedAccount: Codable {
        let plaid_account_id: String
        let name: String?
        let type: String?
        let subtype: String?
        let mask: String?
        let balance_current: Double?
        let balance_available: Double?
        let balance_limit: Double?
        let balance_iso_currency_code: String?
    }

    struct SkippedItem: Codable {
        let item_id: String
        let reason: String
    }

    struct BalanceError: Codable {
        let item_id: String
        let institution_name: String?
        let error: String
    }

    // MARK: - Identity Response Types

    struct IdentityRefreshResponse: Codable {
        let refreshed: [RefreshedIdentityItem]
        let errors: [BalanceError]
    }

    struct RefreshedIdentityItem: Codable {
        let item_id: String
        let institution_name: String?
    }

    // MARK: - Transactions Status

    struct TransactionsStatusResponse: Codable {
        let items: [TransactionsStatusItem]
    }

    struct TransactionsStatusItem: Codable {
        let id: String
        let item_id: String
        let institution_name: String?
        let initial_update_complete: Bool
        let historical_update_complete: Bool
        let pending_update_available: Bool
        let last_synced_at: String?
    }

    // MARK: - Items (Update Mode)

    struct ItemsResponse: Codable {
        let items: [ItemSummary]
    }

    struct ItemSummary: Codable {
        let id: String
        let item_id: String
        let institution_id: String?
        let institution_name: String?
        let created_at: String?
        let needs_update: Bool
        let needs_update_reason: String?
        let needs_update_detected_at: String?
    }

    // MARK: - Error Types

    enum PlaidServiceError: LocalizedError {
        case serverUnreachable
        case invalidResponse
        case serverError(String)
        /// HTTP 429 from the server's rate limiter. Carries the parsed
        /// Retry-After (seconds) when the server sent one, so bulk flows
        /// (seed, push, pull) can back off and resume instead of failing.
        case rateLimited(retryAfter: TimeInterval?)

        var errorDescription: String? {
            switch self {
            case .serverUnreachable: return "Cannot connect to the Plaid server. Make sure it's running."
            case .invalidResponse: return "Invalid response from server."
            case .serverError(let message): return "Server error: \(message)"
            case .rateLimited: return "The server is rate-limiting requests — retrying shortly."
            }
        }
    }

    // MARK: - Connection Test

    /// Shape of the public `/health` payload. Per SECURITY_POLICY §3 the
    /// server promises this endpoint returns nothing beyond status + env.
    struct HealthResponse: Codable {
        let status: String
        let env: String
    }

    /// Outcome of the Settings → Plaid Server → Test Connection probe.
    /// Carries only non-sensitive diagnostics (server env, HTTP status) —
    /// never the token or any Plaid payload (SECURITY_POLICY §8).
    enum ConnectionTestResult: Equatable, Sendable {
        case success(env: String)   // reachable AND token accepted
        case unauthorized           // reachable but token rejected (401)
        case unreachable            // could not connect at all
        case invalidURL             // Server URL is empty / malformed
        case serverError(String)    // reached, non-2xx other than 401
    }

    /// Two-step health + auth probe for the Test Connection button.
    /// Step 1 hits the public `/health` endpoint to prove the Server URL
    /// is reachable and read the environment. Step 2 hits the
    /// token-gated `/api/transactions/status` to prove the App Auth Token
    /// is accepted. Never throws — every path maps to a result the UI can
    /// explain. Reads the same persisted Server URL + Keychain token the
    /// real API calls use, so a green result means real calls will work.
    func testConnection() async -> ConnectionTestResult {
        let urlString = (UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: urlString), base.scheme != nil, base.host != nil else {
            return .invalidURL
        }

        // Step 1 — reachability + environment (no auth required).
        let env: String
        do {
            var request = URLRequest(url: base.appendingPathComponent("/health"))
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            guard (200...299).contains(http.statusCode) else {
                return .serverError("health check returned HTTP \(http.statusCode)")
            }
            env = (try? JSONDecoder().decode(HealthResponse.self, from: data))?.env ?? "unknown"
        } catch {
            return .unreachable
        }

        // Step 2 — auth check against a read-only, token-gated endpoint.
        var request = URLRequest(url: base.appendingPathComponent("/api/transactions/status"))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = PlaidService.appToken
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-App-Token")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .serverError("invalid response") }
            switch http.statusCode {
            case 200...299: return .success(env: env)
            case 401:       return .unauthorized
            default:        return .serverError("HTTP \(http.statusCode)")
            }
        } catch {
            return .unreachable
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

    // MARK: - Server transaction store calls (server-hub sync)

    /// Pull one page of changes after `since`. Callers loop while
    /// `has_more`, persisting `next_seq` as their cursor after each page.
    func fetchTransactionChanges(since: Int, limit: Int = 500) async throws -> ChangesResponse {
        try await get(path: "/api/transactions/changes",
                      query: [URLQueryItem(name: "since", value: String(since)),
                              URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Idempotent bulk create (max 250 per call — the server's cap).
    func createTransactions(_ rows: [ServerTransactionUpload]) async throws -> CreateTransactionsResponse {
        try await postEncodable(path: "/api/transactions", body: ["transactions": rows])
    }

    /// Bulk field edits: [{id, patch}]. Patches are dictionaries so that
    /// JSON null (clear this field) is expressible — NSNull encodes as
    /// null, which Codable optionals cannot distinguish from "absent".
    func batchPatchTransactions(_ ops: [(id: String, patch: [String: Any])]) async throws -> BatchPatchResponse {
        let body: [String: Any] = [
            "ops": ops.map { ["id": $0.id, "patch": $0.patch] },
        ]
        return try await post(path: "/api/transactions/batch", body: body)
    }

    // MARK: - Generic record store calls

    func fetchRecordChanges(since: Int, limit: Int = 500) async throws -> RecordChangesResponse {
        try await get(path: "/api/records/changes",
                      query: [URLQueryItem(name: "since", value: String(since)),
                              URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Idempotent bulk upsert (max 250 per call — the server's cap).
    /// Byte-identical payloads are seq-silent server-side.
    func pushRecords(_ rows: [RecordUpload]) async throws -> RecordBulkResponse {
        try await postEncodable(path: "/api/records/bulk", body: ["records": rows])
    }

    func fetchAccounts() async throws -> [AccountListItem] {
        let response: AccountsResponse = try await get(path: "/api/accounts")
        return response.accounts
    }

    func removeItem(_ itemId: String) async throws {
        let _: SuccessResponse = try await delete(path: "/api/items/\(itemId)")
    }

    struct BulkRemoveResponse: Codable {
        let removed: [RefreshedIdentityItem]  // {item_id, institution_name}
        let errors: [BalanceError]
    }

    /// Disconnect EVERY linked institution. Used for user offboarding.
    /// Calls Plaid /item/remove per item then wipes local Plaid tables.
    /// Does not touch transaction history — users can keep their data
    /// even after unlinking banks.
    ///
    /// The ?confirm=DISCONNECT_ALL query flag is the server-side
    /// safety rail — a stray DELETE without it returns 400 instead of
    /// silently wiping every token.
    func removeAllItems() async throws -> BulkRemoveResponse {
        try await delete(path: "/api/items?confirm=DISCONNECT_ALL")
    }

    /// Fetch live balances from Plaid via the server's /balances/refresh.
    /// Each call bills for every item — surface it behind an explicit user
    /// action. `minAgeSeconds` lets the server skip items we just refreshed.
    func refreshBalances(itemId: String? = nil, minAgeSeconds: Int? = nil) async throws -> BalancesRefreshResponse {
        var body: [String: Any] = [:]
        if let itemId { body["item_id"] = itemId }
        if let minAgeSeconds { body["min_age_seconds"] = minAgeSeconds }
        return try await post(path: "/api/balances/refresh", body: body.isEmpty ? nil : body)
    }

    /// Refresh identity data from Plaid. Auto-called on link, so this is
    /// a manual fallback — for example if the user changes their address
    /// at the bank. Each call bills the one-time Identity fee per item.
    func refreshIdentity(itemId: String? = nil) async throws -> IdentityRefreshResponse {
        var body: [String: Any] = [:]
        if let itemId { body["item_id"] = itemId }
        return try await post(path: "/api/identity/refresh", body: body.isEmpty ? nil : body)
    }

    /// Cheap, read-only status of each item's sync lifecycle. Use this
    /// on app launch to decide whether to auto-sync (pending flag) or
    /// show "still backfilling..." (historical flag not yet set).
    func fetchTransactionsStatus() async throws -> TransactionsStatusResponse {
        try await get(path: "/api/transactions/status")
    }

    /// Per-item metadata including update-mode (needs_update) flags.
    /// Called on launch and after webhook-driven events to populate the
    /// "Reconnect" UI.
    func fetchItems() async throws -> ItemsResponse {
        try await get(path: "/api/items")
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

    /// GET with query items. appendingPathComponent percent-encodes "?",
    /// so query strings must go through URLComponents, never the path.
    private func get<T: Codable>(path: String, query: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw PlaidServiceError.invalidResponse
        }
        components.queryItems = query
        guard let url = components.url else { throw PlaidServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuth(&request)
        return try await execute(request)
    }

    /// POST with an Encodable body (arrays of typed rows), where the
    /// dictionary-based post() helper would force lossy [String: Any].
    private func postEncodable<Body: Encodable, T: Codable>(path: String, body: Body) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuth(&request)
        request.httpBody = try JSONEncoder().encode(body)
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
            if httpResponse.statusCode == 429 {
                // express-rate-limit sends RateLimit-Reset (seconds until
                // the window resets) with standardHeaders: true.
                let retryAfter = (httpResponse.value(forHTTPHeaderField: "Retry-After")
                                  ?? httpResponse.value(forHTTPHeaderField: "RateLimit-Reset"))
                    .flatMap(TimeInterval.init)
                throw PlaidServiceError.rateLimited(retryAfter: retryAfter)
            }
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
