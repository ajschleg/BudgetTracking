import SwiftUI

struct SourcingCategoriesSheet: View {
    @Bindable var viewModel: SideHustleViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sourcing Categories")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Select which budget categories contain sourcing costs (e.g. thrift store purchases, wholesale buys). All spending in these categories will be subtracted from your side hustle earnings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(viewModel.allCategories) { category in
                    HStack {
                        Image(systemName: viewModel.sourcingCategoryIds.contains(category.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(viewModel.sourcingCategoryIds.contains(category.id) ? .blue : .secondary)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name)
                                .font(.body)

                            if viewModel.sourcingCategoryIds.contains(category.id) {
                                let txns = viewModel.categorySourcingTransactions.filter { $0.categoryId == category.id }
                                let total = txns.reduce(0.0) { $0 + abs($1.amount) }
                                Text("\(txns.count) transactions - \(CurrencyFormatter.format(total))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        RoundedRectangle(cornerRadius: 3)
                            .fill(ColorThresholds.colorFromHex(category.colorHex))
                            .frame(width: 16, height: 16)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.toggleSourcingCategory(category.id)
                    }
                }
            }
            .frame(minHeight: 250)
        }
        .padding(20)
        .frame(minWidth: 450, minHeight: 400)
    }
}
