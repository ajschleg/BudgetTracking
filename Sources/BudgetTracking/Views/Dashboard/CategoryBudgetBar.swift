import SwiftUI

struct CategoryBudgetBar: View {
    let category: BudgetCategory
    let spent: Double
    let percentage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(ColorThresholds.colorFromHex(category.colorHex))
                    .frame(width: 10, height: 10)

                Text(category.name)
                    .font(.headline)

                Spacer()

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
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}
