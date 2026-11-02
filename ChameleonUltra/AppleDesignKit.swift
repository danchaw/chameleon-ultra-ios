import SwiftUI

// MARK: - Apple-style motion & feedback (v1.37.0)
//
// Distilled from WWDC "Designing Fluid Interfaces" and the Principles of
// Great Design, expressed in SwiftUI:
//   • feedback lands on touch-DOWN, not on release;
//   • transitions are springs — interruptible, velocity-aware, never
//     fixed-duration curves for anything a user can touch;
//   • default UI springs are CRITICALLY DAMPED (no overshoot); bounce is
//     reserved for gestures that themselves carried momentum;
//   • haptics fire on the SAME FRAME as the visual state change
//     (.sensoryFeedback(trigger:) rather than imperative calls);
//   • Reduce Motion replaces slides/springs with instant/cross-fade.

/// The three springs the app is allowed to use. Named by intent, not shape.
enum AppleMotion {
    /// Tap-caused state change: damping 1.0, response 0.35 (WWDC default).
    static let ui: Animation = .spring(Spring(response: 0.35, dampingRatio: 1.0))
    /// Press in/out micro feedback: snappier, still no overshoot.
    static let micro: Animation = .spring(Spring(response: 0.25, dampingRatio: 1.0))
    /// Flick / drag release ONLY — inherits the gesture's momentum, so a
    /// slight bounce is earned here and nowhere else.
    static let momentum: Animation = .spring(Spring(response: 0.4, dampingRatio: 0.8))
}

/// Press-down feedback: shade + subtle scale, spring-driven and interruptible
/// mid-press. Use for whole-row buttons, tiles and chips that are Buttons.
struct PressableStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    /// Rows in a List should NOT scale (neighbouring rows shift); tiles may.
    var scales: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.07)
                    : Color.primary.opacity(0.0),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(scales && configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(AppleMotion.micro, value: configuration.isPressed)
    }
}

private struct AppleSpringModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Reduce Motion: instant state change (no travel, no scale); the
        // information itself still updates, which is what the guideline asks.
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(...)` with Reduce Motion honoured, spring default.
    func appleSpring<V: Equatable>(_ animation: Animation = AppleMotion.ui,
                                   value: V) -> some View {
        modifier(AppleSpringModifier(animation: animation, value: value))
    }
}
