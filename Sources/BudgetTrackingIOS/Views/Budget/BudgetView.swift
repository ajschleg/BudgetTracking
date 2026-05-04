import SwiftUI

/// iOS Budget tab: manage categories and per-category monthly budgets.
/// Backed by the shared CategoriesViewModel so adds/edits/deletes route
/// through the same DatabaseManager + CloudKit pipeline as macOS.
struct BudgetView: View {
    @State private var viewModel = CategoriesViewModel()
    @State private var editingCategory: BudgetCategory?
    @State private var showingNewCategorySheet = false
    @State private var dataChangeCounter = 0

    private var visibleCategories: [BudgetCategory] {
        viewModel.categories.filter { !$0.isHiddenFromDashboard }
    }

    private var hiddenCategories: [BudgetCategory] {
        viewModel.categories.filter { $0.isHiddenFromDashboard }
    }

    private var totalBudget: Double {
        visibleCategories.reduce(0) { $0 + $1.monthlyBudget }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = viewModel.errorMessage {
                    InlineErrorRow(message: error).padding(16)
                } else if viewModel.categories.isEmpty {
                    EmptyState()
                } else {
                    List {
                        Section {
                            HStack {
                                Text("Total monthly budget")
                                    .font(.subheadline)
                                Spacer()
                                Text(CurrencyFormatter.format(totalBudget))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }

                        Section("Categories") {
                            ForEach(visibleCategories) { category in
                                CategoryRow(category: category)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editingCategory = category }
                            }
                            .onDelete { indexSet in
                                for idx in indexSet {
                                    viewModel.deleteCategory(visibleCategories[idx])
                                }
                            }
                        }

                        if !hiddenCategories.isEmpty {
                            Section {
                                ForEach(hiddenCategories) { category in
                                    CategoryRow(category: category)
                                        .contentShape(Rectangle())
                                        .onTapGesture { editingCategory = category }
                                }
                                .onDelete { indexSet in
                                    for idx in indexSet {
                                        viewModel.deleteCategory(hiddenCategories[idx])
                                    }
                                }
                            } header: {
                                Text("Hidden from Dashboard")
                            } footer: {
                                Text("Categories like Money Transfers and Credit Card Payments stay out of the dashboard totals so they don't double-count.")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewCategorySheet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { viewModel.load() }
            .task(id: dataChangeCounter) { viewModel.load() }
            .task {
                let center = NotificationCenter.default
                for await _ in center.notifications(named: .localDataDidChange) {
                    dataChangeCounter &+= 1
                }
            }
            .sheet(item: $editingCategory) { category in
                CategoryEditorSheet(
                    initial: category,
                    onSave: { updated in
                        viewModel.updateCategory(updated)
                        editingCategory = nil
                    }
                )
            }
            .sheet(isPresented: $showingNewCategorySheet) {
                CategoryEditorSheet(
                    initial: nil,
                    onSave: { new in
                        viewModel.addCategory(
                            name: new.name,
                            budget: new.monthlyBudget,
                            colorHex: new.colorHex
                        )
                        showingNewCategorySheet = false
                    }
                )
            }
        }
    }
}

// MARK: - Row

private struct CategoryRow: View {
    let category: BudgetCategory

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(ColorThresholds.colorFromHex(category.colorHex))
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.subheadline)
                if category.isIncomeCategory {
                    Text("Income source")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Text(CurrencyFormatter.format(category.monthlyBudget))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor Sheet

private struct CategoryEditorSheet: View {
    /// nil means "create a new category"; non-nil means "edit this one".
    let initial: BudgetCategory?
    let onSave: (BudgetCategory) -> Void

    @State private var name: String
    @State private var monthlyBudget: Double
    @State private var colorHex: String
    @State private var isHiddenFromDashboard: Bool
    @State private var isIncomeCategory: Bool

    @Environment(\.dismiss) private var dismiss

    /// A small fixed palette so users on iOS aren't picking arbitrary hex
    /// strings. Mirrors the colors the macOS Categories editor exposes.
    private static let palette: [String] = [
        "#34C759", "#FF9500", "#007AFF", "#AF52DE", "#FF3B30",
        "#5856D6", "#FF2D55", "#5AC8FA", "#FFCC00", "#8E8E93",
    ]

    init(initial: BudgetCategory?, onSave: @escaping (BudgetCategory) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _monthlyBudget = State(initialValue: initial?.monthlyBudget ?? 0)
        _colorHex = State(initialValue: initial?.colorHex ?? Self.palette.first!)
        _isHiddenFromDashboard = State(initialValue: initial?.isHiddenFromDashboard ?? false)
        _isIncomeCategory = State(initialValue: initial?.isIncomeCategory ?? false)
    }

    private var saveDisabled: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Groceries", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Monthly budget") {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("0", value: $monthlyBudget, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Self.palette, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(ColorThresholds.colorFromHex(hex))
                                        .frame(width: 36, height: 36)
                                    if hex == colorHex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                            .font(.callout.weight(.bold))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if initial != nil {
                    Section {
                        Toggle("Hide from Dashboard", isOn: $isHiddenFromDashboard)
                        Toggle("Income source", isOn: $isIncomeCategory)
                    } footer: {
                        Text("Hidden categories (e.g. Money Transfers) don't count toward the dashboard total. Income sources show up under the green income card.")
                    }
                }
            }
            .navigationTitle(initial == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saveDisabled)
                }
            }
        }
    }

    private func save() {
        if var existing = initial {
            existing.name = name.trimmingCharacters(in: .whitespaces)
            existing.monthlyBudget = monthlyBudget
            existing.colorHex = colorHex
            existing.isHiddenFromDashboard = isHiddenFromDashboard
            existing.isIncomeCategory = isIncomeCategory
            onSave(existing)
        } else {
            // For new categories, sortOrder/init args get filled in by
            // CategoriesViewModel.addCategory; we only carry the user-
            // entered fields back through the closure.
            let staged = BudgetCategory(
                name: name.trimmingCharacters(in: .whitespaces),
                monthlyBudget: monthlyBudget,
                colorHex: colorHex,
                sortOrder: 0
            )
            onSave(staged)
        }
    }
}

// MARK: - Empty / error

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No categories yet")
                .font(.headline)
            Text("Tap + to create your first category, or sign into iCloud to pull categories down from your Mac.")
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
            Text(message).font(.footnote)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
