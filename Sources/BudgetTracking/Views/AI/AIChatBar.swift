import SwiftUI

struct AIChatBar: View {
    @Bindable var viewModel: InsightsViewModel
    let actions: [AIChatAction]
    let page: SidebarItem
    var onApplyBudget: (() -> Void)?

    @State private var isResponseExpanded = false

    private var isAnyLoading: Bool {
        viewModel.isLoadingAI || viewModel.isLoadingRules ||
        viewModel.isLoadingCategorization || viewModel.isLoadingBudgetGeneration ||
        viewModel.autoCategorizeRunning
    }

    private var hasResponse: Bool {
        // General chat response (available on all pages)
        if !viewModel.aiResponse.isEmpty || !viewModel.aiActions.isEmpty || viewModel.aiErrorMessage != nil {
            return true
        }
        // Page-specific responses
        switch page {
        case .transactions:
            return !viewModel.categorizationResponse.isEmpty ||
                   !viewModel.autoCategorizeProgress.isEmpty
        case .categories:
            return !viewModel.budgetGenerationResponse.isEmpty ||
                   !viewModel.ruleResponse.isEmpty ||
                   !viewModel.budgetAllocations.isEmpty ||
                   !viewModel.ruleSuggestions.isEmpty
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Expandable response area
            if isResponseExpanded && hasResponse {
                Divider()

                ScrollView {
                    AIChatResponseView(
                        viewModel: viewModel,
                        page: page,
                        onApplyBudget: onApplyBudget
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 300)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider()

            // Input row
            HStack(spacing: 8) {
                // Quick action buttons
                ForEach(actions) { action in
                    Button {
                        Task { await action.action() }
                    } label: {
                        Label(action.label, systemImage: action.icon)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAnyLoading || viewModel.isOverCap)
                }

                // Divider between buttons and text field
                if !actions.isEmpty {
                    Divider()
                        .frame(height: 20)
                }

                // Chat text field
                TextField("Ask AI...", text: $viewModel.userQuestion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await submitChat() }
                    }

                // Send button
                Button {
                    Task { await submitChat() }
                } label: {
                    if isAnyLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnyLoading || viewModel.isOverCap)

                // Expand/collapse toggle
                if hasResponse {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isResponseExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isResponseExpanded ? "chevron.down" : "chevron.up")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(isResponseExpanded ? "Collapse response" : "Expand response")
                }

                // Usage indicator
                Text("$\(String(format: "%.2f", viewModel.monthlySpend))")
                    .font(.system(size: 10))
                    .foregroundStyle(viewModel.isOverCap ? .red : .secondary)
                    .help("Usage: $\(String(format: "%.2f", viewModel.monthlySpend)) / $\(String(format: "%.2f", viewModel.monthlyCap)) cap")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: hasResponse) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isResponseExpanded = true
                }
            }
        }
    }

    private func submitChat() async {
        // Default behavior: general AI analysis
        await viewModel.askAI()
    }
}
