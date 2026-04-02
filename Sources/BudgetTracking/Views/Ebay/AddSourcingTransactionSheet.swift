import SwiftUI

struct AddSourcingTransactionSheet: View {
    @Bindable var viewModel: SideHustleViewModel
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var transactions: [Transaction] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Sourcing Transactions")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Select individual transactions to include as sourcing costs. These are added on top of any category-based sourcing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search transactions...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(filteredTransactions) { txn in
                    let isLinked = viewModel.isManualSourcing(txn.id) || isCategorySourcing(txn)

                    HStack {
                        Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isLinked ? .blue : .secondary)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(txn.description)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(DateHelpers.shortDate(txn.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if isCategorySourcing(txn) {
                                    Text("via category")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(3)
                                }
                            }
                        }

                        Spacer()

                        Text(CurrencyFormatter.format(txn.amount))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isCategorySourcing(txn) { return }
                        if viewModel.isManualSourcing(txn.id) {
                            viewModel.removeManualSourcingTransaction(txn.id)
                        } else {
                            viewModel.addManualSourcingTransaction(txn.id)
                        }
                    }
                    .opacity(isCategorySourcing(txn) ? 0.6 : 1.0)
                }
            }
            .frame(minHeight: 300)
        }
        .padding(20)
        .frame(minWidth: 550, minHeight: 500)
        .onAppear { loadTransactions() }
    }

    private func loadTransactions() {
        do {
            transactions = try DatabaseManager.shared.fetchTransactions(forMonth: month)
                .filter { $0.amount < 0 }
        } catch {
            transactions = []
        }
    }

    private var filteredTransactions: [Transaction] {
        if searchText.isEmpty { return transactions }
        return transactions.filter {
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func isCategorySourcing(_ txn: Transaction) -> Bool {
        guard let categoryId = txn.categoryId else { return false }
        return viewModel.sourcingCategoryIds.contains(categoryId)
    }
}
