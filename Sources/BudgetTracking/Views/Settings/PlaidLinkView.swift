import SwiftUI
import WebKit

struct PlaidLinkView: View {
    @Bindable var plaidManager: PlaidSyncManager
    var oauthRedirectURI: String?
    /// When set, opens Link in update mode for this existing item
    /// instead of starting a fresh link flow.
    var updateItemId: String?
    /// When true and updateItemId is set, opens Link with the account
    /// picker so the user can add newly-discovered accounts.
    var updateAccountSelection: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var title: String {
        if updateItemId != nil { return "Reconnect Bank Account" }
        if oauthRedirectURI != nil { return "Completing Connection" }
        return "Link Bank Account"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        errorMessage = nil
                        isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(40)
            } else {
                PlaidLinkWebView(
                    plaidManager: plaidManager,
                    oauthRedirectURI: oauthRedirectURI,
                    updateItemId: updateItemId,
                    updateAccountSelection: updateAccountSelection,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    onSuccess: { dismiss() }
                )
                .overlay {
                    if isLoading {
                        ProgressView(oauthRedirectURI != nil ? "Completing connection..." : "Loading...")
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
}

struct PlaidLinkWebView: NSViewRepresentable {
    let plaidManager: PlaidSyncManager
    let oauthRedirectURI: String?
    let updateItemId: String?
    let updateAccountSelection: Bool
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let onSuccess: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "plaidCallback")

        // NOTE: do NOT enable allowFileAccessFromFileURLs here. Loading
        // file:// from within remote-loaded HTML would let a compromised
        // page read local files. We load exclusively from our own
        // http(s) origins and the cdn.plaid.com domain.

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        if let oauthURI = oauthRedirectURI {
            // OAuth completion mode: load oauth.html with the received redirect URI
            loadOAuthCompletionPage(webView, receivedRedirectURI: oauthURI)
        } else if let itemId = updateItemId {
            // Update mode: load update.html for an existing item
            loadUpdatePage(webView, itemId: itemId, accountSelection: updateAccountSelection)
        } else {
            // Normal mode: load link.html to start a new Link flow
            loadLinkPage(webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func loadLinkPage(_ webView: WKWebView) {
        let serverURL = UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080"
        let token = tokenQuery()
        guard let url = URL(string: "\(serverURL)/link.html\(token)") else {
            errorMessage = "Invalid server URL"
            return
        }
        webView.load(URLRequest(url: url))
    }

    private func loadOAuthCompletionPage(_ webView: WKWebView, receivedRedirectURI: String) {
        let serverURL = UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080"
        let encoded = receivedRedirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? receivedRedirectURI
        var query = "?receivedRedirectUri=\(encoded)"
        let tokenValue = PlaidService.appToken
        if !tokenValue.isEmpty,
           let escaped = tokenValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&token=\(escaped)"
        }
        guard let url = URL(string: "\(serverURL)/oauth.html\(query)") else {
            errorMessage = "Invalid server URL"
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Produce a `?token=...` query string (or empty string) for the Link
    /// HTML pages so they can forward the app token to /api/* calls.
    private func tokenQuery() -> String {
        let token = PlaidService.appToken
        guard !token.isEmpty,
              let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return "" }
        return "?token=\(escaped)"
    }

    private func loadUpdatePage(_ webView: WKWebView, itemId: String, accountSelection: Bool) {
        let serverURL = UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080"
        var components = URLComponents(string: "\(serverURL)/update.html")
        var items = [URLQueryItem(name: "item_id", value: itemId)]
        let token = PlaidService.appToken
        if !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        if accountSelection {
            items.append(URLQueryItem(name: "account_selection", value: "true"))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            errorMessage = "Invalid server URL"
            return
        }
        webView.load(URLRequest(url: url))
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: PlaidLinkWebView

        init(_ parent: PlaidLinkWebView) {
            self.parent = parent
        }

        // MARK: - Navigation Policy (OAuth redirect handling)

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let host = url.host else {
                decisionHandler(.allow)
                return
            }

            // Allow our local server and Plaid CDN
            let allowedHosts = ["localhost", "127.0.0.1", "cdn.plaid.com"]
            let isPlaidDomain = host.hasSuffix(".plaid.com")
            let isAllowed = allowedHosts.contains(host) || isPlaidDomain

            if isAllowed {
                decisionHandler(.allow)
            } else {
                // External URL (bank OAuth page) — open in system browser
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // MARK: - Script Message Handler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "plaidCallback",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = json["event"] as? String else { return }

            Task { @MainActor in
                switch event {
                case "success":
                    if let resultData = json["data"] as? [String: Any] {
                        handleSuccess(resultData)
                    }
                case "exit":
                    let error = json["error"] as? String
                    if let error {
                        parent.errorMessage = error
                    } else {
                        parent.onSuccess() // User dismissed Link without error
                    }
                default:
                    break
                }
            }
        }

        private func handleSuccess(_ data: [String: Any]) {
            // Update mode returns { item_id, mode: "update" } — the
            // existing access_token is unchanged, the server already
            // cleared the needs_update flag via /items/:id/clear-update,
            // so there's nothing to persist here. Just dismiss and
            // let finishUpdateMode() refresh the banner state.
            if (data["mode"] as? String) == "update" {
                parent.onSuccess()
                return
            }

            // Normal link flow: persist the newly linked accounts.
            guard let itemId = data["item_id"] as? String,
                  let institution = data["institution"] as? String else { return }

            var accounts: [PlaidService.AccountResponse] = []
            if let accountDicts = data["accounts"] as? [[String: Any]] {
                for dict in accountDicts {
                    if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                       let account = try? JSONDecoder().decode(PlaidService.AccountResponse.self, from: jsonData) {
                        accounts.append(account)
                    }
                }
            }

            parent.plaidManager.handleLinkSuccess(
                itemId: itemId,
                institution: institution,
                accounts: accounts
            )
            parent.onSuccess()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.errorMessage = "Failed to load: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.errorMessage = "Cannot connect to server. Make sure it's running."
        }
    }
}
