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
    @State private var isLinkingAccount = false

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

                        Divider()

                        // Linked accounts
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Linked Accounts")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    isLinkingAccount = true
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
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "building.columns.fill")
                                                .foregroundStyle(.blue)
                                                .font(.caption)
                                            Text(institution)
                                                .font(.subheadline.weight(.medium))
                                            Spacer()
                                            Button {
                                                if let account = grouped[institution]?.first {
                                                    Task { await plaidManager.removeAccount(account) }
                                                }
                                            } label: {
                                                Text("Remove")
                                                    .font(.caption)
                                                    .foregroundStyle(.red)
                                            }
                                            .buttonStyle(.plain)
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
                                            }
                                            .padding(.leading, 20)
                                        }
                                    }
                                    .padding(.vertical, 2)
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

                        // Sync button
                        HStack {
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
            PlaidLinkView(plaidManager: plaidManager)
        }
    }
}
