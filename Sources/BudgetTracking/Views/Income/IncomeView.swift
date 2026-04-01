import SwiftUI

struct IncomeView: View {
    @Binding var selectedMonth: String
    @Bindable var aiViewModel: InsightsViewModel
    @State private var viewModel = IncomeViewModel()

    var body: some View {
        PageWithChatBar(
            viewModel: aiViewModel,
            actions: [
                AIChatAction(label: "Analyze Income", icon: "sparkles") {
                    await aiViewModel.askAI()
                }
            ],
            page: .income
        ) {
            ScrollView {
                VStack(spacing: 20) {
                    MonthSelectorView(selectedMonth: $selectedMonth)
                        .padding(.top)

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
                        Text("No income transactions this month.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Income")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.isManagingSourcesPresented = true
                } label: {
                    Label("Manage Sources", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $viewModel.isManagingSourcesPresented) {
            ManageSourcesSheet(viewModel: viewModel)
        }
        .onAppear { viewModel.load(month: selectedMonth) }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.load(month: newMonth)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load(month: selectedMonth)
        }
    }

    // MARK: - Total Income Banner

    private var totalIncomeBanner: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
            Text("Total Income")
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
            // Header
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
                    if viewModel.expandedSourceId == source.id {
                        viewModel.expandedSourceId = nil
                    } else {
                        viewModel.expandedSourceId = source.id
                    }
                }
            }

            // Expanded transaction list
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

                Image(systemName: viewModel.expandedSourceId == nil && uncategorizedExpanded ? "chevron.up" : "chevron.down")
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
                        HStack {
                            transactionRow(txn)
                        }

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

    @State private var uncategorizedExpanded = false

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

// MARK: - Manage Sources Sheet

struct ManageSourcesSheet: View {
    @Bindable var viewModel: IncomeViewModel
    @State private var newSourceName = ""
    @State private var newSourceKeywords = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Manage Income Sources")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            // Existing sources
            List {
                ForEach(viewModel.sources) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.name)
                                .font(.body)
                            Text("Keywords: \(source.keywords.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            viewModel.deleteSource(source.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 150)

            Divider()

            // Add new source
            HStack {
                TextField("Source name", text: $newSourceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                TextField("Keywords (comma-separated)", text: $newSourceKeywords)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    let keywords = newSourceKeywords
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                        .filter { !$0.isEmpty }
                    guard !newSourceName.isEmpty else { return }
                    viewModel.addSource(
                        name: newSourceName,
                        keywords: keywords.isEmpty ? [newSourceName.uppercased()] : keywords
                    )
                    newSourceName = ""
                    newSourceKeywords = ""
                }
                .disabled(newSourceName.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 350)
    }
}
