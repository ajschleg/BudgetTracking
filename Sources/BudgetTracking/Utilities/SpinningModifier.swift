import SwiftUI

/// Rotates the modified view 360° per second while `isActive` is true,
/// then unwinds back to 0° when it becomes false. Used by the toolbar
/// Sync and Refresh buttons to keep the existing icon visible while
/// signalling ongoing work — instead of swapping in a separate
/// ProgressView and losing the icon's identity.
private struct Spinning: ViewModifier {
    let isActive: Bool
    @State private var rotation: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .onChange(of: isActive, initial: true) { _, active in
                if active {
                    rotation = 0
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                } else {
                    withAnimation(.linear(duration: 0.2)) {
                        rotation = 0
                    }
                }
            }
    }
}

extension View {
    /// Continuously rotates this view while `isActive` is true.
    /// Settles back to 0° with a short tween when it becomes false.
    func spinning(_ isActive: Bool) -> some View {
        modifier(Spinning(isActive: isActive))
    }
}
