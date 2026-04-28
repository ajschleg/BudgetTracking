import SwiftUI

struct DashboardView: View {
    @Binding var selectedMonth: String
    @Binding var selectedItem: SidebarItem?
    @Bindable var aiViewModel: InsightsViewModel
    @AppStorage("isIncomePageEnabled") private var isIncomePageEnabled = false
    @AppStorage("isEditingLocked") private var isEditingLocked = true
    @State private var viewModel = DashboardViewModel()
    @State private var editingCategory: BudgetCategory?

    var body: some View {
        PageWithChatBar(
            viewModel: aiViewModel,
            actions: [
                AIChatAction(label: "Analyze Spending", icon: "sparkles") {
                    await aiViewModel.askAI(page: .dashboard)
                }
            ],
            page: .dashboard
        ) {
            ScrollView {
                VStack(spacing: 20) {
                    // Month selector
                    MonthSelectorView(selectedMonth: $selectedMonth)
                        .padding(.top)

                    // Income summary
                    if viewModel.totalIncome > 0 {
                        incomeSummarySection
                            .padding(.horizontal)
                    }

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
                                    onCategoryChange: isEditingLocked ? nil : { txnId, newCatId in
                                        viewModel.changeTransactionCategory(txnId, to: newCatId)
                                    },
                                    onEdit: isEditingLocked ? nil : { editingCategory = category }
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.load(month: selectedMonth)
                    aiViewModel.load(month: selectedMonth)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .help("Refresh dashboard")
            }
        }
        .onAppear {
            viewModel.load(month: selectedMonth)
            aiViewModel.load(month: selectedMonth)
        }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.load(month: newMonth)
            aiViewModel.load(month: newMonth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load(month: selectedMonth)
        }
        .sheet(item: $editingCategory) { category in
            CategoryEditorView(
                category: category,
                categories: viewModel.categories,
                onSave: { name, budget, color in
                    var updated = category
                    updated.name = name
                    updated.monthlyBudget = budget
                    updated.colorHex = color
                    do {
                        try DatabaseManager.shared.saveCategory(updated)
                        viewModel.load(month: selectedMonth)
                    } catch {
                        // Silently revert on save failure; the load() above
                        // would re-fetch the unmodified row.
                    }
                    editingCategory = nil
                },
                onCancel: { editingCategory = nil }
            )
        }
    }

    // MARK: - Income Summary

    private var incomeSummarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (clickable to expand)
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)

                Text("Income")
                    .font(.headline)

                Spacer()

                if isIncomePageEnabled {
                    Button {
                        selectedItem = .income
                    } label: {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open Income page")
                }

                Image(systemName: viewModel.isIncomeExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(CurrencyFormatter.format(viewModel.totalIncome))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.isIncomeExpanded.toggle()
                }
            }

            // Expanded transaction list
            if viewModel.isIncomeExpanded {
                Divider()
                    .padding(.horizontal)

                if viewModel.incomeTransactions.isEmpty {
                    Text("No income transactions this month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.incomeTransactions) { txn in
                            HStack {
                                Text(DateHelpers.shortDate(txn.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 65, alignment: .leading)

                                Text(txn.description)
                                    .font(.caption)
                                    .lineLimit(1)

                                Spacer()

                                Text(CurrencyFormatter.format(txn.amount))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)

                            if txn.id != viewModel.incomeTransactions.last?.id {
                                Divider()
                                    .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Net summary
                Divider()
                    .padding(.horizontal)
                HStack {
                    Text("Net (Income − Spending)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let net = viewModel.totalIncome - viewModel.totalSpent
                    Text(CurrencyFormatter.format(abs(net)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(net >= 0 ? .green : .red)
                    Text(net >= 0 ? "surplus" : "deficit")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isIncomeExpanded)
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
