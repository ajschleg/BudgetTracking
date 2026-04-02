import SwiftUI

struct SideHustleBannerView: View {
    @Bindable var viewModel: SideHustleViewModel
    let selectedMonth: String

    var body: some View {
        VStack(spacing: 0) {
            // Monthly and Lifetime side by side
            HStack(alignment: .top, spacing: 0) {
                // Monthly Net Profit
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monthly Net Profit")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(CurrencyFormatter.format(viewModel.monthlyNetProfit))
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(viewModel.monthlyNetProfit >= 0 ? .green : .red)

                    HStack(spacing: 12) {
                        HStack(spacing: 3) {
                            Text("Sales:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(CurrencyFormatter.format(viewModel.monthlySales))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        HStack(spacing: 3) {
                            Text("Costs:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(CurrencyFormatter.format(-viewModel.monthlyCosts))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                }

                Spacer()

                Divider()
                    .frame(height: 55)
                    .padding(.horizontal, 16)

                // Lifetime Net Profit
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lifetime Net Profit")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(CurrencyFormatter.format(viewModel.lifetimeNetProfit))
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(viewModel.lifetimeNetProfit >= 0 ? .green : .red)

                    HStack(spacing: 12) {
                        HStack(spacing: 3) {
                            Text("Sales:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(CurrencyFormatter.format(viewModel.lifetimeSales))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        HStack(spacing: 3) {
                            Text("Costs:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(CurrencyFormatter.format(-viewModel.lifetimeCosts))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                }

                Spacer()
            }
            .padding()

            Divider()

            // Sourcing action bar
            HStack(spacing: 12) {
                Text("Sourcing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.isManagingSourcingCategories = true
                } label: {
                    Label("Categories", systemImage: "folder.badge.gearshape")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.isAddingSourcingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isMonthlySourcingExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Monthly (\(viewModel.allSourcingTransactions.count))")
                            .font(.caption)
                        Image(systemName: viewModel.isMonthlySourcingExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.isLifetimeSourcingExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Lifetime (\(viewModel.lifetimeSourcingTransactions.count))")
                            .font(.caption)
                        Image(systemName: viewModel.isLifetimeSourcingExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Expandable monthly transactions
            if viewModel.isMonthlySourcingExpanded {
                Divider()
                    .padding(.horizontal)
                sourcingTransactionList(
                    title: "Monthly Sourcing",
                    transactions: viewModel.allSourcingTransactions,
                    total: viewModel.totalSourcingCosts,
                    showRemoveButton: true
                )
            }

            // Expandable lifetime transactions
            if viewModel.isLifetimeSourcingExpanded {
                Divider()
                    .padding(.horizontal)
                sourcingTransactionList(
                    title: "Lifetime Sourcing",
                    transactions: viewModel.lifetimeSourcingTransactions,
                    total: viewModel.lifetimeCosts,
                    showRemoveButton: false
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isMonthlySourcingExpanded)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isLifetimeSourcingExpanded)
        .sheet(isPresented: $viewModel.isManagingSourcingCategories) {
            SourcingCategoriesSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isAddingSourcingTransaction) {
            AddSourcingTransactionSheet(viewModel: viewModel, month: selectedMonth)
        }
    }

    private func sourcingTransactionList(title: String, transactions: [Transaction], total: Double, showRemoveButton: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if total > 0 {
                    Text(CurrencyFormatter.format(-total))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)

            ForEach(transactions) { txn in
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
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                    if showRemoveButton && viewModel.isManualSourcing(txn.id) {
                        Button {
                            viewModel.removeManualSourcingTransaction(txn.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }

            if transactions.isEmpty {
                Text("No sourcing transactions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.bottom, 4)
    }
}
