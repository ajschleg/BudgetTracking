import Foundation
import SwiftUI

@Observable
final class IncomeViewModel {
    var sources: [IncomeSource] = []
    var incomeTransactions: [Transaction] = []
    var totalIncome: Double = 0
    var sourceAssignments: [UUID: UUID] = [:]  // transactionId -> sourceId
    var expandedSourceId: UUID?
    var errorMessage: String?

    // Source management sheet
    var isManagingSourcesPresented = false

    private var currentMonth: String = ""

    func load(month: String) {
        currentMonth = month
        do {
            sources = IncomeSource.loadSaved()
            incomeTransactions = try DatabaseManager.shared.fetchIncomeTransactions(forMonth: month)
            totalIncome = try DatabaseManager.shared.fetchTotalIncome(forMonth: month)
            sourceAssignments = IncomeSource.loadMappings()
            autoAssignUnmatched()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Auto-Assignment

    private func autoAssignUnmatched() {
        var changed = false
        for txn in incomeTransactions {
            guard sourceAssignments[txn.id] == nil else { continue }
            for source in sources {
                let matched = source.keywords.contains { keyword in
                    txn.description.localizedCaseInsensitiveContains(keyword)
                }
                if matched {
                    sourceAssignments[txn.id] = source.id
                    changed = true
                    break
                }
            }
        }
        if changed {
            IncomeSource.saveMappings(sourceAssignments)
        }
    }

    // MARK: - Manual Assignment

    func assignSource(_ sourceId: UUID?, to transactionId: UUID) {
        if let sourceId {
            sourceAssignments[transactionId] = sourceId
        } else {
            sourceAssignments.removeValue(forKey: transactionId)
        }
        IncomeSource.saveMappings(sourceAssignments)
    }

    // MARK: - Source Management

    func addSource(name: String, keywords: [String]) {
        let source = IncomeSource(name: name, keywords: keywords, isDefault: false)
        sources.append(source)
        IncomeSource.save(sources)
    }

    func deleteSource(_ sourceId: UUID) {
        sources.removeAll { $0.id == sourceId }
        // Unassign transactions that were assigned to this source
        for (txnId, srcId) in sourceAssignments where srcId == sourceId {
            sourceAssignments.removeValue(forKey: txnId)
        }
        IncomeSource.save(sources)
        IncomeSource.saveMappings(sourceAssignments)
    }

    func renameSource(_ sourceId: UUID, to newName: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceId }) else { return }
        sources[index].name = newName
        IncomeSource.save(sources)
    }

    func updateKeywords(_ sourceId: UUID, keywords: [String]) {
        guard let index = sources.firstIndex(where: { $0.id == sourceId }) else { return }
        sources[index].keywords = keywords
        IncomeSource.save(sources)
    }

    // MARK: - Computed Groupings

    func transactions(for sourceId: UUID) -> [Transaction] {
        incomeTransactions.filter { sourceAssignments[$0.id] == sourceId }
    }

    var uncategorizedTransactions: [Transaction] {
        let assignedSourceIds = Set(sources.map(\.id))
        return incomeTransactions.filter { txn in
            guard let srcId = sourceAssignments[txn.id] else { return true }
            return !assignedSourceIds.contains(srcId)
        }
    }

    func total(for sourceId: UUID) -> Double {
        transactions(for: sourceId).reduce(0) { $0 + $1.amount }
    }

    var uncategorizedTotal: Double {
        uncategorizedTransactions.reduce(0) { $0 + $1.amount }
    }
}
