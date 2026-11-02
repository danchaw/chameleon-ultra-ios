import SwiftUI

// MARK: - Design system (v1.38.0 · redesign/apple-native)
//
// Full teardown of the v1.36 hand-drawn Liquid Glass layer. Per
// apple-design / HIG:
//   • glass and material belong to INTERACTIVE chrome (buttons, toolbars),
//     never to content surfaces — cards are native grouped surfaces;
//   • where a system style exists it wins over any hand-built
//     approximation — on iOS 26 that is .glass/.glassProminent/glassEffect;
//     on iOS 17–25 it is .bordered/.borderedProminent and plain UIKit
//     system colors (the Settings/Mail look), no faux frosted glass.
// The API names stay (call sites untouched); every implementation is new.

let lgCardRadius: CGFloat = 16
let lgTileRadius: CGFloat = 16

// MARK: - Content surface

struct LGCardModifier: ViewModifier {
    var interactive: Bool = false   // kept for call-site compatibility

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: lgCardRadius, style: .continuous))
    }
}

// MARK: - Tile / button

/// iOS 26: the OS glass button styles (free absorb-on-press physics).
/// iOS 17–25: the OS bordered styles, stretched to fill — everything the
/// system draws, nothing hand-frosted.
private struct FillLabelStyle<S: ButtonStyle>: ButtonStyle {
    let base: S
    func makeBody(configuration: Configuration) -> some View {
        base.makeBody(configuration: configuration)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    @ViewBuilder
    func lgTile(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            // controlSize is an ENVIRONMENT value — set it outside the style
            // (BorderedButtonStyle itself has no .controlSize chain).
            if prominent {
                controlSize(.large)
                    .buttonStyle(FillLabelStyle(base: BorderedProminentButtonStyle()))
            } else {
                controlSize(.large)
                    .buttonStyle(FillLabelStyle(base: BorderedButtonStyle()))
            }
        }
    }

    /// Full-width tappable row (lists rendered outside a List).
    @ViewBuilder
    func lgRow() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(LGLargeGlassRowStyle())
        } else {
            buttonStyle(PressableStyle(cornerRadius: 12, scales: false))
        }
    }

    /// Inline pill/badge. Interactive chrome → glass on 26; on older
    /// systems a light tertiary system fill (a chip, not a frosted panel).
    func lgChip(_ tint: Color? = nil) -> some View {
        modifier(LGChipModifier(tint: tint))
    }

    /// Hierarchical symbol rendering (iOS 15+).
    func lgIcon() -> some View {
        symbolRenderingMode(.hierarchical)
    }

    /// Rolling digits for counters/battery/percentages.
    func lgNumber() -> some View {
        contentTransition(.numericText())
    }

    func lgCard(interactive: Bool = false) -> some View {
        modifier(LGCardModifier(interactive: interactive))
    }
}

struct LGChipModifier: ViewModifier {
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(Glass.regular.tint(tint.opacity(0.45)).interactive(),
                                    in: .capsule)
            } else {
                content.glassEffect(Glass.regular, in: .capsule)
            }
        } else {
            content.background(Color(.tertiarySystemBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
        }
    }
}

// MARK: - Morph container + namespace (iOS 26 selection morph; pass-through below)

struct LGMorphContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

struct LGMorphID: ViewModifier {
    let id: String
    @Environment(\.lgNamespace) private var ns

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let ns {
            content.glassEffectID(id, in: ns)
        } else {
            content
        }
    }
}

private struct LGNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var lgNamespace: Namespace.ID? {
        get { self[LGNamespaceKey.self] }
        set { self[LGNamespaceKey.self] = newValue }
    }
}

/// Wraps a screen so children can use `.lgMorphShape(id:)`.
struct LGMorphScope<Content: View>: View {
    @Namespace private var ns
    @ViewBuilder var content: Content

    var body: some View {
        LGMorphContainer {
            content.environment(\.lgNamespace, ns)
        }
    }
}

extension View {
    func lgMorphShape(_ id: String) -> some View { modifier(LGMorphID(id: id)) }
}

// MARK: - Row glass (iOS 26)

@available(iOS 26.0, *)
private struct LGLargeGlassRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .glassEffect(Glass.regular.interactive(),
                         in: .rect(cornerRadius: lgTileRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
