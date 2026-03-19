import SwiftUI

struct CategoriesSettingsView: View {
    @State private var viewModel = CategoriesViewModel()
    @State private var showAddCategory = false
    @State private var showAddRule = false
    @State private var editingCategory: BudgetCategory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Categories section
                HStack {
                    Text("Budget Categories")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button(action: { showAddCategory = true }) {
                        Label("Add Category", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                LazyVStack(spacing: 8) {
                    ForEach(viewModel.categories) { category in
                        CategoryRow(
                            category: category,
                            onEdit: { editingCategory = category },
                            onDelete: { viewModel.deleteCategory(category) }
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
    }
}

struct CategoryRow: View {
    let category: BudgetCategory
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(ColorThresholds.colorFromHex(category.colorHex))
                .frame(width: 14, height: 14)

            Text(category.name)
                .font(.headline)

            Spacer()

            Text(CurrencyFormatter.format(category.monthlyBudget))
                .foregroundStyle(.secondary)
                .monospacedDigit()

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
}
