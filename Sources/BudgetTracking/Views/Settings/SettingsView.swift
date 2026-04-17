import SwiftUI

struct SettingsView: View {
    @Bindable var aiViewModel: InsightsViewModel
    var ebayAuthManager: EbayAuthManager
    @Bindable var plaidManager: PlaidSyncManager
    @AppStorage("isIncomePageEnabled") private var isIncomePageEnabled = false
    @State private var ebayClientId: String = ""
    @State private var ebayClientSecret: String = ""
    @State private var ebayRuName: String = ""
    @AppStorage("plaidServerURL") private var plaidServerURL = "http://localhost:8080"
    @AppStorage("plaidAppToken") private var plaidAppToken = ""
    /// Tracks whether the user has seen and accepted the pre-Link
    /// consent screen. Persisted so we do not ask on every link attempt;
    /// reset to false if the user disconnects everything (the reset
    /// happens implicitly — linkedAccounts.isEmpty is the signal).
    @AppStorage("plaidConsentAcknowledged") private var plaidConsentAcknowledged = false
    @State private var isShowingConsent = false
    @State private var isLinkingAccount = false
    /// The institution currently in the "are you sure you want to
    /// disconnect?" confirmation dialog, or nil.
    @State private var pendingDisconnect: (institution: String, account: PlaidAccount)?
    @State private var showDisconnectAllConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Pages
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Income Page", isOn: $isIncomePageEnabled)

                        Text("Show the Income page in the sidebar with Employment and Side Hustle tabs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } label: {
                    Label("Pages", systemImage: "sidebar.left")
                }

                // MARK: - AI Configuration
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        // API Key
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Claude API Key")
                                .font(.headline)

                            SecureField("sk-ant-...", text: $aiViewModel.apiKey)
                                .textFieldStyle(.roundedBorder)

                            if aiViewModel.isAPIKeyConfigured {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                    Text("API key configured")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }

