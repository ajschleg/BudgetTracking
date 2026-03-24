import SwiftUI

struct TransactionsListView: View {
    @Binding var selectedMonth: String
    @Bindable var aiViewModel: InsightsViewModel
    @State private var viewModel = TransactionsViewModel()
    @State private var reapplyResultMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            MonthSelectorView(selectedMonth: $selectedMonth)
                .padding(.vertical, 8)

            TransactionFiltersBar(viewModel: viewModel)

            TransactionTableContent(viewModel: viewModel)

            Divider()

            // Re-apply Rules section
            reapplyRulesSection
                .padding(.horizontal)
                .padding(.top)

            // AI Auto-Categorize section
            if aiViewModel.isAPIKeyConfigured {
                autoCategorizeSection
                    .padding(.horizontal)
                    .padding(.top)
                    .padding(.bottom)
            }
        }
        .navigationTitle("Transactions")
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
        .onReceive(NotificationCenter.default.publisher(for: .localDataDidChange)) { _ in
            viewModel.load(month: selectedMonth)
        }
    }

    // MARK: - Re-apply Rules Section

    private var reapplyRulesSection: some View {
        GroupBox {
            HStack {
                Text("Re-apply categorization rules to uncategorized transactions.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Spacer()

                if let message = reapplyResultMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button {
                    let count = viewModel.reapplyRules()
                    withAnimation {
                        reapplyResultMessage = count > 0
                            ? "Categorized \(count) transaction\(count == 1 ? "" : "s")."
                            : "No new matches found."
                    }
                } label: {
                    Label("Re-apply Rules", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(4)
        } label: {
            Label("Rule-Based Categorization", systemImage: "text.badge.checkmark")
        }
    }

    // MARK: - Auto-Categorize Section

    private var autoCategorizeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Let AI categorize your uncategorized transactions.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if aiViewModel.autoCategorizeRunning {
                        Button {
                            aiViewModel.stopAutoCategorize()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button {
                            Task { await aiViewModel.categorizeTransactions() }
                        } label: {
                            if aiViewModel.isLoadingCategorization {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Categorize Batch", systemImage: "tag.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(aiViewModel.isLoadingCategorization || aiViewModel.isOverCap)

                        Button {
                            Task { await aiViewModel.autoCategorizeAll() }
                        } label: {
                            Label("Categorize All", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(aiViewModel.isLoadingCategorization || aiViewModel.isOverCap)
                    }
                }

                if !aiViewModel.autoCategorizeProgress.isEmpty {
                    HStack(spacing: 8) {
                        if aiViewModel.autoCategorizeRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(aiViewModel.autoCategorizeProgress)
                            .font(.caption)
                            .foregroundStyle(aiViewModel.autoCategorizeRunning ? .primary : .secondary)
                    }
                }

                if let error = aiViewModel.aiErrorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                if !aiViewModel.categorizationResponse.isEmpty {
                    Divider()

                    Text(aiViewModel.categorizationResponse)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !aiViewModel.categorizationSuggestions.isEmpty {
                        Divider()

                        HStack {
                            Text("Suggested Categories")
                                .font(.headline)
                            Spacer()
                            Button("Apply All") {
                                aiViewModel.applyAllCategorizations()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        ForEach(aiViewModel.categorizationSuggestions) { item in
                            categorizationCard(item)
                        }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("AI Auto-Categorize", systemImage: "tag.fill")
        }
    }

    private func categorizationCard(_ item: ClaudeAPIService.CategorizationSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.transactionDescription)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("$\(String(format: "%.2f", item.amount))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.category.hasPrefix("[NEW] ") {
                        Text(item.category.replacingOccurrences(of: "[NEW] ", with: ""))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    } else {
                        Text(item.category)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation { aiViewModel.applyCategorization(item) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
