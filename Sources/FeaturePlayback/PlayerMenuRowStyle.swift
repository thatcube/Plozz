#if canImport(SwiftUI)
import SwiftUI

/// Fitted, theme-aware focus style for in-player options-menu rows.
///
/// The default tvOS focus effect on a `.plain` button is oversized for these
/// compact rows. This mirrors the Settings drill-in rows instead: on focus the
/// row gets a rounded highlight sized to the row itself (an inverted white card,
/// black foreground) rather than a big system halo. Deliberately *no* drop
/// shadow — a soft shadow forces a per-frame offscreen blur recomposited over
/// the Dolby Vision / HDR video behind the panel, which drops frames on Apple TV
/// (the same problem we removed from the panel container).
///
/// Pair every button using this style with `.focusEffectDisabled()` so the
/// system focus effect doesn't double up with the fitted card.
struct PlayerMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayerMenuRowBody(configuration: configuration)
    }
}

private struct PlayerMenuRowBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            // Propagate focus to leaf content (checkmarks, subtitles) so they
            // can flip to legible colors on the inverted white card.
            .environment(\.playerMenuRowIsFocused, isFocused)
            .foregroundStyle(isFocused ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
            .background(
                // Concentric focus card: inset 4 within the row (which already sits
                // 14 from the panel edge) → an 18 gutter on every side, matching the
                // header chips. With the panel's 32 corner, a 14 radius (32 − 18)
                // makes the card corners share a centre with the panel's, and the
                // equal gutter keeps an edge row equidistant from top/bottom/left/
                // right. Text stays anchored by the row's own padding so titles still
                // line up under the section header.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
                    .padding(.horizontal, 4)
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            // Switch color + fill INSTANTLY on focus change. An animated fade
            // lingers as a ghost card when navigating away and, over moving
            // Dolby Vision video, reads as a laggy "fade behind". Instant is
            // both crisper and cheaper (no per-frame animated blend over HDR).
            .animation(nil, value: isFocused)
    }
}

// MARK: - Focus-aware leaf helpers

private struct PlayerMenuRowIsFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var playerMenuRowIsFocused: Bool {
        get { self[PlayerMenuRowIsFocusedKey.self] }
        set { self[PlayerMenuRowIsFocusedKey.self] = newValue }
    }
}

/// Secondary text (row subtitles) — dims to a dark tone on the focused white
/// card so it stays readable instead of vanishing.
private struct PlayerMenuRowSecondaryStyle: ViewModifier {
    @Environment(\.playerMenuRowIsFocused) private var focused
    func body(content: Content) -> some View {
        content.foregroundStyle(focused ? Color.black.opacity(0.6) : Color.secondary)
    }
}

/// Selection mark (checkmark / radio circle). On the focused white card the
/// accent would clash, so selected marks go black and unselected go a dim black;
/// off focus they use the accent / secondary as before.
private struct PlayerMenuRowMarkStyle: ViewModifier {
    let isSelected: Bool
    let accent: Color
    @Environment(\.playerMenuRowIsFocused) private var focused
    func body(content: Content) -> some View {
        let color: Color = {
            if focused { return isSelected ? .black : Color.black.opacity(0.45) }
            return isSelected ? accent : Color.secondary
        }()
        return content.foregroundStyle(color)
    }
}

extension View {
    func playerMenuRowSecondary() -> some View { modifier(PlayerMenuRowSecondaryStyle()) }
    func playerMenuRowMark(isSelected: Bool, accent: Color) -> some View {
        modifier(PlayerMenuRowMarkStyle(isSelected: isSelected, accent: accent))
    }
}

/// A small "knockout" pill marking an external (downloaded / sidecar) subtitle in
/// the track menu: a solid fill with the label cut out of it (transparent text),
/// so the row — or the inverted white focus card — shows through the letters. The
/// fill is focus-aware (light on the dark row, dark on the white focus card) so it
/// reads on both.
struct ExternalSubtitleBadge: View {
    @Environment(\.playerMenuRowIsFocused) private var focused

