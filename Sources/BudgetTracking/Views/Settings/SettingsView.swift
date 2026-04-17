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
    /// Keychain-backed; @State copy here binds to the SecureField and
    /// is synced on change rather than on every keystroke writing to
    /// the Keychain (which would spam SecItemAdd).
    @State private var plaidAppToken: String = PlaidService.appToken

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

                    }
                    .padding(8)
                } label: {
                    Label("Plaid Server", systemImage: "server.rack")
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
}
