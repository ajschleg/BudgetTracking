import SwiftUI

struct SideHustleTabView: View {
    @Bindable var viewModel: SideHustleViewModel
    @Bindable var ebayViewModel: EbayEarningsViewModel
    let ebayAuthManager: EbayAuthManager
    @Binding var selectedMonth: String

    var body: some View {
        VStack(spacing: 0) {
            // Combined banner
            SideHustleBannerView(viewModel: viewModel, selectedMonth: selectedMonth)
                .padding(.horizontal)
                .padding(.vertical, 8)

            // Side hustle list + detail — fills remaining space
            HSplitView {
                SideHustleListView(viewModel: viewModel)
                    .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)

                // Detail view
                if let selectedId = viewModel.selectedSourceId,
                   let source = viewModel.sources.first(where: { $0.id == selectedId }) {
                    if source.isEbay {
                        EbayEarningsView(
                            selectedMonth: $selectedMonth,
                            ebayAuthManager: ebayAuthManager,
                            viewModel: ebayViewModel
                        )
                    } else {
                        SideHustleDetailView(
                            source: source,
                            viewModel: viewModel,
                            selectedMonth: selectedMonth
                        )
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("Select a side hustle")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $viewModel.isAddingSideHustle) {
            AddSideHustleSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Add Side Hustle Sheet

struct AddSideHustleSheet: View {
    @Bindable var viewModel: SideHustleViewModel
    @State private var name = ""
    @State private var keywords = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Side Hustle")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }

            TextField("Name (e.g. Poshmark, Mercari)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Keywords for matching bank transactions (comma-separated)", text: $keywords)
                .textFieldStyle(.roundedBorder)

            Text("Keywords are used to automatically match income transactions from your bank imports.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Add") {
                    let kws = keywords
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                        .filter { !$0.isEmpty }
                    guard !name.isEmpty else { return }
                    viewModel.addSideHustle(
                        name: name,
                        keywords: kws.isEmpty ? [name.uppercased()] : kws
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 200)
    }
}
