import SwiftUI

/// iOS Settings tab: server connection (the iPhone is a pure client of
/// the user's Plaid server — same URL + token as the Mac), Plaid actions,
/// local-data reset, app version.
struct SettingsView: View {
    @AppStorage("plaidServerURL") private var plaidServerURL = ""
    @State private var plaidAppToken: String = PlaidService.appToken
    @State private var isTestingConnection = false
    @State private var connectionTestResult: PlaidService.ConnectionTestResult?

    @State private var showResetConfirm = false
    @State private var resetMessage: String?
    @State private var plaidRefreshFeedback: String?
    @State private var showLinkSheet = false

    private var serverConfigured: Bool {
        if case .success = connectionTestResult { return true }
        return UserDefaults.standard.bool(forKey: ServerTransactionSync.enabledKey)
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-mini.tailnet-name.ts.net", text: $plaidServerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("App auth token", text: $plaidAppToken)
                        .onChange(of: plaidAppToken) { _, newValue in
                            PlaidService.appToken = newValue
                        }
                    Button {
                        Task {
                            isTestingConnection = true
                            connectionTestResult = await PlaidService().testConnection()
                            isTestingConnection = false
                            if case .success = connectionTestResult {
                                // The server is the source of truth — flip
                                // sync on and pull everything.
                                UserDefaults.standard.set(true, forKey: ServerTransactionSync.enabledKey)
                                await ServerRecordSync.shared.syncIfNeeded()
                                _ = await ServerTransactionSync.shared.pull()
                            }
                        }
                    } label: {
                        if isTestingConnection {
                            ProgressView()
                        } else {
                            Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    if let result = connectionTestResult {
                        connectionResultRow(result)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The same Server URL and App Auth Token as your Mac (Settings → Plaid Server). A successful test enables sync and pulls your budgets, categories, and transactions to this iPhone.")
                }

                Section {
                    Button {
                        showLinkSheet = true
                    } label: {
                        Label("Link bank account…", systemImage: "building.columns")
                    }
                    .disabled(!serverConfigured)

                    Button {
                        requestPlaidRefresh()
                    } label: {
                        Label("Refresh from Plaid", systemImage: "arrow.clockwise.icloud")
                    }
                    .disabled(!serverConfigured)
                    if let plaidRefreshFeedback {
                        Text(plaidRefreshFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Plaid")
                } footer: {
                    Text("Link a new bank from this iPhone or pull the latest transactions. Both talk straight to your server — the Mac app does not need to be open.")
                }

                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Reset local data", systemImage: "trash")
                    }
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("Wipes all categories, budgets, transactions, and rules from this iPhone, then re-pulls everything from the server. The server's data is untouched.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLinkSheet) {
                PlaidLinkSheet()
            }
            .alert("Reset local data?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { performReset() }
            } message: {
                Text("This will wipe all local data on this iPhone and re-pull everything from your server.")
            }
            .alert("Reset complete", isPresented: Binding(
                get: { resetMessage != nil },
                set: { if !$0 { resetMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(resetMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func connectionResultRow(_ result: PlaidService.ConnectionTestResult) -> some View {
        switch result {
        case .success(let env):
            Label("Connected (\(env)) — sync enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .unauthorized:
            Label("Server reachable, but the token was rejected", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.caption)
        case .unreachable:
            Label("Cannot reach the server (check the URL and your tailnet)", systemImage: "wifi.slash")
                .foregroundStyle(.red).font(.caption)
        case .invalidURL:
            Label("Invalid server URL", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        case .serverError(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        }
    }

    private func performReset() {
        do {
            try DatabaseManager.shared.wipeAllLocalData()
            // Rewind both pull cursors so the next sync re-walks the full
            // server feeds (idempotent, LWW).
            UserDefaults.standard.set(0, forKey: ServerTransactionSync.cursorKey)
            UserDefaults.standard.set(0, forKey: ServerRecordSync.cursorKey)
            Task {
                _ = await ServerRecordSync.shared.pull()
                _ = await ServerTransactionSync.shared.pull()
            }
            resetMessage = "Local data cleared. The tabs will repopulate from the server momentarily."
        } catch {
            resetMessage = "Reset failed: \(error.localizedDescription)"
        }
    }

    private func requestPlaidRefresh() {
        plaidRefreshFeedback = "Asking the server to ingest from Plaid…"
        Task {
            do {
                _ = try await PlaidService().syncTransactions()
                _ = await ServerTransactionSync.shared.pull()
                await MainActor.run {
                    plaidRefreshFeedback = "Done — new transactions (if any) are in."
                }
            } catch {
                await MainActor.run {
                    plaidRefreshFeedback = "Refresh failed: \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { plaidRefreshFeedback = nil }
        }
    }
}
