import SwiftUI

struct DashboardView: View {
    @Binding var selectedMonth: String
    @State private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Month selector
                MonthSelectorView(selectedMonth: $selectedMonth)
                    .padding(.top)

                // Overall budget bar
                OverallBudgetBar(
                    spent: viewModel.totalSpent,
                    budget: viewModel.totalBudget,
                    percentage: viewModel.overallPercentage
                )
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                // Category budget bars
                if viewModel.categories.isEmpty {
                    Text("No budget categories configured.\nGo to Categories to set up your budget.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.categories) { category in
                            CategoryBudgetBar(
                                category: category,
                                spent: viewModel.spending(for: category),
                                percentage: viewModel.percentage(for: category),
                                isExpanded: viewModel.expandedCategoryId == category.id,
                                transactions: viewModel.expandedCategoryId == category.id
                                    ? viewModel.expandedTransactions : [],
                                allCategories: viewModel.categories,
                                onTap: { viewModel.toggleCategory(category.id) },
                                onCategoryChange: { txnId, newCatId in
                                    viewModel.changeTransactionCategory(txnId, to: newCatId)
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("Dashboard")
        .onAppear { viewModel.load(month: selectedMonth) }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.load(month: newMonth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load(month: selectedMonth)
        }
    }
}

struct MonthSelectorView: View {
    @Binding var selectedMonth: String

    var body: some View {
        HStack {
            Button(action: {
                selectedMonth = DateHelpers.previousMonth(from: selectedMonth)
            }) {
                Image(systemName: "chevron.left")
            }

            Text(DateHelpers.displayMonth(selectedMonth))
                .font(.title2)
                .fontWeight(.semibold)
                .frame(minWidth: 180)

            Button(action: {
                selectedMonth = DateHelpers.nextMonth(from: selectedMonth)
            }) {
                Image(systemName: "chevron.right")
            }

            Spacer()

            Button("Today") {
                selectedMonth = DateHelpers.monthString()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }
}
