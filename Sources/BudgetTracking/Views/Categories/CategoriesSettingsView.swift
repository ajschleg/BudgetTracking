import SwiftUI

struct CategoriesSettingsView: View {
    @Bindable var aiViewModel: InsightsViewModel
    @State private var viewModel = CategoriesViewModel()
    @State private var showAddCategory = false
    @State private var showAddRule = false
    @State private var editingCategory: BudgetCategory?
    @State private var showSaveDefaultsConfirmation = false

    var body: some View {
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

                    Button {
                        viewModel.restoreDefaults()
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(action: { showAddCategory = true }) {
                        Label("Add Category", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                // AI Generate Budget
                if aiViewModel.isAPIKeyConfigured {
                    generateBudgetSection
                }

                LazyVStack(spacing: 8) {
                    ForEach(viewModel.categories) { category in
                        CategoryRow(
                            category: category,
                            onEdit: { editingCategory = category },
                            onDelete: { viewModel.deleteCategory(category) },
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
                    Spacer()
                    Button(action: { showAddRule = true }) {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                // AI Suggest Rules
                if aiViewModel.isAPIKeyConfigured {
                    suggestRulesSection
                }

                if viewModel.rules.isEmpty {
                    Text("No rules configured. Rules are also auto-created when you manually categorize transactions.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.rules) { rule in
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
        .navigationTitle("Categories")
        .onAppear { viewModel.load() }
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
                },
                onCancel: { showAddRule = false }
            )
        }
        .alert("Overwrite Saved Defaults?", isPresented: $showSaveDefaultsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Overwrite", role: .destructive) {
                viewModel.saveAsDefaults()
            }
        } message: {
            Text("You already have saved default categories. This will replace them with your current categories.")
        }
    }
}

// MARK: - AI Sections

extension CategoriesSettingsView {
    var generateBudgetSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Detected Monthly Income")
                        .font(.subheadline)
                    Spacer()
                    if aiViewModel.monthlyIncome.isEmpty || aiViewModel.monthlyIncome == "0" {
                        Text("No income detected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("$\(aiViewModel.monthlyIncome)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Budget Style")
                        .font(.subheadline)
                    Picker("Style", selection: $aiViewModel.budgetStyle) {
                        ForEach(ClaudeAPIService.BudgetStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(aiViewModel.budgetStyle.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await aiViewModel.generateBudget() }
                    } label: {
                        if aiViewModel.isLoadingBudgetGeneration {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Generate Budget", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiViewModel.isLoadingBudgetGeneration || aiViewModel.isOverCap)
                }

                if let error = aiViewModel.aiErrorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                if !aiViewModel.budgetGenerationResponse.isEmpty {
                    Divider()

                    Text(aiViewModel.budgetGenerationResponse)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !aiViewModel.budgetAllocations.isEmpty {
                        Divider()

                        HStack {
                            Text("Proposed Budget")
                                .font(.headline)
                            Spacer()
                            let total = aiViewModel.budgetAllocations.reduce(0.0) { $0 + $1.amount }
                            Text("Total: $\(String(format: "%.0f", total))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(aiViewModel.budgetAllocations) { allocation in
                            budgetAllocationCard(allocation)
                        }

                        Button {
                            aiViewModel.showApplyBudgetConfirmation = true
                        } label: {
                            Label("Apply This Budget", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.large)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("AI Generate Budget", systemImage: "wand.and.stars")
        }
        .onAppear { aiViewModel.loadIncomeEstimate() }
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

    var suggestRulesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Analyze transactions and suggest keyword rules to auto-categorize them.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        Task { await aiViewModel.suggestRules() }
                    } label: {
                        if aiViewModel.isLoadingRules {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Suggest Rules", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiViewModel.isLoadingRules || aiViewModel.isOverCap)
                }

                if !aiViewModel.ruleResponse.isEmpty {
                    Divider()

                    Text(aiViewModel.ruleResponse)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    if !aiViewModel.ruleSuggestions.isEmpty {
                        Divider()

                        HStack {
                            Text("Suggested Rules")
                                .font(.headline)
                            Spacer()
                            Button("Apply All") {
                                aiViewModel.applyAllRules()
                                viewModel.load()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        ForEach(aiViewModel.ruleSuggestions) { rule in
                            ruleCard(rule)
                        }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("AI Suggest Rules", systemImage: "text.badge.checkmark")
        }
    }

    func budgetAllocationCard(_ allocation: ClaudeAPIService.BudgetAllocation) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if allocation.category.hasPrefix("[NEW] ") {
                        Text(allocation.category.replacingOccurrences(of: "[NEW] ", with: ""))
                            .font(.subheadline.weight(.semibold))
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    } else {
                        Text(allocation.category)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Text(allocation.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("$\(String(format: "%.0f", allocation.amount))")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func ruleCard(_ rule: ClaudeAPIService.RuleSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\"\(rule.keyword)\"")
                        .font(.subheadline.weight(.semibold).monospaced())
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rule.category)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                Text(rule.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation {
                    aiViewModel.applyRule(rule)
                    viewModel.load()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CategoryRow: View {
    let category: BudgetCategory
    let onEdit: () -> Void
    let onDelete: () -> Void
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
                        budgetText = String(format: "%.2f", category.monthlyBudget)
                        isEditingBudget = true
                        budgetFieldFocused = true
                    }
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
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
