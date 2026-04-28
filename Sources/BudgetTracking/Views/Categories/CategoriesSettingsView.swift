import SwiftUI

struct CategoriesSettingsView: View {
    @Bindable var aiViewModel: InsightsViewModel
    @AppStorage("isEditingLocked") private var isEditingLocked = true
    @State private var viewModel = CategoriesViewModel()
    @State private var showAddCategory = false
    @State private var showAddRule = false
    @State private var editingCategory: BudgetCategory?
    @State private var showSaveDefaultsConfirmation = false
    @State private var ruleApplyMessage: String?
    @State private var ruleSearchText: String = ""
    @State private var categorySearchText: String = ""
    @State private var showBudgetGenerationConfig = false

    private var filteredCategories: [BudgetCategory] {
        guard !categorySearchText.isEmpty else { return viewModel.categories }
        return viewModel.categories.filter {
            $0.name.localizedCaseInsensitiveContains(categorySearchText)
        }
    }

    private var filteredRules: [CategorizationRule] {
        guard !ruleSearchText.isEmpty else { return viewModel.rules }
        return viewModel.rules.filter {
            $0.keyword.localizedCaseInsensitiveContains(ruleSearchText) ||
            viewModel.categoryName(for: $0.categoryId).localizedCaseInsensitiveContains(ruleSearchText)
        }
    }

    var body: some View {
        PageWithChatBar(
            viewModel: aiViewModel,
            actions: [
                AIChatAction(label: "Generate Budget", icon: "wand.and.stars") { @MainActor in
                    showBudgetGenerationConfig = true
                },
                AIChatAction(label: "Suggest Rules", icon: "text.badge.checkmark") {
                    await aiViewModel.suggestRules()
                }
            ],
            page: .categories,
            onApplyBudget: { viewModel.load() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Categories section
                    HStack {
                        Text("Budget Categories")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Spacer()
                        Button {
                            if viewModel.hasSavedDefaults {
                                showSaveDefaultsConfirmation = true
                            } else {
                                viewModel.saveAsDefaults()
                            }
                        } label: {
                            Label("Save as Defaults", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isEditingLocked)

                        Button {
                            viewModel.restoreDefaults()
                        } label: {
                            Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isEditingLocked)

                        Button(action: { showAddCategory = true }) {
                            Label("Add Category", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isEditingLocked)
                    }

                    if !viewModel.categories.isEmpty {
                        TextField("Search categories...", text: $categorySearchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                    }

                    LazyVStack(spacing: 8) {
                        ForEach(filteredCategories) { category in
                            CategoryRow(
                                category: category,
                                isLocked: isEditingLocked,
                                onEdit: { editingCategory = category },
                                onDelete: { viewModel.deleteCategory(category) },
                                onToggleHidden: { viewModel.toggleHidden(category) },
                                onUpdateBudget: { newBudget in
                                    var updated = category
                                    updated.monthlyBudget = newBudget
                                    viewModel.updateCategory(updated)
                                },
                                onUpdateName: { newName in
                                    var updated = category
                                    updated.name = newName
                                    viewModel.updateCategory(updated)
                                }
                            )
                        }
                    }

                    Divider()

                    // Categorization rules section
                    HStack {
                        Text("Categorization Rules")
                            .font(.title2)
                            .fontWeight(.semibold)

                        if let message = ruleApplyMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.green)
                                .transition(.opacity)
                        }

                        Spacer()
                        Button(action: { showAddRule = true }) {
                            Label("Add Rule", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isEditingLocked)
                    }

                    if !viewModel.rules.isEmpty {
                        TextField("Search rules...", text: $ruleSearchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                    }

                    if viewModel.rules.isEmpty {
                        Text("No rules configured. Rules are also auto-created when you manually categorize transactions.")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredRules) { rule in
                                HStack {
                                    Text("\"\(rule.keyword)\"")
                                        .fontWeight(.medium)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.categoryName(for: rule.categoryId))
                                        .foregroundStyle(.blue)
                                    Spacer()
                                    if !rule.isUserDefined {
                                        Text("learned")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.1))
                                            .cornerRadius(4)
                                    }
                                    Text("\(rule.matchCount) matches")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button(role: .destructive) {
                                        viewModel.deleteRule(rule)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isEditingLocked)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Categories")
        .onAppear {
            viewModel.load()
            aiViewModel.loadIncomeEstimate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.load()
        }
        .sheet(isPresented: $showAddCategory) {
            CategoryEditorView(
                categories: viewModel.categories,
                onSave: { name, budget, color in
                    viewModel.addCategory(name: name, budget: budget, colorHex: color)
                    showAddCategory = false
                },
                onCancel: { showAddCategory = false }
            )
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
                    viewModel.updateCategory(updated)
                    editingCategory = nil
                },
                onCancel: { editingCategory = nil }
            )
        }
        .sheet(isPresented: $showAddRule) {
            AddRuleView(
                categories: viewModel.categories,
                onSave: { keyword, categoryId in
                    viewModel.addRule(keyword: keyword, categoryId: categoryId)
                    showAddRule = false
                    let count = viewModel.lastRuleApplyCount
                    if count > 0 {
                        withAnimation {
                            ruleApplyMessage = "Rule applied to \(count) transaction\(count == 1 ? "" : "s")."
                        }
                    }
                },
                onCancel: { showAddRule = false }
            )
        }
        .sheet(isPresented: $showBudgetGenerationConfig) {
            BudgetGenerationConfigSheet(viewModel: aiViewModel)
        }
        .alert("Overwrite Saved Defaults?", isPresented: $showSaveDefaultsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Overwrite", role: .destructive) {
                viewModel.saveAsDefaults()
            }
        } message: {
            Text("You already have saved default categories. This will replace them with your current categories.")
        }
        .alert("Apply Budget?", isPresented: $aiViewModel.showApplyBudgetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Apply", role: .destructive) {
                withAnimation {
                    aiViewModel.applyGeneratedBudget()
                    viewModel.load()
                }
            }
        } message: {
            Text("This will overwrite all current category budgets with the AI-generated amounts. New categories will be created as needed.")
        }
    }
}

