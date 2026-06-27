#if canImport(SwiftUI)
import SwiftUI

/// Shape of a Plozz glass control pill in the opaque (Reduce Transparency) path.
public enum PlozzControlShape: Equatable {
    case capsule
    case circle
}

public extension View {
    /// Liquid-glass pill matching the Twozz player control / chat-settings
    /// buttons: native Liquid Glass on tvOS 26+ — `.glassProminent` when
    /// `isSelected`, plain `.glass` otherwise — with **no focus outline** (the
    /// native glass lift is the only focus treatment). When the system Reduce
    /// Transparency setting is on it swaps in a theme-aware **opaque** pill that
    /// follows the tvOS focus convention (bright white fill + dark glyph) and
    /// never draws a border on focus. Selected pills carry the brand accent.
    func plozzGlassPillButton(isSelected: Bool = false, shape: PlozzControlShape = .capsule) -> some View {
        modifier(PlozzGlassPillButtonModifier(isSelected: isSelected, shape: shape))
    }
}

struct PlozzGlassPillButtonModifier: ViewModifier {
    var isSelected: Bool
    var shape: PlozzControlShape
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Reduce Transparency: opaque themed pill, no translucency, no focus
            // ring (we draw our own white-fill focus treatment instead).
            content
                .buttonStyle(PlozzOpaquePillButtonStyle(isSelected: isSelected, shape: shape))
                .focusEffectDisabled()
        } else if #available(tvOS 26.0, *) {
            // Native Liquid Glass — identical to the player controls. The
            // prominent variant marks the selected pill with the app tint.
            if isSelected {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            // Pre-Liquid-Glass fallback: the same opaque pill (still outline-free)
            // rather than a bordered style.
            content
                .buttonStyle(PlozzOpaquePillButtonStyle(isSelected: isSelected, shape: shape))
                .focusEffectDisabled()
        }
    }
}

/// Season-tab styling: a single, **identity-stable** button style for the series
/// detail season tabs. Unlike swapping `.glass` ↔ `.glassProminent` by selection
/// (which changes the view's identity and makes tvOS snap focus back to the first
/// tab — see Twozz's `settingPillStyle`), this style is applied unconditionally
/// and varies only *animatable* properties (opacity, fill, weight, scale). That
/// keeps the focused tab's identity intact so left/right navigation never breaks.
///
/// Visually: a tab reads as **text-only** when it is neither focused nor the
/// active (selected) season, and lifts into a Liquid Glass pill when focused or
/// selected — matching the reference where only the current season is a pill.
public struct PlozzSeasonTabStyle: ButtonStyle {
    var isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, isSelected: isSelected)
    }

    private struct TabBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.plozzReduceTransparency) private var reduceTransparency
        @Environment(\.themePalette) private var palette

        /// Whether the tab shows its pill (focused tab, or the active season).
        private var active: Bool { isFocused || isSelected }

        private var foreground: Color {
            // The focused tab wears the bright solid "focus" pill, so its label is
            // dark for contrast (the standard tvOS focused-button look). A merely
            // selected (active, not focused) tab keeps light text on its glass pill.
            if isFocused { return .black }
            if isSelected { return palette.primaryText }
            return palette.secondaryText
        }

        var body: some View {
            configuration.label
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(foreground)
                // Text colour + weight snap INSTANTLY. Animating them is what made
                // the label colour appear to "lag behind" focus during a fast swipe:
                // each chip crossfaded its dark focused text back to light over 0.16s,
                // so trailing chips briefly kept a dark label. Clearing the animation
                // for just this label subtree fixes that without needing to detect a
                // swipe. The scale lift below still animates — that's the nice bit on
                // single left/right steps, and being pure geometry it leaves no ghost.
                .transaction { $0.animation = nil }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(pill)
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1.0))
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        /// Two always-present layers (stable identity — the view-tree shape never
        /// changes with focus/selection, so focus moves freely):
        ///
        ///  - `basePill`: the glass "button" pill, shown for the *selected* season
        ///    while it is NOT the focused tab. The expensive Liquid Glass layer, but
        ///    it is only ever visible on the single selected chip — never on chips
        ///    the focus flies across — so fast swipes don't pay for glass.
        ///  - `focusPill`: a cheap *solid* bright capsule that rides focus.
        ///
        /// Crucially the opacities here switch with **no animation** (`.transaction`
        /// clears it). Animating them (a 0.16s fade per chip) is what produced the
        /// "comet trail" of half-faded pills during a rapid swipe — a 50%-opacity
        /// white pill over the dark bar even reads as a gray glass pill. Snapping
        /// them instantly means exactly one crisp pill sits under the focused chip
        /// every frame, which both looks and feels fast. The scale lift on the label
        /// above still animates, so single steps keep their gentle bounce.
        private var pill: some View {
            let shape = Capsule(style: .continuous)
            return ZStack {
                basePill(shape).opacity(isSelected && !isFocused ? 1 : 0)
                focusPill(shape).opacity(isFocused ? 1 : 0)
            }
            .transaction { $0.animation = nil }
        }

        /// The bright focus capsule — a solid fill (white on the translucent paths,
        /// the themed card surface is unnecessary here). Cheap to composite, so it
        /// never bottlenecks a rapid focus swipe.
        private func focusPill(_ shape: Capsule) -> some View {
            shape.fill(.white)
        }

        // The branch here keys off Reduce Transparency / OS availability — both
        // stable while navigating — never off focus or selection (the view tree
        // shape AND the `Glass` value stay identical), so focus moves freely and the
        // glass is never recomputed mid-swipe.
        @ViewBuilder
        private func basePill(_ shape: Capsule) -> some View {
            if reduceTransparency {
                shape.fill(palette.cardSurface)
            } else if #available(tvOS 26.0, *) {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
    }
}

