#if canImport(SwiftUI)
import SwiftUI

/// The shared **circular** focus treatment for round artwork — artist images,
/// profile avatars and cast portraits — modelled on the profile picker's
/// original `FocusGlassAvatar`.
///
/// At rest there is **no** surface: just the round avatar. On focus the same
/// liquid-glass "card" the rest of the app uses (`plozzGlassCard`, so it tracks
/// the theme and Reduce-Transparency exactly) blooms behind the avatar as a
/// perfect circle (its corner radius is half the slot) with a gentle lift and
/// drop shadow, while the avatar itself eases up toward the halo. The focused
/// slot is always reserved, so gaining focus never nudges neighbouring tiles.
///
/// This is the pure visual layer and takes an explicit `isFocused` (and optional
/// `isPressed`) so it works both inside a `Button` label (profile picker) and
/// inside a `.focusable` tile (`CircularFocusTile`).
public struct CircularFocusHalo<Avatar: View>: View {
    private let isFocused: Bool
    private let isPressed: Bool
    private let diameter: CGFloat
    private let focusPadding: CGFloat
    private let focusScale: CGFloat
    private let avatar: () -> Avatar

    public init(
        isFocused: Bool,
        isPressed: Bool = false,
        diameter: CGFloat,
        focusPadding: CGFloat,
        focusScale: CGFloat = PlozzTheme.Metrics.mediumFocusedCardScale,
        @ViewBuilder avatar: @escaping () -> Avatar
    ) {
        self.isFocused = isFocused
        self.isPressed = isPressed
        self.diameter = diameter
        self.focusPadding = focusPadding
        self.focusScale = focusScale
        self.avatar = avatar
    }

    /// The reserved slot: the avatar plus the halo's clearance on every side.
    private var slot: CGFloat { diameter + focusPadding * 2 }

    private var contentScale: CGFloat {
        guard isFocused else { return 1 }
        return isPressed ? focusScale * 0.97 : focusScale
    }

    public var body: some View {
        ZStack {
            Color.clear
                .frame(width: slot, height: slot)
                .plozzGlassCard(cornerRadius: slot / 2, isFocused: true)
                .shadow(color: .black.opacity(0.36), radius: 20, y: 10)
                .opacity(isFocused ? 1 : 0)

            avatar()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .scaleEffect(contentScale)
        }
        .frame(width: slot, height: slot)
        .animation(.easeOut(duration: 0.22), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

/// A self-contained, focusable circular tile: a `CircularFocusHalo` over a round
/// avatar with an optional caption beneath it. Owns its focus the same way the
/// rectangular cards do — `.focusable` + `.onTapGesture` with the system focus
/// effect disabled — so the only focus visual is our circular glass halo (a
/// `Button` would paint tvOS's white focus platter behind it).
///
/// The caption builder receives the live focus state so labels can emphasise on
/// focus. The caption sits *below* the halo (never inside it), so it stays on the
/// page rather than on the glass.
public struct CircularFocusTile<Avatar: View, Caption: View>: View {
    private let diameter: CGFloat
    private let focusPadding: CGFloat
    private let focusScale: CGFloat
    private let captionSpacing: CGFloat
    private let avatar: () -> Avatar
    private let caption: (Bool) -> Caption
    private let action: () -> Void

    @FocusState private var isFocused: Bool

    public init(
        diameter: CGFloat,
        focusPadding: CGFloat,
        focusScale: CGFloat = PlozzTheme.Metrics.mediumFocusedCardScale,
        captionSpacing: CGFloat = 12,
        action: @escaping () -> Void,
        @ViewBuilder avatar: @escaping () -> Avatar,
        @ViewBuilder caption: @escaping (Bool) -> Caption
    ) {
        self.diameter = diameter
        self.focusPadding = focusPadding
        self.focusScale = focusScale
        self.captionSpacing = captionSpacing
        self.action = action
        self.avatar = avatar
        self.caption = caption
    }

    public var body: some View {
        VStack(spacing: captionSpacing) {
            CircularFocusHalo(
                isFocused: isFocused,
                diameter: diameter,
                focusPadding: focusPadding,
                focusScale: focusScale,
                avatar: avatar
            )
            caption(isFocused)
        }
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .zIndex(isFocused ? 2 : 0)
    }
}
#endif
