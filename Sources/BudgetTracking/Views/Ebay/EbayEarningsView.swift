import SwiftUI

struct EbayEarningsView: View {
    @Binding var selectedMonth: String
    @Bindable var aiViewModel: InsightsViewModel
    let ebayAuthManager: EbayAuthManager
    @State private var viewModel = EbayEarningsViewModel()

    var body: some View {
        PageWithChatBar(
            viewModel: aiViewModel,
            actions: [
                AIChatAction(label: "Analyze eBay Earnings", icon: "sparkles") {
                    await aiViewModel.askAI(page: .ebayEarnings)
                }
            ],
            page: .ebayEarnings
        ) {
            ScrollView {
                VStack(spacing: 20) {
                    MonthSelectorView(selectedMonth: $selectedMonth)
                        .padding(.top)

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
        .navigationTitle("eBay Earnings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await syncFromAPI() }
                    } label: {
                        Label("Sync eBay", systemImage: "arrow.clockwise")
                    }
                    .disabled(!ebayAuthManager.isAuthenticated)
                    .help(ebayAuthManager.isAuthenticated ? "Sync data from eBay" : "Connect eBay account first")
                }
            }
        }
        .onAppear { viewModel.load(month: selectedMonth) }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.load(month: newMonth)
        }
        .onChange(of: ebayAuthManager.isAuthenticated) { _, isAuth in
            if isAuth {
                Task { await syncFromAPI() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load(month: selectedMonth)
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

    // MARK: - Sync

    private func syncFromAPI() async {
        guard let startDate = DateHelpers.startOfMonth(selectedMonth),
              let endDate = DateHelpers.endOfMonth(selectedMonth) else {
            viewModel.errorMessage = "Invalid month format."
            return
        }

        viewModel.isSyncing = true
        viewModel.syncProgress = "Authenticating..."
        defer { viewModel.isSyncing = false }

        do {
            let token = try await ebayAuthManager.getAccessToken()
            let apiService = EbayAPIService()

            // Fetch sales
            viewModel.syncProgress = "Fetching sales..."
            let sales = try await apiService.getAllTransactions(
                accessToken: token, startDate: startDate, endDate: endDate, transactionType: "SALE"
            )

            // Collect unique order IDs and fetch item titles from Fulfillment API
            let uniqueOrderIds = Array(Set(sales.compactMap { $0.orderId }))
            viewModel.syncProgress = "Fetching item details for \(uniqueOrderIds.count) orders..."
            let titlesByOrderId = await apiService.fetchItemTitles(accessToken: token, orderIds: uniqueOrderIds)

            // Transform and save orders + fees
            viewModel.syncProgress = "Saving \(sales.count) orders..."
            let monthStr = selectedMonth
            var ebayOrders: [EbayOrder] = []
            var ebayFees: [EbayFee] = []

            for sale in sales {
                guard let orderId = sale.orderId,
                      let transactionId = sale.transactionId else { continue }

                let saleDate = sale.transactionDate.flatMap { EbayAPIService.parseEbayDate($0) } ?? Date()
                let fulfillmentTitles = titlesByOrderId[orderId] ?? []

                for (index, lineItem) in (sale.orderLineItems ?? []).enumerated() {
                    // Use Fulfillment API title first, then Finances API title, then fallback
                    let itemTitle = (index < fulfillmentTitles.count ? fulfillmentTitles[index] : nil)
                        ?? lineItem.title
                        ?? (fulfillmentTitles.first)
                        ?? "Unknown Item"

                    let order = EbayOrder(
                        ebayOrderId: "\(orderId)-\(lineItem.lineItemId ?? "0")",
                        transactionId: transactionId,
                        buyerUsername: sale.buyer?.username,
                        itemTitle: itemTitle,
                        itemId: lineItem.itemId,
                        quantity: lineItem.quantity ?? lineItem.purchaseQuantity ?? 1,
                        saleDate: saleDate,
                        saleAmount: sale.amount?.doubleValue ?? 0,
                        month: monthStr
                    )
                    ebayOrders.append(order)

                    for fee in lineItem.fees ?? [] {
                        let ebayFee = EbayFee(
                            ebayOrderId: order.id,
                            feeType: fee.feeType ?? "UNKNOWN",
                            amount: abs(fee.amount?.doubleValue ?? 0),
                            feeMemo: fee.feeMemo
                        )
                        ebayFees.append(ebayFee)
                    }
                }

                // If no line items, create a single order from the transaction
                if sale.orderLineItems?.isEmpty ?? true {
                    let title = fulfillmentTitles.first ?? "eBay Sale"
                    let order = EbayOrder(
                        ebayOrderId: orderId,
                        transactionId: transactionId,
                        buyerUsername: sale.buyer?.username,
                        itemTitle: title,
                        saleDate: saleDate,
                        saleAmount: sale.amount?.doubleValue ?? 0,
                        month: monthStr
                    )
                    ebayOrders.append(order)

                    if let totalFee = sale.totalFeeAmount {
                        let fee = EbayFee(
                            ebayOrderId: order.id,
                            feeType: "TOTAL_FEE",
                            amount: abs(totalFee.doubleValue)
                        )
                        ebayFees.append(fee)
                    }
                }
            }

            try DatabaseManager.shared.saveEbayOrders(ebayOrders)
            try DatabaseManager.shared.saveEbayFees(ebayFees)

            // Fetch payouts
            viewModel.syncProgress = "Fetching payouts..."
            let apiPayouts = try await apiService.getAllPayouts(
                accessToken: token, startDate: startDate, endDate: endDate
            )

            var ebayPayouts: [EbayPayout] = []
            for payout in apiPayouts {
                guard let payoutId = payout.payoutId else { continue }
                let payoutDate = payout.payoutDate.flatMap { EbayAPIService.parseEbayDate($0) } ?? Date()
                let ebayPayout = EbayPayout(
                    ebayPayoutId: payoutId,
                    payoutDate: payoutDate,
                    amount: payout.amount?.doubleValue ?? 0,
                    status: payout.payoutStatus ?? "UNKNOWN",
                    month: monthStr
                )
                ebayPayouts.append(ebayPayout)
            }
            try DatabaseManager.shared.saveEbayPayouts(ebayPayouts)

            // Auto-match payouts to bank transactions
            viewModel.syncProgress = "Matching payouts..."
            viewModel.load(month: selectedMonth)
            viewModel.autoMatchPayouts()

            viewModel.syncProgress = "Done!"
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
