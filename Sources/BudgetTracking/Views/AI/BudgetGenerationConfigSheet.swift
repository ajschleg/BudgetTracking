import SwiftUI

struct BudgetGenerationConfigSheet: View {
    @Bindable var viewModel: InsightsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Generate Budget")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }

            // Income display
            HStack {
                Text("Detected Monthly Income")
                    .font(.subheadline)

                Button {
                    viewModel.loadIncomeBreakdown()
                    viewModel.showIncomeBreakdown = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("View income sources")

                Spacer()

                if viewModel.monthlyIncome.isEmpty || viewModel.monthlyIncome == "0" {
                    Text("No income detected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("$\(viewModel.monthlyIncome)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }

            // Budget style picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Budget Style")
                    .font(.subheadline)
                Picker("Style", selection: $viewModel.budgetStyle) {
                    ForEach(ClaudeAPIService.BudgetStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.budgetStyle.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                    Task { await viewModel.generateBudget() }
                } label: {
                    Label("Generate Budget", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoadingBudgetGeneration || viewModel.isOverCap)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        .onAppear { viewModel.loadIncomeEstimate() }
        .sheet(isPresented: $viewModel.showIncomeBreakdown) {
            IncomeBreakdownSheet(viewModel: viewModel)
        }
    }
}
