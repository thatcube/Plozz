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

/// Compact rounded-chip style for the panel header's Edit / Back controls.
///
/// Sized to match the menu rows (`.body`, low height) rather than the taller
/// system glass button, with a nested corner radius that reads as concentric
/// with the panel's rounded edge. Idle shows a faint translucent fill + hairline
/// stroke; focus flips to a solid white card with black content, mirroring
/// `PlayerMenuRowButtonStyle`. Deliberately *no* drop shadow (same HDR frame-drop
/// reason as the rows). Pair with `.focusEffectDisabled()`.
struct PanelHeaderButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14
    func makeBody(configuration: Configuration) -> some View {
        PanelHeaderButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }
}

private struct PanelHeaderButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isFocused ? AnyShapeStyle(Color.black) : AnyShapeStyle(Color.white))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(shape.fill(isFocused ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12))))
            .overlay(shape.stroke(.white.opacity(isFocused ? 0 : 0.18), lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.9 : 1)
            // Instant focus flip (no lingering ghost card over moving HDR video),
            // matching PlayerMenuRowButtonStyle.
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
/// A single-line label that truncates (with a soft right-edge fade) at rest and
/// **marquee-scrolls** the full text left-and-back when its row is focused — the
/// standard tvOS treatment for long titles that don't fit. Reads the row's focus
/// from `playerMenuRowIsFocused`, so it only animates the focused row.
struct MarqueeText: View {
    let text: String
    var font: Font = .body

    @Environment(\.playerMenuRowIsFocused) private var focused
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var scroll = false

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(GeometryReader { g in
                Color.clear.preference(key: MarqueeTextWidthKey.self, value: g.size.width)
            })
            .offset(x: scroll ? -overflow : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.preference(key: MarqueeContainerWidthKey.self, value: g.size.width)
            })
            .clipped()
            .mask(fadeMask)
            .onPreferenceChange(MarqueeTextWidthKey.self) { textWidth = $0; updateScroll() }
            .onPreferenceChange(MarqueeContainerWidthKey.self) { containerWidth = $0; updateScroll() }
            .onChange(of: focused) { _, _ in updateScroll() }
    }

    /// Soft fade on the right edge at rest to signal "there's more"; solid (no
    /// fade) while scrolling so the end is fully legible as it passes.
    @ViewBuilder private var fadeMask: some View {
        if overflow > 1 && !scroll {
            LinearGradient(
                stops: [.init(color: .black, location: 0),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1.0)],
                startPoint: .leading, endPoint: .trailing)
        } else {
            Color.black
        }
    }

    private func updateScroll() {
        guard focused, overflow > 1 else {
            withAnimation(.easeOut(duration: 0.2)) { scroll = false }
            return
        }
        // Speed proportional to the overflow so long and short names scroll at a
        // similar pace; pause at each end (autoreverse) and loop while focused.
        withAnimation(.linear(duration: max(2.2, Double(overflow) / 55))
            .delay(0.6)
            .repeatForever(autoreverses: true)) {
            scroll = true
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct MarqueeContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif
