import SwiftUI

/// iOS Settings tab: sync status, reset action, app version. Future
/// PRs will expand this with eBay credential pad-through and Plaid
/// backend host configuration.
struct SettingsView: View {
    let syncEngine: SyncEngine
    let lanSyncEngine: LANSyncEngine

    @State private var showResetConfirm = false
    @State private var resetMessage: String?
    /// Toast-style banner shown briefly after asking the Mac to refresh
    /// from Plaid. The actual sync runs on the Mac and the new
    /// transactions arrive via the regular LAN sync push, so the iOS
    /// side has nothing to wait on synchronously - just enough feedback
    /// to confirm the request went out.
    @State private var plaidRefreshFeedback: String?

    private var iCloudStatusText: String {
        switch syncEngine.status {
        case .idle: return "Synced"
        case .syncing: return "Syncing…"
        case .error(let msg): return "Error: \(msg)"
        case .noAccount: return "Not signed in"
        }
    }

    private var iCloudStatusColor: Color {
        switch syncEngine.status {
        case .idle: return .green
        case .syncing: return .blue
        case .error: return .red
        case .noAccount: return .secondary
        }
    }

    private var lanStatusText: String {
        switch lanSyncEngine.status {
        case .disabled: return "Disabled"
        case .searching: return "Searching for peer…"
        case .connected(let name): return "Connected to \(name)"
        case .syncing(let name): return "Syncing with \(name)…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var lanStatusColor: Color {
        switch lanSyncEngine.status {
        case .disabled: return .secondary
        case .searching: return .orange
        case .connected: return .green
        case .syncing: return .blue
        case .error: return .red
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud sync") {
                    HStack {
                        Image(systemName: syncEngine.status == .idle ? "icloud.fill" : "icloud")
                            .foregroundStyle(iCloudStatusColor)
                        Text(iCloudStatusText)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Image(systemName: lanSyncEngine.status == .disabled ? "wifi.slash" : "wifi")
                            .foregroundStyle(lanStatusColor)
                        Text(lanStatusText)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Enable LAN sync", isOn: Binding(
                        get: { lanSyncEngine.isEnabled },
                        set: { lanSyncEngine.isEnabled = $0 }
                    ))
                    Button {
                        lanSyncEngine.syncNow()
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(lanSyncEngine.connectedPeerName == nil)
                } header: {
                    Text("LAN sync")
                } footer: {
                    Text("Discovers your Mac on the same Wi-Fi and pulls categories, budgets, and transactions over the local network.")
                }

                Section {
                    Button {
                        requestPlaidRefresh()
                    } label: {
                        Label("Refresh from Plaid", systemImage: "arrow.clockwise.icloud")
                    }
                    .disabled(lanSyncEngine.connectedPeerName == nil)
                    if let plaidRefreshFeedback {
                        Text(plaidRefreshFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Plaid")
                } footer: {
                    Text("Asks your Mac to fetch the latest bank transactions from Plaid. The new transactions sync back to this iPhone over LAN once the Mac finishes — usually a few seconds. Requires the Mac app to be open and on the same Wi-Fi.")
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
                    Text("Wipes all categories, budgets, transactions, and rules from this iPhone, then re-syncs from your Mac. Your Mac's data is untouched. Use this if iOS data ever drifts out of sync — for example, duplicate categories appearing.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                }
            }
            .navigationTitle("Settings")
            .alert("Reset local data?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { performReset() }
            } message: {
                Text("This will wipe all local data on this iPhone. Your Mac is unaffected. The iPhone will re-pull everything from your Mac on the next sync.")
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

    private func performReset() {
        do {
            try DatabaseManager.shared.wipeAllLocalData()
            lanSyncEngine.resetSyncState()
            // Trigger an immediate full re-sync if we still have a peer.
            lanSyncEngine.syncNow()
            resetMessage = "Local data cleared. The Dashboard, Transactions, and Budget tabs will repopulate as your Mac syncs."
        } catch {
            resetMessage = "Reset failed: \(error.localizedDescription)"
        }
    }

    private func requestPlaidRefresh() {
        let sent = lanSyncEngine.requestPlaidRefresh(initiatorNote: "iPhone Settings tab")
        if sent {
            plaidRefreshFeedback = "Sent — your Mac is fetching new transactions. They'll appear here shortly."
        } else {
            plaidRefreshFeedback = "No Mac peer connected. Open BudgetTracking on your Mac and try again."
        }
        // Auto-clear the toast after 4 seconds.
        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { plaidRefreshFeedback = nil }
        }
    }
}
