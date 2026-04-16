#if canImport(LinkKit)
import SwiftUI
import LinkKit

/// Native Plaid Link integration for iOS using the LinkKit SDK.
/// Uses the native Plaid Link UI instead of WKWebView for a better mobile experience.
struct PlaidLinkNativeView: View {
    @Bindable var plaidManager: PlaidSyncManager
    var oauthRedirectURI: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var handler: Handler?

    var body: some View {
        NavigationStack {
            Group {
                if let error = errorMessage {
                    errorView(error)
                } else if isLoading {
                    ProgressView(oauthRedirectURI != nil ? "Completing connection..." : "Connecting to Plaid...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Handler opens as a modal, this is just a placeholder
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(oauthRedirectURI != nil ? "Completing Connection" : "Link Bank Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await initializePlaidLink()
        }
    }

    // MARK: - Error View

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
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
                Task { await initializePlaidLink() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    // MARK: - Plaid Link Initialization

    private func initializePlaidLink() async {
        do {
            let linkToken = try await plaidManager.createLinkToken()
            await createHandler(linkToken: linkToken)
        } catch {
            errorMessage = "Failed to create link token: \(error.localizedDescription)"
            isLoading = false
        }
    }

    @MainActor
    private func createHandler(linkToken: String) {
        var configuration = LinkTokenConfiguration(
            token: linkToken,
            onSuccess: { linkSuccess in
                handleSuccess(linkSuccess)
            }
        )

        configuration.onExit = { linkExit in
            handleExit(linkExit)
        }

        configuration.onEvent = { linkEvent in
            handleEvent(linkEvent)
        }

        // If completing an OAuth flow, pass the received redirect URI
        // Note: For OAuth completion, the link token must have been created
        // with the same redirect_uri that the bank redirected to.

        let result = Plaid.create(configuration)

        switch result {
        case .success(let linkHandler):
            self.handler = linkHandler
            isLoading = false
            // Present Plaid Link
            linkHandler.open(presentUsing: .default)

        case .failure(let error):
            errorMessage = "Failed to initialize Plaid Link: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - Callbacks

    private func handleSuccess(_ success: LinkSuccess) {
        let publicToken = success.publicToken
        let institutionName = success.metadata.institution.name
        let institutionID = success.metadata.institution.id

        // Exchange the public token via the backend
        Task {
            do {
                let plaidService = PlaidService()
                let response = try await plaidService.exchangeToken(
                    publicToken: publicToken,
                    institution: (name: institutionName, id: institutionID)
                )

                plaidManager.handleLinkSuccess(
                    itemId: response.item_id,
                    institution: response.institution,
                    accounts: response.accounts
                )

                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to connect account: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleExit(_ exit: LinkExit) {
        if let error = exit.error {
            errorMessage = error.displayMessage ?? error.errorMessage
        } else {
            // User exited without error
            dismiss()
        }
    }

    private func handleEvent(_ event: LinkEvent) {
        // Log events for debugging/analytics
        print("[PlaidLink] Event: \(event.eventName), metadata: \(event.metadata.description)")
    }
}

// MARK: - Universal Link Handler for iOS OAuth

extension PlaidLinkNativeView {
    /// Call this when the app receives a universal link OAuth redirect.
    /// The handler must still be retained from the initial Link session.
    static func handleUniversalLink(_ url: URL, handler: Handler?) {
        // The Plaid iOS SDK handles OAuth redirects automatically
        // when universal links are properly configured. The SDK
        // intercepts the redirect and resumes the Link flow.
        //
        // Ensure the Handler is retained throughout the OAuth flow
        // for this to work correctly.
        print("[PlaidLink] Received universal link: \(url)")
    }
}
#endif
