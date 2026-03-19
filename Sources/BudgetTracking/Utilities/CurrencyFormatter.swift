import Foundation

enum CurrencyFormatter {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale.current
        return f
    }()

    static func format(_ amount: Double) -> String {
        formatter.string(from: NSNumber(value: amount)) ?? "$\(String(format: "%.2f", amount))"
    }

    static func formatShort(_ amount: Double) -> String {
        if abs(amount) >= 1000 {
            return "$\(String(format: "%.0f", amount))"
        }
        return format(amount)
    }
}