                            Text("Your API key is stored locally and only used to send aggregated spending data (category names and monthly totals) to Claude for analysis.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Text("Need an API key?")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Link("Get one at console.anthropic.com",
                                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                    .font(.caption)
                            }
                        }

                        Divider()

                        // Usage display
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Usage This Month")
                                    .font(.subheadline)
                                Spacer()
                                Text("$\(String(format: "%.2f", aiViewModel.monthlySpend))")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }

                            Text("Balance and credits are managed on the Anthropic console.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Link("Check balance & buy credits",
                                 destination: URL(string: "https://console.anthropic.com/settings/billing")!)
                                .font(.caption)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("AI Assistant", systemImage: "sparkles")
                }
                // MARK: - Plaid Bank Connection
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server URL")
                                .font(.headline)

                            TextField("http://localhost:8080", text: $plaidServerURL)
                                .textFieldStyle(.roundedBorder)

                            Text("The URL of your Plaid backend server.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("App Auth Token")
                                .font(.headline)

                            SecureField("Shared secret (matches APP_AUTH_TOKEN on the server)", text: $plaidAppToken)
                                .textFieldStyle(.roundedBorder)

                            Text("Required if your server has APP_AUTH_TOKEN set. Blocks unauthorized callers on public (e.g. ngrok) URLs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        // Linked accounts
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Linked Accounts")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    // Require consent acknowledgement before opening Plaid
                                    // Link. Once granted, subsequent links skip the consent
                                    // screen but the Privacy Policy link remains in the app.
                                    if plaidConsentAcknowledged {
                                        isLinkingAccount = true
                                    } else {
                                        isShowingConsent = true
                                    }
                                } label: {
                                    Label("Link Account", systemImage: "plus.circle")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            if plaidManager.linkedAccounts.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "building.columns")
                                        .foregroundStyle(.secondary)
                                    Text("No bank accounts linked. Click \"Link Account\" to connect your bank.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            } else {
                                // Group accounts by institution
                                let grouped = Dictionary(grouping: plaidManager.linkedAccounts) { $0.institutionName ?? "Unknown" }
                                ForEach(grouped.keys.sorted(), id: \.self) { institution in
                                    // Look up update-mode state for this institution's item
                                    let itemIdForInstitution = grouped[institution]?.first?.plaidItemId
                                    let needsUpdate = itemIdForInstitution.flatMap { plaidItemId in
                                        plaidManager.itemsNeedingUpdate.first(where: { $0.item_id == plaidItemId })
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "building.columns.fill")
                                                .foregroundStyle(.blue)
                                                .font(.caption)
                                            Text(institution)
                                                .font(.subheadline.weight(.medium))
                                            // Owner name from Plaid Identity (if available)
                                            if let owner = grouped[institution]?.compactMap(\.ownerName).first, !owner.isEmpty {
                                                Text("• \(owner)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if let needsUpdate {
                                                Button {
                                                    plaidManager.startUpdateMode(for: needsUpdate.id)
                                                } label: {
                                                    Label("Reconnect", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                                        .font(.caption)
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                                .tint(.orange)
                                            }
                                            Button {
                                                if let account = grouped[institution]?.first {
                                                    pendingDisconnect = (institution: institution, account: account)
                                                }
                                            } label: {
                                                Text("Disconnect")
                                                    .font(.caption)
                                                    .foregroundStyle(.red)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Unlink this bank and stop syncing")
                                        }
                                        if let needsUpdate {
                                            Text(updateReasonMessage(needsUpdate.needs_update_reason))
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                                .padding(.leading, 20)
                                        }

                                        ForEach(grouped[institution] ?? []) { account in
                                            HStack(spacing: 6) {
                                                Text(account.displayName)
                                                    .font(.caption)
                                                if let subtype = account.subtype {
                                                    Text(subtype.capitalized)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 1)
                                                        .background(Color.secondary.opacity(0.1))
                                                        .cornerRadius(3)
                                                }
                                                Spacer()
                                                if let current = account.balanceCurrent {
                                                    Text(CurrencyFormatter.format(current, code: account.balanceCurrencyCode))
                                                        .font(.caption.monospacedDigit())
                                                        .foregroundStyle(.primary)
                                                }
                                            }
                                            .padding(.leading, 20)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }

                            if plaidManager.isHistoricalBackfillInProgress {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                    Text("Plaid is still backfilling historical transactions. Older data will appear over the next few hours.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let error = plaidManager.errorMessage {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Divider()

                        // Action buttons
                        HStack(spacing: 12) {
                            if plaidManager.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                Text(plaidManager.syncProgress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button {
                                    Task { await plaidManager.syncTransactions() }
                                } label: {
                                    Label("Sync Transactions", systemImage: "arrow.clockwise")
                                }
                                .disabled(plaidManager.linkedAccounts.isEmpty)

                                if plaidManager.isRefreshingBalances {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Checking balances…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button {
                                        Task { await plaidManager.refreshBalances() }
                                    } label: {
                                        Label("Refresh Balances", systemImage: "dollarsign.arrow.circlepath")
                                    }
                                    .disabled(plaidManager.linkedAccounts.isEmpty)
                                }
                            }
                        }

                        // Offboarding: disconnect every linked bank at once.
                        // Does not touch transaction history — users can keep
                        // their data after unlinking Plaid.
                        if !plaidManager.linkedAccounts.isEmpty {
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Disconnect All Banks")
                                        .font(.caption.weight(.medium))
                                    Text("Revokes Plaid access and stops all syncing. Your existing transaction history stays.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    showDisconnectAllConfirmation = true
                                } label: {
                                    Text("Disconnect All")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Bank Connections (Plaid)", systemImage: "building.columns")
                }

                // MARK: - eBay Configuration
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("eBay Developer Credentials")
                                .font(.headline)

                            TextField("Client ID (App ID)", text: $ebayClientId)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: ebayClientId) { _, newValue in
                                    ebayAuthManager.clientId = newValue
                                }

                            SecureField("Client Secret (Cert ID)", text: $ebayClientSecret)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: ebayClientSecret) { _, newValue in
                                    ebayAuthManager.clientSecret = newValue
                                }

                            TextField("RuName (Redirect URL Name)", text: $ebayRuName)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: ebayRuName) { _, newValue in
                                    ebayAuthManager.ruName = newValue
                                }

                            if ebayAuthManager.isAuthenticated {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                    Text("Connected to eBay")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    Spacer()
                                    Button("Disconnect") {
                                        ebayAuthManager.disconnect()
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                }
                            }

                            Text("Credentials are stored securely in your Keychain. Get them from developer.ebay.com.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Toggle("Use eBay Sandbox", isOn: Binding(
                                get: { ebayAuthManager.useSandbox },
                                set: { ebayAuthManager.useSandbox = $0 }
                            ))
                            .font(.caption)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("eBay Integration", systemImage: "bag.fill")
                }
            }
            .padding(24)
        }
        .navigationTitle("Settings")
        .onAppear {
            ebayClientId = ebayAuthManager.clientId
            ebayClientSecret = ebayAuthManager.clientSecret
            ebayRuName = ebayAuthManager.ruName
            plaidManager.loadAccounts()
        }
        .sheet(isPresented: $isLinkingAccount) {
            PlaidLinkView(plaidManager: plaidManager, oauthRedirectURI: nil)
        }
        .sheet(isPresented: $isShowingConsent) {
            PlaidConsentView(onContinue: {
                plaidConsentAcknowledged = true
                isShowingConsent = false
                // Open the Link sheet on the next runloop so SwiftUI can
                // animate the consent sheet closed before the Link sheet
                // opens.
                DispatchQueue.main.async { isLinkingAccount = true }
            })
        }
        .confirmationDialog(
            "Disconnect \(pendingDisconnect?.institution ?? "bank")?",
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDisconnect
        ) { pending in
            Button("Disconnect", role: .destructive) {
                Task { await plaidManager.removeAccount(pending.account) }
                pendingDisconnect = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDisconnect = nil
            }
        } message: { pending in
            Text("This will revoke Plaid's access to \(pending.institution) and stop syncing new transactions. Your existing transaction history will not be deleted. You can reconnect later by clicking Link Account.")
        }
        .confirmationDialog(
            "Disconnect every linked bank?",
            isPresented: $showDisconnectAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect All", role: .destructive) {
                Task { await plaidManager.disconnectAllBanks() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will revoke Plaid's access to all linked banks and stop all syncing. Your existing transaction history will not be deleted.")
        }
    }

    /// Human-readable hint for the needs_update reason code Plaid sent.
    private func updateReasonMessage(_ reason: String?) -> String {
        switch reason {
        case "ITEM_LOGIN_REQUIRED":
            return "Your credentials for this bank have expired. Reconnect to resume syncing."
        case "PENDING_EXPIRATION":
            return "Consent will expire in under 7 days. Reconnect to avoid interruption."
        case "PENDING_DISCONNECT":
            return "This connection will soon be disconnected. Reconnect to keep it active."
        case "NEW_ACCOUNTS_AVAILABLE":
            return "New accounts are available. Reconnect to choose which to share."
        default:
            return "This connection needs attention. Please reconnect."
        }
    }
}
