import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ComingSoonView(title: "Dashboard")
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }

            ComingSoonView(title: "Transactions")
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }

            ComingSoonView(title: "Budget")
                .tabItem { Label("Budget", systemImage: "folder.fill") }

            ComingSoonView(title: "Settings")
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

private struct ComingSoonView: View {
    let title: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("\(title) — Coming soon")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}

#Preview {
    ContentView()
}
