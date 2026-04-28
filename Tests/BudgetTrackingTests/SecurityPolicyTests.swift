import XCTest
@testable import BudgetTracking

/// Tests that turn rules in `SECURITY_POLICY.md` into hard assertions.
/// When one of these starts failing, either:
///   (a) the policy is being violated and the change should be reverted,
///       or
///   (b) the policy itself was deliberately updated and the test
///       should be updated alongside the doc.
///
/// Section numbers in the comments below refer to `SECURITY_POLICY.md`.
final class SecurityPolicyTests: XCTestCase {

    // MARK: - §1 Secrets handling: Keychain account names are reverse-DNS

    /// Every Keychain account name created on the macOS app must be
    /// fully-qualified reverse-DNS so different apps under the same
    /// shared Apple team ID can't collide.
    func testKnownKeychainKeysAreReverseDNS() {
        let knownKeychainKeys = [
            "com.schlegel.BudgetTracking.plaidAppToken",
            "com.schlegel.BudgetTracking.claudeAPIKey",
        ]
        for key in knownKeychainKeys {
            XCTAssertTrue(
                key.hasPrefix("com.schlegel.BudgetTracking."),
                "Keychain key \"\(key)\" must start with reverse-DNS prefix per SECURITY_POLICY §1"
            )
            XCTAssertFalse(
                key.contains(" "),
                "Keychain key \"\(key)\" must not contain whitespace"
            )
            XCTAssertGreaterThan(
                key.split(separator: ".").count,
                3,
                "Keychain key \"\(key)\" must include at least 4 reverse-DNS segments"
            )
        }
    }

    /// Round-trip the KeychainStore API to confirm the abstraction
    /// works — the production KeychainStore is the only sanctioned
    /// home for these secrets per the policy. Cleans up after itself
    /// so a test run leaves no residue in the user's real keychain.
    func testKeychainStoreRoundTripsValuesUnderArbitraryKey() {
        let testKey = "com.schlegel.BudgetTracking.SecurityPolicyTests.transient"
        defer { KeychainStore.set(nil, forKey: testKey) }

        KeychainStore.set("hunter2", forKey: testKey)
        XCTAssertEqual(KeychainStore.get(forKey: testKey), "hunter2")

        KeychainStore.set(nil, forKey: testKey)
        XCTAssertNil(KeychainStore.get(forKey: testKey))
    }

    // MARK: - §7 WKWebView host whitelist

    /// SECURITY_POLICY §7: WKWebView navigation must whitelist hosts.
    /// The PlaidLinkWebView allows our local server (localhost /
    /// 127.0.0.1) plus Plaid's CDN (cdn.plaid.com plus any *.plaid.com
    /// subdomain). Everything else must be rejected by the in-WebView
    /// check (the navigation delegate then opens it in the system
    /// browser).
    func testWebViewAllowsLocalServerAndPlaidDomains() {
        XCTAssertTrue(PlaidLinkWebView.isHostAllowedInWebView("localhost"))
        XCTAssertTrue(PlaidLinkWebView.isHostAllowedInWebView("127.0.0.1"))
        XCTAssertTrue(PlaidLinkWebView.isHostAllowedInWebView("cdn.plaid.com"))
        XCTAssertTrue(PlaidLinkWebView.isHostAllowedInWebView("link.plaid.com"))
        XCTAssertTrue(PlaidLinkWebView.isHostAllowedInWebView("api.plaid.com"))
        XCTAssertTrue(PlaidLinkWebView.isHostAllowedInWebView("sandbox.plaid.com"))
    }

