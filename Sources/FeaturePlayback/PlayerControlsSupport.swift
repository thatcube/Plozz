#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

struct ControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the transport block's (scrubber + buttons) height so the Style panel
/// can align its top margin to its side margin.
struct TransportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports each panel's natural (unclipped) content height, **keyed by category**,
/// so the glass box can animate ONLY its clip window to that height. The rows are
/// laid out at full size and clipped to the animating frame, so they never
/// cross-fade or spill past the rounded border when a sub-screen adds/removes rows
/// — "animate the container, not what's inside".
///
/// The height is tagged with its owning `Category` because panels overlap during
/// the 0.2s open/close transition: a *closing* panel stays mounted and keeps
/// reporting its (tall) height while the *next* panel is already opening. Keying by
/// category lets the reader pick out only the currently-open panel's height, so a
/// closing panel can never size the panel that's replacing it (which caused short
/// menus like Audio to spawn tall and then animate down).
struct PanelBodyHeightKey: PreferenceKey {
    static let defaultValue: [PlayerControls.Category: CGFloat] = [:]
    static func reduce(
        value: inout [PlayerControls.Category: CGFloat],
        nextValue: () -> [PlayerControls.Category: CGFloat]
    ) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

/// The scrub track: buffered + played fill, a knob, and a floating trickplay
/// thumbnail positioned over the scrub head while scrubbing.
struct ScrubBar: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    /// Horizontal distance from the scrub track's leading/trailing edge out to the
    /// screen edge, so the trickplay thumbnail can extend past the track (but not
    /// off-screen).
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = width * CGFloat(model.progressFraction)
            // The bar is "focused" whenever the scrub surface owns focus — the
            // controls are up and focus hasn't dropped to the button row below
            // (scrubbing counts as focused). Focused, the bar is full height,
            // the played fill is bright and the playhead is a rounded pill. Once
            // focus moves to the buttons the bar slims by 8pt, the fill fades and
            // the playhead squares off flush into the track.
            let focused = model.controlsVisible && !model.controlBarVisible
            let barHeight: CGFloat = focused ? 20 : 12
            let knobWidth: CGFloat = focused ? 8 : 4
            let knobHeight: CGFloat = focused ? (model.isScrubbing ? 40 : 32) : barHeight

            ZStack(alignment: .leading) {
                glassTrack(height: barHeight)
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: width * CGFloat(model.bufferedFraction), height: barHeight)
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                    .fill(.white.opacity(focused ? 0.62 : 0.32))
                    .frame(width: knobX, height: barHeight)
                RoundedRectangle(cornerRadius: focused ? knobWidth / 2 : 0, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)

                if model.isScrubbing && model.hasPreviewFrame {
                    thumbnailPreview(width: width, knobX: knobX)
                        .transition(.thumbnailDismiss)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
            .animation(.easeOut(duration: 0.2), value: model.controlBarVisible)
            .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
        }
    }

    /// The base scrub track rendered as Liquid Glass on tvOS 26+, with a
    /// translucent-fill fallback on older systems.
    @ViewBuilder
    private func glassTrack(height: CGFloat) -> some View {
        if #available(tvOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .frame(height: height)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: height)
        }
    }

    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        if let image = model.previewImage {
            // ~15% larger than the previous 420pt thumbnail.
            let thumbWidth: CGFloat = 483
            let aspect = previewAspect
            let thumbHeight = thumbWidth / aspect
            let corner: CGFloat = 18
            let border: CGFloat = 12
            // Account for glass border so visual left edge sits at x=0 (track edge).
            let visualWidth = thumbWidth + 2 * border
            let minX = visualWidth / 2
            let edgeMargin: CGFloat = 16
            let maxX = width + trailingInset - visualWidth / 2 - edgeMargin
            let clampedX = min(max(minX, knobX), max(minX, maxX))

            let content = Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            // Float the trickplay thumbnail above the scrub bar (bar is centred
            // at y=0 in this GeometryReader). `thumbnailLift` is the gap from the
            // bar centre to the *bottom* of the thumbnail — kept tight so the
            // preview hugs the bar.
            let thumbnailLift: CGFloat = 34
            Group {
                if #available(tvOS 26.0, *) {
                    content
                        .padding(border)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner + border, style: .continuous))
                } else {
                    content
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .stroke(.white.opacity(0.85), lineWidth: border)
                        )
                }
            }
            .position(x: clampedX, y: -(thumbnailLift + thumbHeight / 2))
        }
    }

    private var previewAspect: CGFloat {
        guard let image = model.previewImage, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}

