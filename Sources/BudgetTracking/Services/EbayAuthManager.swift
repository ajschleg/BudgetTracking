import Foundation
import Security
import AppKit

@Observable
final class EbayAuthManager {

    var isAuthenticated: Bool = false
    var isAuthenticating: Bool = false
    var showingCodeEntry: Bool = false
    var errorMessage: String?

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    private let tokenEndpoint = URL(string: "https://api.ebay.com/identity/v1/oauth2/token")!
    private let sandboxTokenEndpoint = URL(string: "https://api.sandbox.ebay.com/identity/v1/oauth2/token")!
    private let authEndpoint = URL(string: "https://auth.ebay.com/oauth2/authorize")!
    private let sandboxAuthEndpoint = URL(string: "https://auth.sandbox.ebay.com/oauth2/authorize")!

    private let scope = "https://api.ebay.com/oauth/api_scope/sell.finances https://api.ebay.com/oauth/api_scope/sell.fulfillment"
    private let redirectScheme = "budgettracking"
    private let callbackPath = "/ebay/callback"

    // Keychain keys
    private let accessTokenKey = "com.schlegel.BudgetTracking.ebay.accessToken"
    private let refreshTokenKey = "com.schlegel.BudgetTracking.ebay.refreshToken"
    private let tokenExpiryKey = "com.schlegel.BudgetTracking.ebay.tokenExpiry"
    private let clientIdKey = "com.schlegel.BudgetTracking.ebay.clientId"
    private let clientSecretKey = "com.schlegel.BudgetTracking.ebay.clientSecret"
    private let ruNameKey = "com.schlegel.BudgetTracking.ebay.ruName"

    private var authState: String?

    var useSandbox: Bool {
        get { UserDefaults.standard.bool(forKey: "ebayUseSandbox") }
        set { UserDefaults.standard.set(newValue, forKey: "ebayUseSandbox") }
    }

    init() {
        loadTokensFromKeychain()
    }

    // MARK: - Credentials

    var clientId: String {
        get { readKeychain(key: clientIdKey) ?? "" }
        set { saveKeychain(key: clientIdKey, value: newValue) }
    }

    var clientSecret: String {
        get { readKeychain(key: clientSecretKey) ?? "" }
        set { saveKeychain(key: clientSecretKey, value: newValue) }
    }

    var ruName: String {
        get { readKeychain(key: ruNameKey) ?? "" }
        set { saveKeychain(key: ruNameKey, value: newValue) }
    }

    var hasCredentials: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty && !ruName.isEmpty
    }

    // MARK: - Auth Flow

    func startAuthFlow() {
        guard hasCredentials else {
            errorMessage = "Please enter your eBay API credentials in Settings first."
            return
        }

        isAuthenticating = true
        errorMessage = nil
        authState = UUID().uuidString

        let baseURL = useSandbox ? sandboxAuthEndpoint : authEndpoint
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: ruName),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: authState)
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
            showingCodeEntry = true
        }
    }

    /// Handle a manually pasted authorization code or full callback URL from the eBay consent page.
    func handleManualCode(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please paste a valid authorization code or URL."
            return
        }

        let code: String
        // Check if the user pasted a full URL containing a code parameter
        if trimmed.contains("code="),
           let components = URLComponents(string: trimmed),
           let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
            code = codeParam
        } else if trimmed.hasPrefix("http"), let url = URL(string: trimmed),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let codeParam = components.queryItems?.first(where: { $0.name == "code" })?.value {
            code = codeParam
        } else {
            // Assume it's a raw code
            code = trimmed
        }

        showingCodeEntry = false
        isAuthenticating = true
        errorMessage = nil
        Task {
            await exchangeCodeForTokens(code: code)
        }
    }

    func handleCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == callbackPath || url.absoluteString.contains("ebay/callback") else {
            return
        }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        // Verify state
        if let state = params["state"], state != authState {
            errorMessage = "Invalid auth state. Please try again."
            isAuthenticating = false
            return
        }

        guard let code = params["code"] else {
            errorMessage = params["error_description"] ?? params["error"] ?? "Authorization failed."
            isAuthenticating = false
            return
        }

        Task {
            await exchangeCodeForTokens(code: code)
        }
    }

    private func exchangeCodeForTokens(code: String) async {
        let tokenURL = useSandbox ? sandboxTokenEndpoint : tokenEndpoint

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientId):\(clientSecret)"
        let base64Credentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(ruName)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                await MainActor.run {
                    errorMessage = "Token exchange failed: \(body)"
                    isAuthenticating = false
                }
                return
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            await MainActor.run {
                accessToken = tokenResponse.access_token
                refreshToken = tokenResponse.refresh_token
                tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
                isAuthenticated = true
                isAuthenticating = false
                errorMessage = nil
                saveTokensToKeychain()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Token exchange error: \(error.localizedDescription)"
                isAuthenticating = false
            }
        }
    }

    // MARK: - Token Management

    func getAccessToken() async throws -> String {
        guard isAuthenticated else {
            throw EbayAPIService.EbayAPIError.notAuthenticated
        }

        // Refresh if expiring within 5 minutes
        if let expiry = tokenExpiry, expiry.timeIntervalSinceNow < 300 {
            try await refreshAccessToken()
        }

        guard let token = accessToken else {
            throw EbayAPIService.EbayAPIError.notAuthenticated
        }
        return token
    }

    func refreshAccessToken() async throws {
        guard let refreshToken else {
            await MainActor.run {
                isAuthenticated = false
                errorMessage = "No refresh token available. Please reconnect."
            }
            throw EbayAPIService.EbayAPIError.notAuthenticated
        }

        let tokenURL = useSandbox ? sandboxTokenEndpoint : tokenEndpoint
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientId):\(clientSecret)"
        let base64Credentials = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "scope=\(scope)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            await MainActor.run {
                isAuthenticated = false
                errorMessage = "Token refresh failed. Please reconnect."
            }
            throw EbayAPIService.EbayAPIError.tokenExpired
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        await MainActor.run {
            accessToken = tokenResponse.access_token
            if let newRefresh = tokenResponse.refresh_token {
                self.refreshToken = newRefresh
            }
            tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
            saveTokensToKeychain()
        }
    }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        isAuthenticated = false
        errorMessage = nil
        deleteKeychain(key: accessTokenKey)
        deleteKeychain(key: refreshTokenKey)
        deleteKeychain(key: tokenExpiryKey)
    }

    // MARK: - Token Response

    private struct TokenResponse: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let token_type: String?
    }

    // MARK: - Keychain

    private func saveTokensToKeychain() {
        if let accessToken {
            saveKeychain(key: accessTokenKey, value: accessToken)
        }
        if let refreshToken {
            saveKeychain(key: refreshTokenKey, value: refreshToken)
        }
        if let tokenExpiry {
            saveKeychain(key: tokenExpiryKey, value: "\(tokenExpiry.timeIntervalSince1970)")
        }
    }

    private func loadTokensFromKeychain() {
        accessToken = readKeychain(key: accessTokenKey)
        refreshToken = readKeychain(key: refreshTokenKey)
        if let expiryString = readKeychain(key: tokenExpiryKey),
           let interval = Double(expiryString) {
            tokenExpiry = Date(timeIntervalSince1970: interval)
        }
        isAuthenticated = accessToken != nil && refreshToken != nil
    }

    private func saveKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
