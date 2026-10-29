import SwiftUI

// MARK: - Liquid Glass design kit (v1.36)
//
// One semantic API, two implementations: native `glassEffect` on iOS 26+,
// a calibrated material fallback on iOS 17-25 (blur radius / edge-light /
// stroke values follow the SwiftLiquid parameter reference so both paths
// read as the same design language).
//
// Surfaces (largest → smallest):
//   .lgCard      content group      — clear glass on 26 (content under it stays primary)
//   .lgTile      tappable grid cell — regular glass, tinted + interactive when promoted
//   .lgChip      inline pill/badge  — regular glass capsule
// Morphing:
//   LGMorph      one GlassEffectContainer per screen; selection shapes carry
//                .glassEffectID(...) so the highlight morphs between positions
//                instead of fading (Apple "Applying Liquid Glass" example 2).

private let lgCardRadius: CGFloat = 22
private let lgTileRadius: CGFloat = 16
private let lgCornerRadiusContinuous = RoundedRectangle(cornerRadius: lgCardRadius, style: .continuous)

// MARK: - Card surface

struct LGCardModifier: ViewModifier {
    @Environment(\.themeAccent) private var accent
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Large content surfaces use the CLEAR variant: lighter than the
            // controls riding on top of them (HIG: don't glass everything).
            var glass = Glass.clear
            if interactive { glass = glass.interactive() }
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(glass, in: .rect(cornerRadius: lgCardRadius, style: .continuous))
        } else {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: lgCornerRadiusContinuous)
                .overlay(
                    lgCornerRadiusContinuous
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Tile surface (tappable grid cell / primary button)

struct LGTileStyle: ButtonStyle {
    var prominent: Bool = false
    @Environment(\.themeAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, prominent: prominent, accent: accent)
    }

    private struct TileBody: View {
        let configuration: Configuration
        let prominent: Bool
        let accent: Color

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 10)
                .modifier(TileGlass(prominent: prominent, pressed: configuration.isPressed, accent: accent))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.22), value: configuration.isPressed)
        }
    }

    private struct TileGlass: ViewModifier {
        let prominent: Bool
        let pressed: Bool
        let accent: Color

        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                var glass = Glass.regular.interactive()
                if prominent { glass = glass.tint(accent.opacity(0.6)) }
                content
                    .glassEffect(glass, in: .rect(cornerRadius: lgTileRadius, style: .continuous))
                    .opacity(pressed ? 0.85 : 1)
            } else {
                content
                    .background(
                        prominent ? AnyShapeStyle(accent.opacity(pressed ? 0.28 : 0.20))
                                  : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: lgTileRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: lgTileRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }
}

// MARK: - Chip surface (inline pill / badge)

struct LGChipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}

// MARK: - Morph container + namespace

/// Share a GlassEffectContainer across a screen so `glassEffectID` shapes
/// morph between positions (slot selection, tab-like pills). On iOS < 26 it
/// is a transparent pass-through.
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

/// Applies a morphing identity to a background shape inside an LGMorphContainer.
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

// MARK: - Icon / number polish

extension View {
    func lgCard(interactive: Bool = false) -> some View {
        modifier(LGCardModifier(interactive: interactive))
    }

    func lgChip() -> some View { modifier(LGChipModifier()) }

    /// Tiles/buttons: native context-aware glass button styles on iOS 26
    /// (`.glass` / `.glassProminent` — the pressed-absorb behaviour is free),
    /// hand-built equivalent below.
    @ViewBuilder
    func lgTile(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            buttonStyle(LGTileStyle(prominent: prominent))
        }
    }

    /// Layered coloured symbols on iOS 26 (WWDC25 "Give your app that
    /// iOS 26 style"); hierarchical style elsewhere.
    func lgIcon() -> some View {
        if #available(iOS 26.0, *) {
            foregroundStyle(.layered)
        } else {
            foregroundStyle(.hierarchical)
        }
    }

    /// Rolling digits for counters/battery/percentages.
    func lgNumber() -> some View {
        contentTransition(.numericText())
    }
}

/// Wraps a screen so children can use `.lGMorphShape(id:)`.
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