// MARK: - Income Breakdown Sheet

struct IncomeBreakdownSheet: View {
    var viewModel: InsightsViewModel
    @Environment(\.dismiss) private var dismiss

    private var transactions: [Transaction] { viewModel.incomeTransactions }
    private var includedTotal: Double {
        transactions
            .filter { !viewModel.isIncomeExcluded($0.id) }
            .reduce(0.0) { $0 + $1.amount }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Income Sources")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if transactions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "banknote")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No income transactions found this month")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transactions) { txn in
                            incomeRow(txn)
                            Divider()
                        }
                    }
                }

                Divider()

                HStack {
                    Text("Included Total")
                        .font(.headline)
                    Spacer()
                    Text(CurrencyFormatter.format(includedTotal))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.green)
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func incomeRow(_ txn: Transaction) -> some View {
        let excluded = viewModel.isIncomeExcluded(txn.id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.description)
                    .font(.body)
                    .lineLimit(1)
                    .strikethrough(excluded)
                    .foregroundStyle(excluded ? .secondary : .primary)
                Text(DateHelpers.shortDate(txn.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(CurrencyFormatter.format(txn.amount))
                .font(.body.monospacedDigit())
                .foregroundColor(excluded ? .secondary : .green)

            Button {
                withAnimation { viewModel.toggleIncomeExclusion(txn.id) }
            } label: {
                Image(systemName: excluded ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundColor(excluded ? .red : .green)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct CategoryRow: View {
    let category: BudgetCategory
    let isLocked: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleHidden: () -> Void
    let onUpdateBudget: (Double) -> Void
    let onUpdateName: (String) -> Void

    @State private var isEditingBudget = false
    @State private var budgetText = ""
    @FocusState private var budgetFieldFocused: Bool

    @State private var isEditingName = false
    @State private var nameText = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(ColorThresholds.colorFromHex(category.colorHex))
                .frame(width: 14, height: 14)

            if isEditingName {
                TextField("Name", text: $nameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .font(.headline)
                    .focused($nameFieldFocused)
                    .onSubmit {
                        commitNameEdit()
                    }
                    .onExitCommand {
                        cancelNameEdit()
                    }
                    .onChange(of: nameFieldFocused) { _, focused in
                        if !focused {
                            cancelNameEdit()
                        }
                    }
            } else {
                Text(category.name)
                    .font(.headline)
                    .onTapGesture(count: 2) {
                        guard !isLocked else { return }
                        nameText = category.name
                        isEditingName = true
                        nameFieldFocused = true
                    }
            }

            Spacer()

            if isEditingBudget {
                TextField("Budget", text: $budgetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .monospacedDigit()
                    .focused($budgetFieldFocused)
                    .onSubmit {
                        commitBudgetEdit()
                    }
                    .onExitCommand {
                        cancelBudgetEdit()
                    }
                    .onChange(of: budgetFieldFocused) { _, focused in
                        if !focused {
                            cancelBudgetEdit()
                        }
                    }
            } else {
                Text(CurrencyFormatter.format(category.monthlyBudget))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .onTapGesture(count: 2) {
                        guard !isLocked else { return }
                        budgetText = String(format: "%.2f", category.monthlyBudget)
                        isEditingBudget = true
                        budgetFieldFocused = true
                    }
            }

            Button(action: onToggleHidden) {
                Image(systemName: category.isHiddenFromDashboard ? "eye.slash" : "eye")
                    .foregroundStyle(category.isHiddenFromDashboard ? Color.secondary : Color.blue)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .help(category.isHiddenFromDashboard
                  ? "Hidden from dashboard — click to show"
                  : "Showing on dashboard — click to hide")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .disabled(isLocked)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .opacity(category.isHiddenFromDashboard ? 0.55 : 1)
    }

    private func commitBudgetEdit() {
        if let newBudget = Double(budgetText), newBudget >= 0 {
            onUpdateBudget(newBudget)
        }
        isEditingBudget = false
    }

    private func cancelBudgetEdit() {
        isEditingBudget = false
    }

    private func commitNameEdit() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            onUpdateName(trimmed)
        }
        isEditingName = false
    }

    private func cancelNameEdit() {
        isEditingName = false
    }
}
