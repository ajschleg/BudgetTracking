import SwiftUI

enum ColorThresholds {
    static func color(forPercentage pct: Double) -> Color {
        switch pct {
        case ..<0.70:
            return .green
        case 0.70..<0.90:
            return .yellow
        default:
            return .red
        }
    }

    static func colorFromHex(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6,
              let rgb = UInt64(cleaned, radix: 16)
        else { return .gray }

        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
