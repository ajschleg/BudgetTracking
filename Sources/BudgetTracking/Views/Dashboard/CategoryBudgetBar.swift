import SwiftUI

struct CategoryBudgetBar: View {
    let category: BudgetCategory
    let spent: Double
    let percentage: Double
    var isExpanded: Bool = false
    var transactions: [Transaction] = []
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category header (clickable)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle()
                        .fill(ColorThresholds.colorFromHex(category.colorHex))
                        .frame(width: 10, height: 10)

                    Text(category.name)
                        .font(.headline)

                    Spacer()

                    if onTap != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("\(CurrencyFormatter.format(spent)) / \(CurrencyFormatter.format(category.monthlyBudget))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 20)

                        // Fill
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ColorThresholds.color(forPercentage: percentage))
                            .frame(
                                width: min(geo.size.width * CGFloat(min(percentage, 1.0)), geo.size.width),
                                height: 20
                            )

                        // Percentage label
                        if percentage > 0.1 {
                            Text("\(Int(percentage * 100))%")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.leading, 8)
                        }
                    }
                }
                .frame(height: 20)

                if category.monthlyBudget > 0 {
                    let remaining = category.monthlyBudget - spent
                    Text(remaining >= 0
                         ? "\(CurrencyFormatter.format(remaining)) remaining"
                         : "\(CurrencyFormatter.format(abs(remaining))) over budget")
                        .font(.caption)
                        .foregroundColor(remaining >= 0 ? .secondary : .red)
                }
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }

            // Expanded transaction list
            if isExpanded {
                Divider()
                    .padding(.horizontal)

                if transactions.isEmpty {
                    Text("No transactions in this category")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    VStack(spacing: 0) {
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

                                Text(CurrencyFormatter.format(abs(txn.amount)))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)

                            if txn.id != transactions.last?.id {
                                Divider()
                                    .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}
