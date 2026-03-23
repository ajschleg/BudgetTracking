import SwiftUI

struct TransactionsListView: View {
    @Binding var selectedMonth: String
    @State private var viewModel = TransactionsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            MonthSelectorView(selectedMonth: $selectedMonth)
                .padding(.vertical, 8)

            TransactionFiltersBar(viewModel: viewModel)

            TransactionTableContent(viewModel: viewModel)
        }
        .navigationTitle("Transactions")
        .onAppear { viewModel.load(month: selectedMonth) }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.load(month: newMonth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load(month: selectedMonth)
        }
    }
}

private struct TransactionFiltersBar: View {
    @Bindable var viewModel: TransactionsViewModel

    var body: some View {
        HStack {
            TextField("Search transactions...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Picker("Category", selection: $viewModel.selectedCategoryFilter) {
                Text("All Categories").tag(nil as UUID?)
                ForEach(viewModel.categories) { cat in
                    Text(cat.name).tag(cat.id as UUID?)
                }
            }
            .frame(maxWidth: 200)

            Spacer()

            Text("\(viewModel.filteredTransactions.count) transactions")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

private struct TransactionTableContent: View {
    @Bindable var viewModel: TransactionsViewModel

    var body: some View {
        if viewModel.filteredTransactions.isEmpty {
            emptyState
        } else {
            transactionList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No transactions found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Import bank statements to see transactions here.")
                .foregroundStyle(.tertiary)
        }
        .frame(maxHeight: .infinity)
    }

    private var transactionList: some View {
        List {
            ForEach(viewModel.filteredTransactions) { txn in
                TransactionRowView(
                    transaction: txn,
                    categories: viewModel.categories,
                    categoryName: viewModel.categoryName(for: txn.categoryId),
                    onCategoryChange: { newId in
                        viewModel.updateCategory(for: txn.id, to: newId)
                    }
                )
            }
        }
    }
}

private struct TransactionRowView: View {
    let transaction: Transaction
    let categories: [BudgetCategory]
    let categoryName: String
    let onCategoryChange: (UUID) -> Void

    @State private var selectedCategoryId: UUID?

    var body: some View {
        HStack {
            Text(DateHelpers.shortDate(transaction.date))
                .frame(width: 80, alignment: .leading)
                .font(.callout)

            Text(transaction.description)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .font(.callout)

            Picker("", selection: $selectedCategoryId) {
                Text("Uncategorized").tag(nil as UUID?)
                ForEach(categories) { cat in
                    Text(cat.name).tag(cat.id as UUID?)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: selectedCategoryId) { _, newValue in
                if let id = newValue, id != transaction.categoryId {
                    onCategoryChange(id)
                }
            }

            Text(CurrencyFormatter.format(transaction.amount))
                .frame(width: 90, alignment: .trailing)
                .foregroundColor(transaction.amount < 0 ? .primary : .green)
                .monospacedDigit()
                .font(.callout)
        }
        .onAppear {
            selectedCategoryId = transaction.categoryId
        }
    }
}
