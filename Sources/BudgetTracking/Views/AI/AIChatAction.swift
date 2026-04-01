import Foundation

struct AIChatAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let action: () async -> Void
}
