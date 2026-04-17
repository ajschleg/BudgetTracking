import SwiftUI

/// Pre-Link consent screen. Shown before the Plaid Link WKWebView so the
/// user sees what data will be shared, who can access it, and where the
/// full privacy policy lives — and must explicitly tap Continue before
/// Link opens.
///
/// Required by Plaid's MSA guidance ("Provide required notices and obtain
/// consent"). Covers GLBA/CCPA-style disclosure plus Plaid's own consent
/// layer on top.
struct PlaidConsentView: View {
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let privacyPolicyURL = URL(string: "https://ajschleg.github.io/BudgetTracking/#privacy")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    dataSection
                    accessSection
                    thirdPartySection
                    rightsSection
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 600)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Before You Connect")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Cancel") { dismiss() }
        }
        .padding()
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .font(.title)
                Text("BudgetTracking uses Plaid to connect to your bank")
                    .font(.headline)
            }
            Text("Plaid is the service that lets this app read transactions from your accounts. Your bank credentials go directly to Plaid and are never stored on this computer.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var dataSection: some View {
        section(title: "What data will be shared") {
            bulletRow("Account name, type, and last 4 digits of the account number")
            bulletRow("Current and available balances, refreshed when you tap Refresh Balances")
            bulletRow("Transaction history (description, merchant, date, amount, category)")
            bulletRow("Account owner name, email, and phone as provided by your bank")
        }
    }

    private var accessSection: some View {
        section(title: "Where your data is stored") {
            bulletRow("All data stays on this Mac in a local database")
            bulletRow("Optionally synced to your private iCloud account for your other devices")
            bulletRow("Never sent to any server other than Plaid itself")
            bulletRow("Plaid access tokens are encrypted at rest (AES-256-GCM)")
        }
    }

    private var thirdPartySection: some View {
        section(title: "Third parties") {
            bulletRow("Plaid (Plaid Inc.) provides the bank connection service")
            bulletRow("Apple iCloud (if you enable sync) stores an encrypted copy in your iCloud account")
            bulletRow("No data is sold, shared for advertising, or used for any purpose other than showing you your budget")
        }
    }

    private var rightsSection: some View {
        section(title: "Your rights") {
            bulletRow("Disconnect any bank at any time from Settings — this revokes Plaid's access and stops all syncing")
            bulletRow("Delete all data by removing the app")
            bulletRow("View your connection status and last sync time in Settings")
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 6) {
                body()
            }
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Link("Privacy Policy", destination: privacyPolicyURL)
                .font(.caption)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                onContinue()
            } label: {
                Text("I Agree, Continue to Plaid")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}
