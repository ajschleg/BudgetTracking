import SwiftUI

struct OverallBudgetBar: View {
    let spent: Double
    let budget: Double
    let percentage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Overall Budget")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(CurrencyFormatter.format(spent)) / \(CurrencyFormatter.format(budget))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 30)

                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    ColorThresholds.color(forPercentage: percentage).opacity(0.8),
                                    ColorThresholds.color(forPercentage: percentage)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: min(geo.size.width * CGFloat(min(percentage, 1.0)), geo.size.width),
                            height: 30
                        )

                    Text("\(Int(percentage * 100))%")
                        .font(.callout)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.leading, 12)
                }
            }
            .frame(height: 30)

            let remaining = budget - spent
            Text(remaining >= 0
                 ? "\(CurrencyFormatter.format(remaining)) remaining this month"
                 : "\(CurrencyFormatter.format(abs(remaining))) over budget this month")
                .font(.subheadline)
                .foregroundStyle(remaining >= 0 ? .green : .red)
                .fontWeight(.medium)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}
