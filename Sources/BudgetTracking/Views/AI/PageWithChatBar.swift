import SwiftUI

struct PageWithChatBar<Content: View>: View {
    @Bindable var viewModel: InsightsViewModel
    let actions: [AIChatAction]
    let page: SidebarItem
    var onApplyBudget: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()

            if viewModel.isAPIKeyConfigured {
                AIChatBar(
                    viewModel: viewModel,
                    actions: actions,
                    page: page,
                    onApplyBudget: onApplyBudget
                )
            }
        }
    }
}
