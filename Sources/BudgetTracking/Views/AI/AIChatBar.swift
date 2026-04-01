import SwiftUI

struct AIChatBar: View {
    @Bindable var viewModel: InsightsViewModel
    let actions: [AIChatAction]
    let page: SidebarItem
    var onApplyBudget: (() -> Void)?

    private var chatState: PageChatState {
        viewModel.pageChatStates[page, default: PageChatState()]
    }

    private var isAnyLoading: Bool {
        viewModel.isLoadingAI || viewModel.isLoadingRules ||
        viewModel.isLoadingCategorization || viewModel.isLoadingBudgetGeneration ||
        viewModel.autoCategorizeRunning
    }

    private var hasResponse: Bool {
        let state = chatState
        if !state.aiResponse.isEmpty || !state.aiActions.isEmpty || state.aiErrorMessage != nil {
            return true
        }
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
            Divider()

            // Always-visible show/hide toggle bar
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.pageChatStates[page, default: PageChatState()].isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: chatState.isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2.weight(.semibold))
                    Text("AI Response")
                        .font(.caption)
                        .fontWeight(.medium)
                    if hasResponse {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasResponse ? .primary : .secondary)

            // Expandable response area
            if chatState.isExpanded && hasResponse {
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
                TextField("Ask AI...", text: Binding(
                    get: { viewModel.pageChatStates[page, default: PageChatState()].userQuestion },
                    set: { viewModel.pageChatStates[page, default: PageChatState()].userQuestion = $0 }
                ))
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
    }

    private func submitChat() async {
        await viewModel.askAI(page: page)
    }
}