    var body: some View {
        let fill = focused ? Color.black.opacity(0.62) : Color.white.opacity(0.6)
        Text("EXTERNAL")
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.4)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            // The text punches its own shape out of the fill behind it; the fill is
            // drawn first (as the background), then the text's destinationOut blend
            // removes the glyphs. `compositingGroup` isolates the blend so it only
            // cuts the pill, never the HDR video behind the panel.
            .blendMode(.destinationOut)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
            .compositingGroup()
            .accessibilityLabel("External subtitle")
    }
}
/// A single-line label that truncates at rest and **marquee-scrolls** the full
/// text left-and-back when its row is focused — the standard tvOS treatment for
/// long titles that don't fit. Reads the row's focus from `playerMenuRowIsFocused`
/// so it only animates the focused row.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    /// Focus, when the label isn't inside a player menu row.
    ///
    /// The menu rows publish theirs through the environment, but a caller that
    /// owns its own focus state — a cast card, say — has nowhere to put it, and
    /// would otherwise have to pretend to be a menu row to animate at all.
    var isFocused: Bool?
    /// How the text sits when it FITS.
    ///
    /// Only ever applies then: text long enough to scroll has to start hard
    /// against the leading edge, or the marquee would begin by sliding the
    /// opening words out of view. Menu rows are leading either way; a card that
    /// centres its labels needs its short ones to stay centred.
    var restingAlignment: Alignment = .leading

    @Environment(\.playerMenuRowIsFocused) private var rowFocused
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    /// How far through the scroll the text is, 0…1.
    ///
    /// Animated in the same transaction as `offset`, on the same curve, so it
    /// stays in step with it — which is what lets the leading fade exist only
    /// while something really is hidden off that edge.
    @State private var scrolled: CGFloat = 0

    private var focused: Bool { isFocused ?? rowFocused }

    /// How wide the softened edge is. Narrow on purpose: it is an edge treatment,
    /// not a vignette, and every point of it is width the text can't use.
    private static let fade: CGFloat = 16

    var body: some View {
        // A hidden copy claims the available width + single-line height WITHOUT
        // being stretched by the real (fixedSize) text. The scrolling text is an
        // overlay — overlays don't influence the parent's size — so the row stays
        // bounded to the panel width (no focus outline running off-screen), and the
        // real text overflows *inside* it, clipped, free to scroll.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { containerWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in containerWidth = w }
            })
            .overlay(alignment: overflows ? .leading : restingAlignment) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { textWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in textWidth = w }
                    })
                    .offset(x: offset)
            }
            // Fade the overflow out rather than cutting it dead. A hard edge
            // reads as a rendering mistake; a soft one reads as "there is more
            // here", which is exactly what it means. Only ever applied when the
            // text really is too long, so short labels keep crisp edges.
            //
            // This is also the clip: a mask hides everything outside its own
            // bounds. An additional `.clipped()` used to sit here, and that was
            // the hard edge — two clips one point apart, so the text met the
            // second one while the fade was still only part way to transparent.
            .mask { fadeMask }
            .onChange(of: focused) { _, _ in restart() }
            .onChange(of: textWidth) { _, _ in restart() }
            .onChange(of: containerWidth) { _, _ in restart() }
    }

    private var overflows: Bool {
        textWidth - containerWidth > 1 && containerWidth > Self.fade * 2
    }

    /// Opaque unless the text overflows; then it feathers the edges the text runs
    /// past — the trailing one always, since at rest there is always more text
    /// that way, and the leading one only in proportion to how far the marquee
    /// has actually travelled.
    ///
    /// Tied to `scrolled` rather than to focus: on focus alone the leading edge
    /// dimmed the moment the card lit up, while the text was still sitting at its
    /// start with nothing hidden behind it.
    ///
    /// Laid out as three bands rather than as gradient stops or a blended
    /// punch-out: a band is flush against the border by construction, so the fade
    /// is guaranteed to reach fully transparent exactly where the text leaves the
    /// label — which neither of the other two spellings could promise. The
    /// leading band's WIDTH carries the animation, growing from nothing as the
    /// text travels.
    @ViewBuilder
    private var fadeMask: some View {
        if overflows {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fade * scrolled)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fade)
            }
        } else {
            Color.black
        }
    }

    private func restart() {
        // Hard-stop any running loop and snap back to the start.
        var stop = Transaction()
        stop.disablesAnimations = true
        withTransaction(stop) {
            offset = 0
            scrolled = 0
        }

        let overflow = max(0, textWidth - containerWidth)
        guard focused, overflow > 1 else { return }
        // Scroll left to reveal the end, then back — looping while focused. Speed
        // scales with the overflow so long and short names move at a similar pace.
        let duration = max(2.0, Double(overflow) / 55.0)
        withAnimation(.easeInOut(duration: duration).delay(0.5).repeatForever(autoreverses: true)) {
            offset = -overflow
            scrolled = 1
        }
    }
}
#endif
