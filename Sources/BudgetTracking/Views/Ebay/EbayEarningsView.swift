import SwiftUI

struct EbayEarningsView: View {
    @Binding var selectedMonth: String
    let ebayAuthManager: EbayAuthManager
    @Bindable var viewModel: EbayEarningsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Connection banner or processing indicator
                if ebayAuthManager.isAuthenticating && !ebayAuthManager.showingCodeEntry {
                        // Exchanging token — show prominent spinner
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connecting to eBay...")
                                    .font(.headline)
                                Text("Exchanging authorization code for access token.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    } else if !ebayAuthManager.isAuthenticated {
                        connectionBanner
                            .padding(.horizontal)
                    } else {
                        // Connected indicator
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected to eBay")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Disconnect") {
                                ebayAuthManager.disconnect()
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }

                    if let error = ebayAuthManager.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    if let error = viewModel.errorMessage {
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Dismiss") { viewModel.errorMessage = nil }
                                .font(.caption)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    if viewModel.isSyncing {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.syncProgress)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    if let summary = viewModel.summary, summary.totalSales > 0 {
                        earningsSummaryCard(summary)
                            .padding(.horizontal)
                    }

                    // Orders section
                    if !viewModel.orders.isEmpty {
                        ordersSection
                            .padding(.horizontal)
                    }

                    // Payouts section
                    if !viewModel.payouts.isEmpty {
                        payoutsSection
                            .padding(.horizontal)
                    }

                    if viewModel.orders.isEmpty && viewModel.payouts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bag")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No eBay data this month")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Connect your eBay account and sync to see earnings data.")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 60)
                    }
                }
                .padding(.bottom, 20)
            }
        }


    // MARK: - Earnings Summary Card

    private func earningsSummaryCard(_ summary: DatabaseManager.EbayEarningsSummary) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Earnings Summary")
                    .font(.headline)
                Spacer()
            }

            Divider()

            summaryRow("Gross Sales", value: summary.totalSales, color: .green)
            summaryRow("eBay Fees", value: -summary.totalFees, color: .red)
            if summary.totalCOGS > 0 {
                summaryRow("Cost of Goods", value: -summary.totalCOGS, color: .red)
            }
            if summary.totalShipping > 0 {
                summaryRow("Shipping Costs", value: -summary.totalShipping, color: .red)
            }
            if summary.totalSourcingCosts > 0 {
                summaryRow("Sourcing Costs", value: -summary.totalSourcingCosts, color: .red)
            }

            Divider()

            HStack {
                Text("Net Earnings")
                    .font(.headline)
                Spacer()
                Text(CurrencyFormatter.format(summary.netEarnings))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(summary.netEarnings >= 0 ? .green : .red)
            }

            if summary.totalSales > 0 {
                HStack {
                    Text("Effective Fee Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", summary.effectiveFeeRate * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func summaryRow(_ label: String, value: Double, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(CurrencyFormatter.format(value))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: - Orders Section

    private var ordersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Orders")
                    .font(.headline)
                Text("\(viewModel.orders.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                Spacer()
            }
            .padding()

            Divider()
                .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(viewModel.orders) { order in
                    orderRow(order)
                    if order.id != viewModel.orders.last?.id {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private func orderRow(_ order: EbayOrder) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.itemTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(DateHelpers.shortDate(order.saleDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(CurrencyFormatter.format(order.saleAmount))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.green)
                    let net = viewModel.netProfit(for: order)
                    Text("Net: \(CurrencyFormatter.format(net))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(net >= 0 ? .green : .red)
                }

                Image(systemName: viewModel.expandedOrderId == order.id ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.expandedOrderId = viewModel.expandedOrderId == order.id ? nil : order.id
                }
            }

            if viewModel.expandedOrderId == order.id {
                Divider()
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 6) {
                    if let fees = viewModel.orderFees[order.id], !fees.isEmpty {
                        Text("Fees")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(fees) { fee in
                            HStack {
                                Text(fee.feeType.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                Spacer()
                                Text(CurrencyFormatter.format(-fee.amount))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if let cogs = viewModel.orderCOGS[order.id] {
                        Divider()
                        HStack {
                            Text("Cost of Goods")
                                .font(.caption)
                            Spacer()
                            Text(CurrencyFormatter.format(-cogs.costAmount))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                        if cogs.shippingCost > 0 {
                            HStack {
                                Text("Shipping")
                                    .font(.caption)
                                Spacer()
                                Text(CurrencyFormatter.format(-cogs.shippingCost))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if let buyer = order.buyerUsername {
                        Text("Buyer: \(buyer)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // COGS Editor
                    if viewModel.editingCOGSOrderId == order.id {
                        COGSEditorView(
                            orderId: order.id,
                            existing: viewModel.orderCOGS[order.id],
                            onSave: { cost, shipping, notes in
                                viewModel.saveCOGS(for: order.id, costAmount: cost, shippingCost: shipping, notes: notes)
                                viewModel.editingCOGSOrderId = nil
                            },
                            onCancel: { viewModel.editingCOGSOrderId = nil }
                        )
                    } else {
                        Button {
                            viewModel.editingCOGSOrderId = order.id
                        } label: {
                            Label(
                                viewModel.orderCOGS[order.id] != nil ? "Edit Costs" : "Add Costs",
                                systemImage: "pencil.circle"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
                .padding()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.expandedOrderId)
    }

    // MARK: - Payouts Section

    private var payoutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Payouts")
                    .font(.headline)
                Text("\(viewModel.payouts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                Spacer()
            }
            .padding()

            Divider()
                .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(viewModel.payouts) { payout in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateHelpers.shortDate(payout.payoutDate))
                                .font(.subheadline)
                            Text(payout.status.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if payout.matchedTransactionId != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .help("Matched to bank transaction")
                        } else {
                            Image(systemName: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("Not matched to bank transaction")
                        }

                        Text(CurrencyFormatter.format(payout.amount))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.green)
                    }
                    .padding()

                    if payout.id != viewModel.payouts.last?.id {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Connection Banner

    @State private var manualAuthCode: String = ""

    private var connectionBanner: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "link.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect eBay Account")
                        .font(.headline)
                    Text("Link your eBay seller account to sync sales, fees, and payouts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if ebayAuthManager.isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else if ebayAuthManager.hasCredentials {
                    Button("Connect") {
                        ebayAuthManager.startAuthFlow()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Set up credentials in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Manual code entry after browser auth
            if ebayAuthManager.showingCodeEntry {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("After signing in on eBay, copy the full URL from the browser address bar and paste it here:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Paste URL or authorization code here...", text: $manualAuthCode)
                            .textFieldStyle(.roundedBorder)

                        Button("Submit") {
                            ebayAuthManager.handleManualCode(manualAuthCode)
                            manualAuthCode = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualAuthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") {
                            ebayAuthManager.showingCodeEntry = false
                            ebayAuthManager.isAuthenticating = false
                            manualAuthCode = ""
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

}
