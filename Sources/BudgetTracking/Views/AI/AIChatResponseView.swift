import SwiftUI

struct AIChatResponseView: View {
    @Bindable var viewModel: InsightsViewModel
    let page: SidebarItem
    var onApplyBudget: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Error display
            if let error = viewModel.aiErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // General AI response (from free-form chat, available on all pages)
            if !viewModel.aiResponse.isEmpty {
                Text(viewModel.aiResponse)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // General AI action cards (from free-form chat)
            aiActionCards

            // Page-specific content below general response
            pageSpecificContent
        }
    }

    // MARK: - Page-Specific Content

    @ViewBuilder
    private var pageSpecificContent: some View {
        switch page {
        case .transactions:
            // Auto-categorize progress
            if !viewModel.autoCategorizeProgress.isEmpty {
                HStack(spacing: 8) {
                    if viewModel.autoCategorizeRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.autoCategorizeProgress)
                        .font(.caption)
                        .foregroundStyle(viewModel.autoCategorizeRunning ? .primary : .secondary)
                }
            }

            // Categorization response text
            if !viewModel.categorizationResponse.isEmpty {
                Text(viewModel.categorizationResponse)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            categorizationCards

        case .categories:
            // Budget generation response
            if !viewModel.budgetGenerationResponse.isEmpty {
                Text(viewModel.budgetGenerationResponse)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            budgetAllocationCards

            // Rule suggestion response
            if !viewModel.ruleResponse.isEmpty && viewModel.budgetGenerationResponse.isEmpty {
                Text(viewModel.ruleResponse)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ruleSuggestionCards

        default:
            EmptyView()
        }
    }

    // MARK: - AI Action Cards (general analysis)

    @ViewBuilder
    private var aiActionCards: some View {
        if !viewModel.aiActions.isEmpty {
            Divider()

            HStack {
                Text("Suggested Actions")
                    .font(.headline)
                Spacer()
                Button("Apply All") {
                    withAnimation { viewModel.applyAllActions() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ForEach(viewModel.aiActions) { action in
                actionCard(action)
            }
        }
    }

    // MARK: - Categorization Cards (Transactions page)

    @ViewBuilder
    private var categorizationCards: some View {
        if !viewModel.categorizationSuggestions.isEmpty {
            Divider()

            HStack {
                Text("Suggested Categories")
                    .font(.headline)
                Spacer()
                Button("Apply All") {
                    viewModel.applyAllCategorizations()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ForEach(viewModel.categorizationSuggestions) { item in
                categorizationCard(item)
            }
        }
    }

    // MARK: - Budget Allocation Cards (Categories page)

    @ViewBuilder
    private var budgetAllocationCards: some View {
        if !viewModel.budgetAllocations.isEmpty {
            Divider()

            HStack {
                Text("Proposed Budget")
                    .font(.headline)
                Spacer()
                let total = viewModel.budgetAllocations.reduce(0.0) { $0 + $1.amount }
                Text("Total: $\(String(format: "%.0f", total))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.budgetAllocations) { allocation in
                budgetAllocationCard(allocation)
            }

            Button {
                viewModel.showApplyBudgetConfirmation = true
            } label: {
                Label("Apply This Budget", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
    }

    // MARK: - Rule Suggestion Cards (Categories page)

    @ViewBuilder
    private var ruleSuggestionCards: some View {
        if !viewModel.ruleSuggestions.isEmpty {
            Divider()

            HStack {
                Text("Suggested Rules")
                    .font(.headline)
                Spacer()
                Button("Apply All") {
                    viewModel.applyAllRules()
                    onApplyBudget?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ForEach(viewModel.ruleSuggestions) { rule in
                ruleCard(rule)
            }
        }
    }

    // MARK: - Card Views

    private func actionCard(_ action: ClaudeAPIService.AIAction) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                switch action {
                case .budgetChange(let s):
                    HStack(spacing: 6) {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text("Budget: \(s.category)")
                            .font(.subheadline.weight(.semibold))
                    }
                    HStack(spacing: 4) {
                        Text("$\(String(format: "%.0f", s.currentBudget))")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.0f", s.suggestedBudget))")
                            .foregroundStyle(s.suggestedBudget > s.currentBudget ? .red : .green)
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    Text(s.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .transactionUpdate(let a):
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Categorize: \"\(a.descriptionPattern)\"")
                            .font(.subheadline.weight(.semibold))
                    }
                    HStack(spacing: 4) {
                        Text("Match \"\(a.descriptionPattern)\"")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(a.category ?? "")
                            .foregroundStyle(.blue)
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    Text(a.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .ruleCreation(let r):
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.checkmark")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("Rule: \"\(r.keyword)\" → \(r.category)")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(r.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Apply") {
                withAnimation { viewModel.applyAction(action) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func categorizationCard(_ item: ClaudeAPIService.CategorizationSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.transactionDescription)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("$\(String(format: "%.2f", item.amount))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.category.hasPrefix("[NEW] ") {
                        Text(item.category.replacingOccurrences(of: "[NEW] ", with: ""))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    } else {
                        Text(item.category)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation { viewModel.applyCategorization(item) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func budgetAllocationCard(_ allocation: ClaudeAPIService.BudgetAllocation) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if allocation.category.hasPrefix("[NEW] ") {
                        Text(allocation.category.replacingOccurrences(of: "[NEW] ", with: ""))
                            .font(.subheadline.weight(.semibold))
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    } else {
                        Text(allocation.category)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                Text(allocation.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("$\(String(format: "%.0f", allocation.amount))")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func ruleCard(_ rule: ClaudeAPIService.RuleSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\"\(rule.keyword)\"")
                        .font(.subheadline.weight(.semibold).monospaced())
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rule.category)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                }
                Text(rule.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply") {
                withAnimation {
                    viewModel.applyRule(rule)
                    onApplyBudget?()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