/// The Info-card action-button style: an **instant** focus treatment (no fade).
/// The stock `.glass` / `.borderedProminent` styles animate their own focus
/// highlight, which can't be disabled from outside — so the Info card draws its
/// own capsule and swaps fill/foreground on the same frame focus changes.
/// `.animation(nil, value: focused)` guarantees the swap never rides an ambient
/// transaction. Icon-only at rest; the label reveals with the button on focus
/// (instant, so the row never janks mid-expand).
struct InfoActionButtonStyle: ButtonStyle {
    let focused: Bool
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = focused ? .white : .white.opacity(prominent ? 0.24 : 0.12)
        let fg: Color = focused ? .black : .white
        return configuration.label
            .foregroundStyle(fg)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Capsule(style: .continuous).fill(fill))
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            // Everything about focus is instant — no background/foreground fade.
            .animation(nil, value: focused)
    }
}

/// Drives the trickplay thumbnail's dismissal: it appears instantly (identity
/// insertion) and, on removal, quickly fades while blurring, scaling down a
/// touch, and drifting slightly downward.
struct ThumbnailTransitionModifier: ViewModifier {
    /// 0 = fully visible, 1 = fully dismissed.
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 9 * progress)
            .offset(y: 13 * progress)
            .opacity(Double(max(0, 1 - progress * 4.5)))
    }
}

extension AnyTransition {
    static var thumbnailDismiss: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: ThumbnailTransitionModifier(progress: 1),
                identity: ThumbnailTransitionModifier(progress: 0)
            )
        )
    }
}

extension View {
    /// Applies the system Liquid Glass button style (tvOS 26+), falling back to
    /// the bordered styles on older systems. `prominent` highlights the active
    /// category / enabled toggle.
    @ViewBuilder
    func playerGlassButton(prominent: Bool) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// The floating panel's translucent backing. Native **Liquid Glass** on tvOS
/// 26+, falling back to a cheap solid translucent fill below that (and honouring
/// the perf intent on older devices).
///
/// Still **no `.shadow`** — a soft drop shadow was the original frame-drop
/// culprit over Dolby Vision (a per-frame offscreen blur recomposited on the
/// moving HDR signal). A 1px stroke gives edge separation instead. The glass is
/// a *bounded* backdrop sample (the panel is only 760pt wide), so keep an eye on
/// the diagnostics FPS over DV content and fall back to the solid fill if it
/// ever stutters.
struct PanelGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 32
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        } else {
            content
                .background(Color.black.opacity(0.8))
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }
}

/// Horizontally positions an open control panel within the bottom cluster.
/// `leadingInset` non-nil → shift the panel right to sit under its own button
/// (Speed); nil → pin to the trailing edge above the track-button cluster
/// (Subtitles/Audio/Sync).
struct PanelHorizontalPlacement: ViewModifier {
    let leadingInset: CGFloat?

    func body(content: Content) -> some View {
        if let leadingInset {
            // Use `.offset` — NOT `.padding(.leading,)` — so aligning the Speed
            // panel to its button has zero effect on the bottom cluster's layout.
            // Leading padding applied after a fill frame grows the panel's own
            // width by `leadingInset`, overflowing the row and dragging the whole
            // control cluster sideways as the panel opens. Offset only moves the
            // drawn panel; the measured cluster (and the button we align to) stay
            // put, so there's no layout feedback loop.
            content.offset(x: max(0, leadingInset))
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Carries the Speed button's measured leading-edge X up to `PlayerControls` so
/// the Speed panel can align its left edge to the button. Only the Speed button
/// publishes a value; sibling buttons contribute the default (0), so the reduce
/// keeps the largest (the real measurement) rather than letting a 0 clobber it.
struct SpeedButtonLeadingKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
