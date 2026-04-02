import SwiftUI

enum IncomeTab: String, CaseIterable {
    case employment = "Employment"
    case sideHustle = "Side Hustle"
}

struct IncomeTabView: View {
    @Binding var selectedMonth: String
    @Bindable var aiViewModel: InsightsViewModel
    let ebayAuthManager: EbayAuthManager

    @State private var selectedTab: IncomeTab = .sideHustle
    @State private var employmentViewModel = IncomeViewModel()
    @State private var ebayViewModel = EbayEarningsViewModel()
    @State private var sideHustleViewModel: SideHustleViewModel?

    var body: some View {
        PageWithChatBar(
            viewModel: aiViewModel,
            actions: [
                AIChatAction(label: "Analyze Income", icon: "sparkles") {
                    await aiViewModel.askAI(page: .income)
                }
            ],
            page: .income
        ) {
            VStack(spacing: 0) {
                // Shared header
                VStack(spacing: 12) {
                    MonthSelectorView(selectedMonth: $selectedMonth)
                        .padding(.top)

                    Picker("Income Type", selection: $selectedTab) {
                        ForEach(IncomeTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                // Tab content
                switch selectedTab {
                case .employment:
                    ScrollView {
                        EmploymentIncomeView(viewModel: employmentViewModel, selectedMonth: $selectedMonth)
                            .padding(.bottom, 20)
                    }

                case .sideHustle:
                    if let vm = sideHustleViewModel {
                        SideHustleTabView(
                            viewModel: vm,
                            ebayViewModel: ebayViewModel,
                            ebayAuthManager: ebayAuthManager,
                            selectedMonth: $selectedMonth
                        )
                    }
                }
            }
        }
        .navigationTitle("Income")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if selectedTab == .employment {
                    Button {
                        employmentViewModel.isManagingSourcesPresented = true
                    } label: {
                        Label("Manage Sources", systemImage: "gear")
                    }
                } else if selectedTab == .sideHustle {
                    HStack(spacing: 8) {
                        Button {
                            employmentViewModel.isManagingSourcesPresented = true
                        } label: {
                            Label("Manage Sources", systemImage: "gear")
                        }

                        // eBay sync button
                        if ebayAuthManager.isAuthenticated {
                            if ebayViewModel.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button {
                                    Task { await syncEbay() }
                                } label: {
                                    Label("Sync eBay", systemImage: "arrow.clockwise")
                                }
                            }
                        }

                        Button {
                            sideHustleViewModel?.isAddingSideHustle = true
                        } label: {
                            Label("Add Side Hustle", systemImage: "plus")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $employmentViewModel.isManagingSourcesPresented) {
            ManageSourcesSheet(viewModel: employmentViewModel)
        }
        .onAppear {
            if sideHustleViewModel == nil {
                sideHustleViewModel = SideHustleViewModel(ebayViewModel: ebayViewModel)
            }
            loadAll()
        }
        .onChange(of: selectedMonth) { _, _ in
            loadAll()
        }
        .onChange(of: selectedTab) { _, _ in
            loadAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            loadAll()
        }
    }

    private func loadAll() {
        employmentViewModel.load(month: selectedMonth, sourceType: .employment)
        ebayViewModel.load(month: selectedMonth)
        sideHustleViewModel?.load(month: selectedMonth)
    }

    private func syncEbay() async {
        guard let startDate = DateHelpers.startOfMonth(selectedMonth),
              let endDate = DateHelpers.endOfMonth(selectedMonth) else { return }

        ebayViewModel.isSyncing = true
        ebayViewModel.syncProgress = "Authenticating..."
        defer {
            ebayViewModel.isSyncing = false
            sideHustleViewModel?.load(month: selectedMonth)
        }

        do {
            let token = try await ebayAuthManager.getAccessToken()
            let apiService = EbayAPIService()

            ebayViewModel.syncProgress = "Fetching sales..."
            let sales = try await apiService.getAllTransactions(
                accessToken: token, startDate: startDate, endDate: endDate, transactionType: "SALE"
            )

            let uniqueOrderIds = Array(Set(sales.compactMap { $0.orderId }))
            ebayViewModel.syncProgress = "Fetching item details..."
            let titlesByOrderId = await apiService.fetchItemTitles(accessToken: token, orderIds: uniqueOrderIds)

            ebayViewModel.syncProgress = "Saving \(sales.count) orders..."
            let monthStr = selectedMonth
            var ebayOrders: [EbayOrder] = []
            var ebayFees: [EbayFee] = []

            for sale in sales {
                guard let orderId = sale.orderId,
                      let transactionId = sale.transactionId else { continue }

                let saleDate = sale.transactionDate.flatMap { EbayAPIService.parseEbayDate($0) } ?? Date()
                let fulfillmentTitles = titlesByOrderId[orderId] ?? []

                for (index, lineItem) in (sale.orderLineItems ?? []).enumerated() {
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

            ebayViewModel.syncProgress = "Fetching payouts..."
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

            ebayViewModel.syncProgress = "Matching payouts..."
            ebayViewModel.load(month: selectedMonth)
            ebayViewModel.autoMatchPayouts()
        } catch {
            ebayViewModel.errorMessage = error.localizedDescription
        }
    }
}
