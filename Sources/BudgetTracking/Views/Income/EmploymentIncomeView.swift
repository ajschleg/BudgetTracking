import SwiftUI

struct EmploymentIncomeView: View {
    @Bindable var viewModel: IncomeViewModel
    @Binding var selectedMonth: String

    var body: some View {
        VStack(spacing: 20) {
            // Total income summary
            if viewModel.totalIncome > 0 {
                totalIncomeBanner
                    .padding(.horizontal)
            }

            // Source sections
            LazyVStack(spacing: 12) {
                ForEach(viewModel.sources) { source in
                    let txns = viewModel.transactions(for: source.id)
                    if !txns.isEmpty {
                        sourceSection(source: source, transactions: txns, total: viewModel.total(for: source.id))
                    }
                }

                // Uncategorized
                if !viewModel.uncategorizedTransactions.isEmpty {
                    uncategorizedSection
                }
            }
            .padding(.horizontal)

            if viewModel.incomeTransactions.isEmpty {
                Text("No employment income this month.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
            }
        }
    }

    // MARK: - Total Income Banner

    private var totalIncomeBanner: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
            Text("Employment Income")
                .font(.headline)
            Spacer()
            Text(CurrencyFormatter.format(viewModel.totalIncome))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.green)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Source Section

    private func sourceSection(source: IncomeSource, transactions: [Transaction], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(source.name)
                    .font(.headline)

                Text("\(transactions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)

                Spacer()

                Image(systemName: viewModel.expandedSourceId == source.id ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(CurrencyFormatter.format(total))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.expandedSourceId = viewModel.expandedSourceId == source.id ? nil : source.id
                }
            }

            if viewModel.expandedSourceId == source.id {
                Divider()
                    .padding(.horizontal)

                VStack(spacing: 0) {
                    ForEach(transactions) { txn in
                        transactionRow(txn)
                        if txn.id != transactions.last?.id {
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.expandedSourceId)
    }

    // MARK: - Uncategorized Section

    @State private var uncategorizedExpanded = false

    private var uncategorizedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Uncategorized")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("\(viewModel.uncategorizedTransactions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)

                Spacer()

                Image(systemName: uncategorizedExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(CurrencyFormatter.format(viewModel.uncategorizedTotal))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    uncategorizedExpanded.toggle()
                }
            }

            if uncategorizedExpanded {
                Divider()
                    .padding(.horizontal)

                VStack(spacing: 0) {
                    ForEach(viewModel.uncategorizedTransactions) { txn in
                        transactionRow(txn)
                        if txn.id != viewModel.uncategorizedTransactions.last?.id {
                            Divider()
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: uncategorizedExpanded)
    }

    // MARK: - Transaction Row

    private func transactionRow(_ txn: Transaction) -> some View {
        HStack {
            Text(DateHelpers.shortDate(txn.date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .leading)

            Text(txn.description)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Picker("Source", selection: Binding(
                get: { viewModel.sourceAssignments[txn.id] },
                set: { newValue in viewModel.assignSource(newValue, to: txn.id) }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(viewModel.sources) { source in
                    Text(source.name).tag(UUID?.some(source.id))
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Text(CurrencyFormatter.format(txn.amount))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.green)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}