/// Opaque, theme-aware pill used when Liquid Glass is unavailable/disabled.
/// Ported from Twozz's `TwozzOpaquePillButtonStyle`: reads the button's own focus
/// state and flips to the standard tvOS focused look (white fill + dark label),
/// marks the selected option with the brand accent, and crucially drops its
/// border to `.clear` whenever focused or selected — so focus never reads as an
/// outline.
public struct PlozzOpaquePillButtonStyle: ButtonStyle {
    var isSelected: Bool
    var shape: PlozzControlShape

    public init(isSelected: Bool = false, shape: PlozzControlShape = .capsule) {
        self.isSelected = isSelected
        self.shape = shape
    }

    public func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, isSelected: isSelected, shape: shape)
    }

    private struct PillBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        let shape: PlozzControlShape
        @Environment(\.isFocused) private var isFocused
        @Environment(\.themePalette) private var palette

        private var fill: Color {
            if isFocused { return .white }
            if isSelected { return palette.accent }
            return palette.cardSurface
        }
        private var foreground: Color {
            if isFocused { return .black }
            if isSelected { return .white }
            return palette.primaryText
        }
        private var border: Color {
            (isFocused || isSelected) ? .clear : palette.cardBorder
        }

        var body: some View {
            Group {
                switch shape {
                case .capsule:
                    styled(Capsule(style: .continuous))
                case .circle:
                    styled(Circle())
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1.0))
            .shadow(
                color: .black.opacity(isFocused ? 0.28 : 0.0),
                radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0
            )
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        @ViewBuilder
        private func styled<S: InsettableShape>(_ s: S) -> some View {
            let isCircle = (shape == .circle)
            configuration.label
                .foregroundStyle(foreground)
                .padding(.horizontal, isCircle ? 12 : 22)
                .padding(.vertical, isCircle ? 12 : 14)
                .background(fill, in: s)
                .overlay(s.strokeBorder(border, lineWidth: 1))
                .clipShape(s)
        }
    }
}

#endif
