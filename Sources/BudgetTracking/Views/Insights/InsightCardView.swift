import SwiftUI

struct InsightCardView: View {
    let insight: BudgetInsight
    var onDismissReturn: ((UUID) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.iconName)
                .font(.title2)
                .foregroundStyle(severityColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 6) {
                Text(insight.title)
                    .font(.headline)

                Text(insight.description)
                    .font(.body)
                    .foregroundStyle(.secondary)

                if let action = insight.suggestedAction {
                    Label(action, systemImage: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(severityColor)
                        .padding(.top, 2)
                }

                // "Not a Return" button for return insights
                if insight.type == .returnDetected, let txnId = insight.relatedTransactionId {
                    Button {
                        withAnimation { onDismissReturn?(txnId) }
                    } label: {
                        Label("Not a Return", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(severityColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(severityColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var severityColor: Color {
        switch insight.severity {
        case .alert: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
