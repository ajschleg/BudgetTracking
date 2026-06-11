import SwiftUI

struct SettingsView: View {
    @Bindable var aiViewModel: InsightsViewModel
    var ebayAuthManager: EbayAuthManager
    @Bindable var plaidManager: PlaidSyncManager
    @AppStorage("isIncomePageEnabled") private var isIncomePageEnabled = false
    @AppStorage("isEditingLocked") private var isEditingLocked = true
    @State private var ebayClientId: String = ""
    @State private var ebayClientSecret: String = ""
    @State private var ebayRuName: String = ""
    @AppStorage("plaidServerURL") private var plaidServerURL = "http://localhost:8080"
    /// Keychain-backed; @State copy here binds to the SecureField and
    /// is synced on change rather than on every keystroke writing to
    /// the Keychain (which would spam SecItemAdd).
    @State private var plaidAppToken: String = PlaidService.appToken
    @State private var isTestingConnection = false
    @State private var connectionTestResult: PlaidService.ConnectionTestResult?
    private var serverSync = ServerTransactionSync.shared
    @State private var showSeedConfirmation = false
    @State private var showResyncConfirmation = false
    @State private var seedRowCount = 0

    init(aiViewModel: InsightsViewModel, ebayAuthManager: EbayAuthManager, plaidManager: PlaidSyncManager) {
        self.aiViewModel = aiViewModel
        self.ebayAuthManager = ebayAuthManager
        self.plaidManager = plaidManager
    }

    /// Seed is gated on a green Test Connection so the upload can't be
    /// pointed at a server that will reject every batch.
    private var isConnectionVerified: Bool {
        if case .success = connectionTestResult { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Interface
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Income Page", isOn: $isIncomePageEnabled)

                        Text("Show the Income page in the sidebar with Employment and Side Hustle tabs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Lock Editing", isOn: $isEditingLocked)

                        Text("Prevents accidental changes to budgets, categories, and transaction assignments. Also toggleable from the toolbar lock icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } label: {
                    Label("Interface", systemImage: "sidebar.left")
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
                // MARK: - Plaid Server Configuration
                // Linking accounts, balances, and sync live on the
                // Accounts page now. This block retains only the
                // dev/ops config that operators set once and forget.
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text("Manage linked banks, balances, and sync on the **Accounts** page.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

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
                                .onChange(of: plaidAppToken) { _, newValue in
                                    // Persist to Keychain (OS-encrypted) rather
                                    // than UserDefaults (plaintext on disk).
                                    PlaidService.appToken = newValue
                                }

                            Text("Stored in the macOS Keychain. Required if your server has APP_AUTH_TOKEN set — blocks unauthorized callers on public (e.g. ngrok) URLs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                Task { await runConnectionTest() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isTestingConnection {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "bolt.horizontal.circle")
                                    }
                                    Text(isTestingConnection ? "Testing…" : "Test Connection")
                                }
                            }
                            .disabled(isTestingConnection)

                            if let result = connectionTestResult {
                                connectionResultView(result)
                            } else {
                                Text("Checks that the Server URL is reachable and the App Auth Token is accepted.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        // MARK: Server transaction sync (server-hub)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Server Transaction Sync")
                                .font(.headline)

                            if serverSync.isEnabled {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.icloud")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                    Text("Enabled — the server is the source of truth. Cursor at \(serverSync.cursor).")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    showResyncConfirmation = true
                                } label: {
                                    Label("Re-sync from server", systemImage: "arrow.counterclockwise.icloud")
                                }
                                .font(.caption)

                            } else {
                                Text("Upload this Mac's transaction history once; afterwards every device pulls the same books from the server and edits sync through it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let progress = serverSync.seedProgress {
                                    ProgressView(value: progress) {
                                        Text(serverSync.progress)
                                            .font(.caption)
                                    }
                                } else {
                                    Button {
                                        seedRowCount = (try? DatabaseManager.shared
                                            .fetchAllTransactionsIncludingDeleted().count) ?? 0
                                        showSeedConfirmation = true
                                    } label: {
                                        Label("Upload Local History to Server", systemImage: "icloud.and.arrow.up")
                                    }
                                    .disabled(!isConnectionVerified || serverSync.isSyncing)

                                    if !isConnectionVerified {
                                        Text("Run Test Connection successfully first.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let error = serverSync.errorMessage {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .confirmationDialog(
                            "Re-sync everything from the server?",
                            isPresented: $showResyncConfirmation
                        ) {
                            Button("Re-sync") {
                                ServerTransactionSync.shared.resetForFullResync()
                                ServerRecordSync.shared.resetForFullResync()
                                Task {
                                    _ = await ServerRecordSync.shared.pull()
                                    _ = await ServerTransactionSync.shared.pull()
                                    await ServerRecordSync.shared.push()
                                    await ServerTransactionSync.shared.push()
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Re-walks the full server feed and re-offers local data. Idempotent and safe — use after restoring a server backup or if this Mac ever looks out of sync.")
                        }
                        .confirmationDialog(
                            "Upload \(seedRowCount) transactions to the server?",
                            isPresented: $showSeedConfirmation
                        ) {
                            Button("Upload") {
                                Task { _ = await serverSync.seedAll() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("One-time migration. The upload is safe to re-run — the server skips anything it already has.")
                        }

                    }
                    .padding(8)
                } label: {
                    Label("Bank Connection", systemImage: "server.rack")
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
        }
    }

    // MARK: - Connection Test

    @MainActor
    private func runConnectionTest() async {
        isTestingConnection = true
        connectionTestResult = nil
        connectionTestResult = await PlaidService().testConnection()
        isTestingConnection = false
    }

    @ViewBuilder
    private func connectionResultView(_ result: PlaidService.ConnectionTestResult) -> some View {
        switch result {
        case .success(let env):
            connectionRow(
                "checkmark.circle.fill", .green,
                "Connected — \(env) server, token accepted."
            )
        case .unauthorized:
            connectionRow(
                "xmark.circle.fill", .orange,
                "Reached the server, but the App Auth Token was rejected. Make sure it matches APP_AUTH_TOKEN on the server."
            )
        case .unreachable:
            connectionRow(
                "xmark.circle.fill", .red,
                "Couldn't reach the server. Check the Server URL, that the server is running, and the network/firewall."
            )
        case .invalidURL:
            connectionRow(
                "exclamationmark.triangle.fill", .orange,
                "That Server URL isn't valid. Use a full URL like http://192.168.1.147:8080."
            )
        case .serverError(let message):
            connectionRow(
                "exclamationmark.triangle.fill", .orange,
                "Server error: \(message)"
            )
        }
    }

    private func connectionRow(_ systemImage: String, _ color: Color, _ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}
