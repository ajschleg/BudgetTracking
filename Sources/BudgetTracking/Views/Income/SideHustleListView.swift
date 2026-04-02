import SwiftUI

struct SideHustleListView: View {
    @Bindable var viewModel: SideHustleViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(viewModel.sources, selection: $viewModel.selectedSourceId) { source in
                HStack {
                    if source.isEbay {
                        Image(systemName: "bag.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else {
                        Image(systemName: "dollarsign.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name)
                            .font(.subheadline)
                        let total = viewModel.total(for: source.id)
                        if total > 0 {
                            Text(CurrencyFormatter.format(total))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                }
                .tag(source.id)
                .contextMenu {
                    if !source.isDefault {
                        Button(role: .destructive) {
                            viewModel.deleteSideHustle(source.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                viewModel.isAddingSideHustle = true
            } label: {
                Label("Add Side Hustle", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }
}
