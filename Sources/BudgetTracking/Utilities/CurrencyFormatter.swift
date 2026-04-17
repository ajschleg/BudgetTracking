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

    /// Format with a specific ISO 4217 currency code (e.g. "USD", "EUR").
    /// Falls back to the locale default if code is nil.
    static func format(_ amount: Double, code: String?) -> String {
        guard let code, !code.isEmpty else { return format(amount) }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = Locale.current
        return f.string(from: NSNumber(value: amount)) ?? format(amount)
    }

    static func formatShort(_ amount: Double) -> String {
        if abs(amount) >= 1000 {
            return "$\(String(format: "%.0f", amount))"
        }
        return format(amount)
    }
}
