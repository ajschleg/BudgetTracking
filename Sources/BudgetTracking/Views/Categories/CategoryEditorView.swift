import SwiftUI

struct CategoryEditorView: View {
    var category: BudgetCategory?
    let categories: [BudgetCategory]
    let onSave: (String, Double, String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var budgetText: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, budget
    }

    private let colorOptions: [(String, Color)] = [
        ("#4CAF50", .green),
        ("#2196F3", .blue),
        ("#FF9800", .orange),
        ("#E91E63", .pink),
        ("#9C27B0", .purple),
        ("#00BCD4", .cyan),
        ("#795548", .brown),
        ("#F44336", .red),
        ("#607D8B", .gray),
    ]

    @State private var selectedColorHex: String = "#4CAF50"

    init(
        category: BudgetCategory? = nil,
        categories: [BudgetCategory],
        onSave: @escaping (String, Double, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.category = category
        self.categories = categories
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(category == nil ? "Add Category" : "Edit Category")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Category Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)

            TextField("Monthly Budget", text: $budgetText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .budget)

            // Color picker
            HStack(spacing: 8) {
                Text("Color:")
                ForEach(colorOptions, id: \.0) { hex, color in
                    Button {
                        selectedColorHex = hex
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary, lineWidth: selectedColorHex == hex ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    let budget = Double(budgetText) ?? 0
                    onSave(name, budget, selectedColorHex)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            if let cat = category {
                name = cat.name
                budgetText = String(format: "%.0f", cat.monthlyBudget)
                selectedColorHex = cat.colorHex
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                focusedField = .name
            }
        }
    }
}

struct AddRuleView: View {
    let categories: [BudgetCategory]
    let onSave: (String, UUID) -> Void
    let onCancel: () -> Void

    @State private var keyword: String = ""
    @State private var selectedCategoryId: UUID?
    @FocusState private var isKeywordFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Categorization Rule")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Keyword (e.g., WHOLE FOODS)", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .focused($isKeywordFocused)

            Picker("Category", selection: $selectedCategoryId) {
                Text("Select...").tag(nil as UUID?)
                ForEach(categories) { cat in
                    Text(cat.name).tag(cat.id as UUID?)
                }
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Add Rule") {
                    if let catId = selectedCategoryId {
                        onSave(keyword, catId)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(keyword.isEmpty || selectedCategoryId == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isKeywordFocused = true
            }
        }
    }
}
