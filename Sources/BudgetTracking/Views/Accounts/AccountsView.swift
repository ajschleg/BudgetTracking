import SwiftUI

/// Accounts page: where users manage Plaid-linked banks. File-based
/// imports live on the separate Imports page.
struct AccountsView: View {
    @Bindable var aiViewModel: InsightsViewModel
    @Bindable var plaidManager: PlaidSyncManager

    /// Pre-Link consent state (mirrors the old Settings behavior).
    @AppStorage("plaidConsentAcknowledged") private var plaidConsentAcknowledged = false
    @State private var isShowingConsent = false
    @State private var isLinkingAccount = false
    @State private var pendingDisconnect: (institution: String, account: PlaidAccount)?
    @State private var showDisconnectAllConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                plaidSection
            }
            .padding(24)
        }
        .navigationTitle("Accounts")
        .onAppear {
            plaidManager.loadAccounts()
        }
        // Regular link flow
        .sheet(isPresented: $isLinkingAccount) {
            PlaidLinkView(plaidManager: plaidManager, oauthRedirectURI: nil)
        }
        // Pre-link consent
        .sheet(isPresented: $isShowingConsent) {
            PlaidConsentView(onContinue: {
                plaidConsentAcknowledged = true
                isShowingConsent = false
                DispatchQueue.main.async { isLinkingAccount = true }
            })
        }
        // Per-institution disconnect confirmation
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
            Text("This will revoke Plaid's access to \(pending.institution) and stop syncing new transactions. Your existing transaction history will not be deleted. You can reconnect later.")
        }
        // Disconnect-all confirmation
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

    // MARK: - Connected Banks (Plaid)

    private var plaidSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                linkedAccountsHeader
                linkedAccountsBody
                if plaidManager.isHistoricalBackfillInProgress {
                    backfillHint
                }
                if let error = plaidManager.errorMessage {
                    errorHint(error)
                }
                Divider()
                actionButtons
                if !plaidManager.linkedAccounts.isEmpty {
                    Divider()
                    disconnectAllRow
                }
            }
            .padding(8)
        } label: {
            Label("Connected Banks (Plaid)", systemImage: "building.columns")
        }
    }

    private var linkedAccountsHeader: some View {
        HStack {
            Text("Linked Accounts")
                .font(.headline)
            Spacer()
            Button {
                // Enforce one-time consent before opening Plaid Link.
                if plaidConsentAcknowledged {
                    isLinkingAccount = true
                } else {
                    isShowingConsent = true
                }
            } label: {
                Label("Link Bank Account", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var linkedAccountsBody: some View {
        if plaidManager.linkedAccounts.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "building.columns")
                    .foregroundStyle(.secondary)
                Text("No bank accounts linked. Click \"Link Bank Account\" to connect your first bank.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            let grouped = Dictionary(grouping: plaidManager.linkedAccounts) { $0.institutionName ?? "Unknown" }
            ForEach(grouped.keys.sorted(), id: \.self) { institution in
                institutionBlock(institution: institution, accounts: grouped[institution] ?? [])
            }
        }
    }

    private func institutionBlock(institution: String, accounts: [PlaidAccount]) -> some View {
        let itemIdForInstitution = accounts.first?.plaidItemId
        let needsUpdate = itemIdForInstitution.flatMap { plaidItemId in
            plaidManager.itemsNeedingUpdate.first(where: { $0.item_id == plaidItemId })
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(institution)
                    .font(.subheadline.weight(.medium))
                if let owner = accounts.compactMap(\.ownerName).first, !owner.isEmpty {
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
                    if let account = accounts.first {
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
            ForEach(accounts) { account in
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

    private var backfillHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.blue)
                .font(.caption)
            Text("Plaid is still backfilling historical transactions. Older data will appear over the next few hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func errorHint(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if plaidManager.isSyncing {
                    ProgressView().controlSize(.small)
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
                        ProgressView().controlSize(.small)
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

            if !plaidManager.isSyncing, let summary = plaidManager.lastSyncSummary {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var disconnectAllRow: some View {
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
