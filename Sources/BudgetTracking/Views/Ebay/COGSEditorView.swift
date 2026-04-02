import SwiftUI

struct COGSEditorView: View {
    let orderId: UUID
    let existing: EbayCostOfGoods?
    let onSave: (Double, Double, String?) -> Void
    let onCancel: () -> Void

    @State private var costAmount: String = ""
    @State private var shippingCost: String = ""
    @State private var notes: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cost of Goods")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Item Cost")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("$0.00", text: $costAmount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Shipping")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("$0.00", text: $shippingCost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Optional", text: $notes)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Save") {
                    let cost = Double(costAmount) ?? 0
                    let shipping = Double(shippingCost) ?? 0
                    onSave(cost, shipping, notes.isEmpty ? nil : notes)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
        }
        .onAppear {
            if let existing {
                costAmount = existing.costAmount > 0 ? String(format: "%.2f", existing.costAmount) : ""
                shippingCost = existing.shippingCost > 0 ? String(format: "%.2f", existing.shippingCost) : ""
                notes = existing.notes ?? ""
            }
        }
    }
}
