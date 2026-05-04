import SwiftUI

/// iOS transactions tab: month-scoped list with search and tap-to-categorize.
/// Reads through the shared TransactionsViewModel; reassigning a category
/// invokes the same RuleLearner pipeline the Mac uses, so future imports
/// of the same merchant get auto-categorized everywhere.
struct TransactionsView: View {
    @State private var viewModel = TransactionsViewModel()
    @State private var selectedMonth: String = DateHelpers.monthString()
    @State private var pickerTransaction: Transaction?
    @State private var dataChangeCounter = 0

    private var grouped: [(date: Date, items: [Transaction])] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: viewModel.filteredTransactions) {
            cal.startOfDay(for: $0.date)
        }
        return buckets
            .map { (date: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MonthSelector(selectedMonth: $selectedMonth)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if let error = viewModel.errorMessage {
                    InlineErrorRow(message: error)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                if viewModel.transactions.isEmpty {
                    EmptyState()
                        .padding(.horizontal, 16)
                        .padding(.top, 32)
                    Spacer()
                } else {
                    List {
                        if viewModel.uncategorizedCount > 0 {
                            Toggle(isOn: Binding(
                                get: { viewModel.showOnlyUncategorized },
                                set: { viewModel.showOnlyUncategorized = $0 }
                            )) {
                                Label(
                                    "Uncategorized only (\(viewModel.uncategorizedCount))",
                                    systemImage: "questionmark.circle"
                                )
                            }
                        }

                        ForEach(grouped, id: \.date) { group in
                            Section(DateHelpers.shortDate(group.date)) {
                                ForEach(group.items) { txn in
                                    TransactionRow(
                                        transaction: txn,
                                        category: viewModel.categories.first { $0.id == txn.categoryId }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { pickerTransaction = txn }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: Binding(
                        get: { viewModel.searchText },
                        set: { viewModel.searchText = $0 }
                    ), prompt: "Search description")
                }
            }
            .navigationTitle("Transactions")
            .refreshable { viewModel.load(month: selectedMonth) }
            .task(id: "\(selectedMonth)-\(dataChangeCounter)") {
                viewModel.load(month: selectedMonth)
            }
            .task {
                let center = NotificationCenter.default
                for await _ in center.notifications(named: .localDataDidChange) {
                    dataChangeCounter &+= 1
                }
            }
            .sheet(item: $pickerTransaction) { txn in
                CategoryPickerSheet(
                    transaction: txn,
                    categories: viewModel.categories,
                    onPick: { categoryId in
                        viewModel.updateCategory(for: txn.id, to: categoryId)
                        pickerTransaction = nil
                    }
                )
            }
        }
    }
}

// MARK: - Month Selector (mirrors Dashboard's)

private struct MonthSelector: View {
    @Binding var selectedMonth: String

    var body: some View {
        HStack {
            Button {
                selectedMonth = DateHelpers.previousMonth(from: selectedMonth)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)

            Spacer()

            VStack(spacing: 2) {
                Text(DateHelpers.displayMonth(selectedMonth))
                    .font(.headline)
                if selectedMonth != DateHelpers.monthString() {
                    Button("Today") {
                        selectedMonth = DateHelpers.monthString()
                    }
                    .font(.caption)
                }
            }

            Spacer()

            Button {
                selectedMonth = DateHelpers.nextMonth(from: selectedMonth)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Row

private struct TransactionRow: View {
    let transaction: Transaction
    let category: BudgetCategory?

    private var dotColor: Color {
        guard let category else { return .secondary }
        return ColorThresholds.colorFromHex(category.colorHex)
    }

    private var amountColor: Color {
        transaction.amount >= 0 ? .green : .primary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(category?.name ?? "Uncategorized")
                    .font(.caption)
                    .foregroundStyle(category == nil ? Color.orange : Color.secondary)
            }

            Spacer()

            Text(CurrencyFormatter.format(transaction.amount))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Category Picker Sheet

private struct CategoryPickerSheet: View {
    let transaction: Transaction
    let categories: [BudgetCategory]
    let onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transaction.description)
                            .font(.subheadline)
                        Text("\(DateHelpers.shortDate(transaction.date))  •  \(CurrencyFormatter.format(transaction.amount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Category") {
                    ForEach(categories) { category in
                        Button {
                            onPick(category.id)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(ColorThresholds.colorFromHex(category.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(category.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if category.id == transaction.categoryId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Change category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Empty / error

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No transactions this month")
                .font(.headline)
            Text("Once iCloud sync brings data down from your Mac, transactions for this month will appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

private struct InlineErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
