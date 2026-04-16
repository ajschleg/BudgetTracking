import SwiftUI
import WebKit

struct PlaidLinkView: View {
    @Bindable var plaidManager: PlaidSyncManager
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link Bank Account")
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
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    onSuccess: { dismiss() }
                )
                .overlay {
                    if isLoading {
                        ProgressView("Loading...")
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 600)
    }
}

struct PlaidLinkWebView: NSViewRepresentable {
    let plaidManager: PlaidSyncManager
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let onSuccess: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "plaidCallback")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        loadLinkPage(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func loadLinkPage(_ webView: WKWebView) {
        let serverURL = UserDefaults.standard.string(forKey: "plaidServerURL") ?? "http://localhost:8080"
        guard let url = URL(string: "\(serverURL)/link.html") else {
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

        // Handle messages from JavaScript
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
