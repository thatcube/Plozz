#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Hides content behind a blur that the viewer can lift deliberately — press
/// Select on tvOS, tap on iOS/iPadOS.
///
/// The alternative, removing spoiler-protected content outright, is what the
/// ratings row used to do on the detail hero, and it has a real cost: the viewer
/// cannot tell "this title has no scores" from "your settings are hiding the
/// scores", and there is no way to look anyway short of a trip to Settings.
/// Blurring says both things at once — the data exists, and you asked not to see
/// it yet — while still keeping the number unreadable until it is asked for.
///
/// While hidden the wrapped content is `disabled`, which is what keeps the tvOS
/// focus engine out of it: a blurred rating tile that can still take focus is
/// reachable with the D-pad and would leave the reveal button unreachable behind
/// it. The prompt rides in an `overlay`, so wrapping something in this view never
/// changes its size.
public struct SpoilerRevealBox<Content: View>: View {
    private let isHidden: Bool
    private let prompt: LocalizedStringResource
    private let identity: String
    private let blurRadius: CGFloat
    private let content: Content

    @State private var isRevealed = false
    @Environment(\.themePalette) private var palette

    /// - Parameters:
    ///   - isHidden: Whether spoiler protection applies at all. `false` renders
    ///     `content` untouched, with no blur, no overlay and no focus change.
    ///   - prompt: The reveal button's label, e.g. `"Show Ratings"`.
    ///   - identity: A value that changes when the underlying subject does —
    ///     normally `MediaItem.id`. Revealing is per-title, and detail pages
    ///     swap their item in place (picking another episode, switching server),
    ///     so without this the reveal would carry over to the next title.
    ///   - blurRadius: How hard to blur. The default suits large detail-page
    ///     tiles; small inline badges want less.
    public init(
        isHidden: Bool,
        prompt: LocalizedStringResource,
        identity: String,
        blurRadius: CGFloat = SpoilerRevealBox.defaultBlurRadius,
        @ViewBuilder content: () -> Content
    ) {
        self.isHidden = isHidden
        self.prompt = prompt
        self.identity = identity
        self.blurRadius = blurRadius
        self.content = content()
    }

    public static var defaultBlurRadius: CGFloat {
        #if os(tvOS)
        22
        #else
        14
        #endif
    }

    private var isMasked: Bool { isHidden && !isRevealed }

    public var body: some View {
        content
            .blur(radius: isMasked ? blurRadius : 0)
            // Not decoration: a disabled subtree is unfocusable, so the D-pad
            // cannot land inside the blur and skip past the reveal button.
            .disabled(isMasked)
            .accessibilityHidden(isMasked)
            .overlay {
                if isMasked {
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) { isRevealed = true }
                    } label: {
                        SpoilerRevealPrompt(prompt: prompt, palette: palette)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SpoilerRevealButtonStyle())
                    .focusEffectDisabled()
                    .accessibilityLabel(Text(prompt))
                    .accessibilityHint(Text(
                        "Ratings are hidden until you've watched this. Reveals them anyway.",
                        comment: "Accessibility hint on the control that lifts the spoiler blur over a title's ratings."
                    ))
                }
            }
            // Re-arm when the subject changes, and again if the setting is turned
            // back on while the page is open.
            .onChange(of: identity) { isRevealed = false }
            .onChange(of: isHidden) { isRevealed = false }
    }
}

/// The chip floated over blurred content: an eye-with-slash and the caller's
/// label, sized so it reads as one control rather than a caption.
private struct SpoilerRevealPrompt: View {
    let prompt: LocalizedStringResource
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: iconSpacing) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: fontSize * 0.9, weight: .semibold))
            Text(prompt)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(palette.primaryText)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(palette.cardOpaqueSurface.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(palette.cardBorder, lineWidth: 1))
        // The chip is the one thing here that must stay legible — it sits on top
        // of a blur, and a blur that bled onto its own label would be unreadable.
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }

    private var fontSize: CGFloat {
        #if os(tvOS)
        26
        #else
        15
        #endif
    }

    private var iconSpacing: CGFloat {
        #if os(tvOS)
        12
        #else
        7
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        26
        #else
        16
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        14
        #else
        9
        #endif
    }
}

/// Plain everywhere, with a focus/press response supplied by hand.
///
/// The stock tvOS styles paint their own plate, which here would be a bright
/// rectangle sitting over the blur instead of a chip floating above it. The
/// system focus effect is disabled at the call site for the same reason, so this
/// scale is the only focus feedback — which is why it is large enough to read.
private struct SpoilerRevealButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RevealBody(configuration: configuration)
    }

    /// Not named `Body`: that is `ButtonStyle`'s own associated type, so a nested
    /// type of that name is read as satisfying the requirement and the conformance
    /// fails on access level.
    private struct RevealBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(scale)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var scale: CGFloat {
            if configuration.isPressed { return 0.96 }
            return isFocused ? 1.06 : 1
        }
    }
}
#endif
