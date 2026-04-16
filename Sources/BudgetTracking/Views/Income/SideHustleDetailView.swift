import SwiftUI

struct SideHustleDetailView: View {
    let source: IncomeSource
    @Bindable var viewModel: SideHustleViewModel
    let selectedMonth: String

    @State private var isAddingIncome = false

    private var autoMatchedTxns: [Transaction] {
        viewModel.transactions(for: source.id)
    }

    private var manualTxns: [Transaction] {
        viewModel.manualIncomeTransactions(for: source.id)
    }

    private var allIncomeTxns: [Transaction] {
        let autoIds = Set(autoMatchedTxns.map(\.id))
        let manualOnly = manualTxns.filter { !autoIds.contains($0.id) }
        return (autoMatchedTxns + manualOnly).sorted { $0.date > $1.date }
    }

    private var totalIncome: Double {
        allIncomeTxns.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header with income total
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name)
                            .font(.title2.weight(.bold))
                        if !source.keywords.isEmpty {
                            Text("Auto-matches: \(source.keywords.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("This Month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(CurrencyFormatter.format(totalIncome))
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .foregroundStyle(totalIncome >= 0 ? .green : .red)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)

                // Income transactions
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Income")
                            .font(.headline)
                        Text("\(allIncomeTxns.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)

                        Spacer()

                        Button {
                            isAddingIncome = true
                        } label: {
                            Label("Add Income", systemImage: "plus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding()

                    Divider()
                        .padding(.horizontal)

                    if allIncomeTxns.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "banknote")
                                .font(.title)
                                .foregroundStyle(.secondary)
                            Text("No income this month")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Tap \"Add Income\" to tag bank transactions (Zelle, Venmo, etc.) as income for \(source.name).")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(allIncomeTxns) { txn in
                                HStack {
                                    Text(DateHelpers.shortDate(txn.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 65, alignment: .leading)

                                    Text(txn.description)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Spacer()

                                    // Show if auto-matched or manually added
                                    if autoMatchedTxns.contains(where: { $0.id == txn.id }) {
                                        Text("auto")
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(3)
                                    }

                                    Button {
                                        viewModel.removeTransactionFromSource(txn.id, sourceId: source.id)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    Text(CurrencyFormatter.format(txn.amount))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.green)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)

                                if txn.id != allIncomeTxns.last?.id {
                                    Divider()
                                        .padding(.horizontal)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }
            .padding()
        }
        .sheet(isPresented: $isAddingIncome) {
            AddIncomeTransactionSheet(viewModel: viewModel, source: source, month: selectedMonth)
        }
    }
}

// MARK: - Add Income Transaction Sheet

struct AddIncomeTransactionSheet: View {
    @Bindable var viewModel: SideHustleViewModel
    let source: IncomeSource
    let month: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var transactions: [Transaction] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Income for \(source.name)")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Select bank transactions that are income for \(source.name) (e.g. Zelle payments, Venmo transfers, cash deposits).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search transactions...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(filteredTransactions) { txn in
                    let isLinked = viewModel.isManualIncome(txn.id, for: source.id)
                    let isAutoMatched = viewModel.sourceAssignments[txn.id] == source.id

                    HStack {
                        Image(systemName: (isLinked || isAutoMatched) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle((isLinked || isAutoMatched) ? .green : .secondary)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(txn.description)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(DateHelpers.shortDate(txn.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if isAutoMatched && !isLinked {
                                    Text("auto-matched")
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
                            .foregroundStyle(.green)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isAutoMatched && !isLinked { return }
                        if isLinked {
                            viewModel.removeManualIncomeTransaction(txn.id, from: source.id)
                        } else {
                            viewModel.addManualIncomeTransaction(txn.id, to: source.id)
                        }
                    }
                    .opacity(isAutoMatched && !isLinked ? 0.6 : 1.0)
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
            // Show positive (income) transactions
            transactions = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: month)
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
}
