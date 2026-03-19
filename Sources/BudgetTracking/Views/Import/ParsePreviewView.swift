import SwiftUI

struct ParsePreviewView: View {
    let rows: [ParsedRow]
    let fileName: String
    @Binding var positiveIsSpending: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "doc.text")
                Text(fileName)
                    .font(.headline)
                Spacer()
                Text("\(rows.count) transactions found")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // Sign convention toggle
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.blue)
                Toggle(isOn: $positiveIsSpending) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Positive amounts = money spent")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Enable for statements like Apple Card where charges are positive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal)

            // Preview table
            ScrollView {
                LazyVStack(spacing: 1) {
                    // Header
                    HStack {
                        Text("Date")
                            .frame(width: 100, alignment: .leading)
                        Text("Description")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Original")
                            .frame(width: 90, alignment: .trailing)
                        Text("As Imported")
                            .frame(width: 90, alignment: .trailing)
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)

                    ForEach(Array(rows.prefix(50).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.date.map { DateHelpers.shortDate($0) } ?? "N/A")
                                .frame(width: 100, alignment: .leading)
                            Text(row.description ?? "N/A")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(row.amount.map { CurrencyFormatter.format($0) } ?? "N/A")
                                .frame(width: 90, alignment: .trailing)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(row.amount.map { CurrencyFormatter.format(normalizedAmount($0)) } ?? "N/A")
                                .frame(width: 90, alignment: .trailing)
                                .monospacedDigit()
                                .fontWeight(.medium)
                        }
                        .font(.callout)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }

                    if rows.count > 50 {
                        Text("... and \(rows.count - 50) more transactions")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            // Action buttons
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Import \(rows.count) Transactions") { onConfirm() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func normalizedAmount(_ amount: Double) -> Double {
        positiveIsSpending ? -amount : amount
    }
}