    func testWebViewRejectsUnrelatedHosts() {
        // Bank OAuth pages must NOT load inside the embedded WebView,
        // they must open in the system browser.
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView("chase.com"))
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView("oauth.chase.com"))
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView("evil.com"))
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView(""))
    }

    /// A host that ends with ".plaid.com" but is actually a different
    /// domain (like "evil.plaid.com.attacker.io") must be rejected.
    /// Suffix matching works here because hasSuffix(".plaid.com") only
    /// matches if the string actually ends there.
    func testWebViewSuffixMatchIsAnchoredToEndOfHost() {
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView("evil.plaid.com.attacker.io"))
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView("plaid.com.attacker.io"))
        XCTAssertFalse(PlaidLinkWebView.isHostAllowedInWebView("notplaid.com"))
    }

    // MARK: - §7 budgettracking:// URL scheme handler

    /// The App's `onOpenURL` only acts on the budgettracking:// scheme
    /// and only for the small allow-list of hosts (plaid-oauth,
    /// plaid-oauth-success, ebay). Anything else must resolve to
    /// .ignore — never propagate to a side-effect.
    func testRouteIgnoresWrongScheme() {
        XCTAssertEqual(AppURLRoute.route(URL(string: "https://example.com/plaid-oauth")!), .ignore)
        XCTAssertEqual(AppURLRoute.route(URL(string: "javascript://plaid-oauth")!), .ignore)
        XCTAssertEqual(AppURLRoute.route(URL(string: "file:///etc/passwd")!), .ignore)
    }

    func testRouteIgnoresUnknownHost() {
        XCTAssertEqual(AppURLRoute.route(URL(string: "budgettracking://wipe-everything")!), .ignore)
        XCTAssertEqual(AppURLRoute.route(URL(string: "budgettracking://settings")!), .ignore)
        XCTAssertEqual(AppURLRoute.route(URL(string: "budgettracking://random-host?x=1")!), .ignore)
    }

    func testRouteHonorsPlaidOAuthHostWithRedirectURIQuery() {
        let url = URL(string: "budgettracking://plaid-oauth?redirect_uri=https%3A%2F%2Fexample.com%2Fcallback")!
        switch AppURLRoute.route(url) {
        case .plaidOAuth(let redirectURI):
            XCTAssertEqual(redirectURI, "https://example.com/callback")
        default:
            XCTFail("expected .plaidOAuth, got something else")
        }
    }

    func testRoutePlaidOAuthIgnoresMissingRedirectURI() {
        // Without a redirect_uri the route should not advance — never
        // pass empty data into Plaid Link's OAuth completion mode.
        XCTAssertEqual(
            AppURLRoute.route(URL(string: "budgettracking://plaid-oauth")!),
            .ignore
        )
        XCTAssertEqual(
            AppURLRoute.route(URL(string: "budgettracking://plaid-oauth?redirect_uri=")!),
            .ignore
        )
    }

    func testRouteHonorsPlaidOAuthSuccessHost() {
        let url = URL(string: "budgettracking://plaid-oauth-success?item_id=abc&institution=Chase")!
        switch AppURLRoute.route(url) {
        case .plaidOAuthSuccess(let routedURL):
            XCTAssertEqual(routedURL, url)
        default:
            XCTFail("expected .plaidOAuthSuccess, got something else")
        }
    }

    func testRouteHonorsEbayHost() {
        let url = URL(string: "budgettracking://ebay?code=xyz")!
        switch AppURLRoute.route(url) {
        case .ebay(let routedURL):
            XCTAssertEqual(routedURL, url)
        default:
            XCTFail("expected .ebay, got something else")
        }
    }

    // MARK: - §10 What stays local: model encodings don't leak secrets

    /// SECURITY_POLICY §10: only transactions, budgets, categories, and
    /// learned rules are sent to iCloud. Model fields that get serialized
    /// must not include access tokens, API keys, or owner PII. This test
    /// gives a fast trip-wire if someone accidentally adds such a field.
    func testCloudKitSyncedModelsDoNotContainSecretFields() throws {
        let category = BudgetCategory(name: "Test", monthlyBudget: 100)
        let categoryEncoded = try JSONEncoder().encode(category)
        let categoryJSON = String(data: categoryEncoded, encoding: .utf8) ?? ""
        for forbidden in forbiddenFieldNames {
            XCTAssertFalse(
                categoryJSON.lowercased().contains(forbidden),
                "BudgetCategory must not encode field \"\(forbidden)\" — those secrets stay server-side per §10"
            )
        }

        let txn = Transaction(
            date: Date(),
            description: "Test",
            amount: -10,
            month: "2026-04",
            importedFileId: UUID()
        )
        let txnEncoded = try JSONEncoder().encode(txn)
        let txnJSON = String(data: txnEncoded, encoding: .utf8) ?? ""
        for forbidden in forbiddenFieldNames {
            XCTAssertFalse(
                txnJSON.lowercased().contains(forbidden),
                "Transaction must not encode field \"\(forbidden)\" — those secrets stay server-side per §10"
            )
        }
    }

    private let forbiddenFieldNames: [String] = [
        "access_token",
        "accesstoken",
        "api_key",
        "apikey",
        "secret",
        "password",
        "owner_email",
        "owner_phone",
        "ssn",
    ]
}
