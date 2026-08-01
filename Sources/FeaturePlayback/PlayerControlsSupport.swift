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

    /// The track is the widest single piece of glass in the player, so it gives
    /// its up with the panel rather than staying behind as the one refracting
    /// element left on screen.
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

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
            // `infoCardOpen` holds the bar in its focused shape for the whole Info
            // reveal. The bar is invisible behind the card, so its appearance there is
            // moot — but without this, focus returning to the surface as the card
            // closes resized the bar (12→20 tall, knob 4→8) on this view's own 0.2s
            // curve, while the cluster carrying it translated on the reveal's spring.
            // A thin line growing about its centre while sliding reads as arriving
            // from the wrong direction entirely.
            let focused = model.controlsVisible && (!model.controlBarVisible || model.controlBar.infoCardOpen)
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
        if reducePanelGlass {
            Capsule()
                .fill(.clear)
                .frame(height: height)
                .plozzFrostedBackground(Capsule())
        } else if #available(iOS 26.0, tvOS 26.0, *) {
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
                if #available(iOS 26.0, tvOS 26.0, *) {
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

/// The Info tab's button style.
///
/// Looks like the transport's other capsule controls, but is drawn here so it
/// **ignores `\.isEnabled`** — the repo's established way to take a control out of
/// the focus order without greying it (see `FocusGatedSwitch` /
/// `SettingsFocusButtonStyle` in CoreUI). The tab needs that because it is only
/// focusable while its card is open, yet must look completely normal the rest of
/// the time. Focus colours swap instantly, like the Info card's own actions.
/// One type scale for both bottom-card tabs.
///
/// The Info panel was on semantic fonts and the Cast pane on fixed point sizes,
/// so the two tabs of one card set text at different sizes — and since they
/// swap in place, that difference is visible as a jump rather than as variety.
///
/// Fixed sizes rather than semantic ones because tvOS has no user text-size
/// control for them to answer to, and because the card's height is a hard
/// constant: a layout budget cannot be reasoned about in terms that might change
/// underneath it. The semantic values these replace were `.headline` (45.35pt
/// per line) and `.footnote` (34.61) — both a size larger than this card, at
/// three metres, actually needs.
enum PlayerCardText {
    /// Titles: the episode/film name, a person's name.
    static let title: Font = PlayerCardSurface.isCompact
        ? .system(size: 17, weight: .semibold)
        : .system(size: 34, weight: .bold)
    /// Running prose: a synopsis, a biography.
    static let body: Font = PlayerCardSurface.isCompact
        ? .system(size: 13)
        : .system(size: 25)
    /// Its line height, for height budgeting.
    static let bodyLineHeight: CGFloat = PlayerCardSurface.isCompact ? 17 : 30
    /// Supporting detail: the meta row, a character name.
    static let caption: Font = PlayerCardSurface.isCompact
        ? .system(size: 11, weight: .medium)
        : .system(size: 22, weight: .medium)
}

/// Whether the player's cards are laid out for a phone.
///
/// **Idiom, not size class.** The two disagree in the case that matters: an iPad
/// in Slide Over reports a compact width, and it would be wrong to strip the
/// card down for that when the player is full-screen regardless. What actually
/// changes here is the physical device, and that cannot change while the app
/// runs — so this is a constant, not state, and the numbers that derive from it
/// can stay `static`. That matters more than it sounds: `cardHeight`, the cast
/// cards and the credit posters are all `static` and all derive from those
/// numbers, so they scale for free rather than each needing to be threaded a
/// size class.
enum PlayerCardSurface {
    #if os(tvOS)
    static let isCompact = false
    #else
    // Read off the main-thread-bound `UIDevice` exactly once, at the first
    // touch of any card metric — which happens during layout, on the main actor.
    nonisolated(unsafe) static let isCompact: Bool =
        UIDevice.current.userInterfaceIdiom == .phone
    #endif
}

struct PlayerTabButtonStyle: ButtonStyle {
    let focused: Bool
    /// Whether this tab's card is the one showing.
    ///
    /// Separate from `focused`, and the reason the row reads as a segmented
    /// control rather than a pair of buttons: focus moves down into the card, and
    /// without a selected state nothing then indicates which tab is open. The
    /// season bar on the detail page draws the same distinction.
    var selected: Bool = false

    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    /// Safe to branch on for the same reason `reduceTransparency` is: it changes
    /// when playback starts and stops, never while focus is moving, so the view
    /// tree stays a stable shape mid-swipe.
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    func makeBody(configuration: Configuration) -> some View {
        // ONE geometry for both states: the label, font and padding are applied
        // once and only the BACKGROUND swaps. Branching into two differently-built
        // chains (a filled capsule vs. `.glassEffect`) let the two states measure
        // differently, so the tab changed size the instant it took focus — and in a
        // bottom-anchored stack a size change moves everything, which reads as the
        // tab jumping rather than travelling.
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(focused ? .black : .white)
            .opacity(focused || selected ? 1 : 0.65)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background { background }
            .clipShape(Capsule(style: .continuous))
            // The surface swap stays instant — see above — but the lift is a
            // transform, not layout, so it can travel without moving the stack.
            .animation(nil, value: focused)
            .scaleEffect(configuration.isPressed ? 1.02 : (focused ? 1.08 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    @ViewBuilder
    private var background: some View {
        let shape = Capsule(style: .continuous)
        if focused {
            shape.fill(.white)
        } else if reducePanelGlass {
            // The same material the panel behind these falls back to. Matching
            // it is the whole point: a glass pill sitting on a frosted panel
            // reads as two materials that do not belong together.
            //
            // Plus a hairline edge. Frost takes its brightness from what is
            // behind it, so over a dark scene it very nearly disappears — glass
            // has a specular edge of its own that does this for free, and
            // without it these pills vanish against the letterboxing.
            shape
                .fill(.clear)
                .plozzFrostedBackground(shape, raised: selected)
                .plozzFrostedBorder(shape)
        } else if !reduceTransparency, #available(iOS 26.0, tvOS 26.0, *) {
            // Selected keeps the glass and only tints it. Swapping in a flat
            // fill made an open tab a different material from a closed one,
            // when the only thing that changes is which of them is open.
            Color.clear.glassEffect(
                selected ? .regular.tint(.white.opacity(0.30)) : .regular,
                in: shape
            )
        } else {
            shape.fill(.white.opacity(selected ? 0.34 : 0.16))
        }
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

enum PlozzMoveCommandDirection {
    case up
    case down
    case left
    case right
}

extension View {
    /// Applies the system Liquid Glass button style (tvOS 26+), falling back to
    /// the bordered styles on older systems. `prominent` highlights the active
    /// category / enabled toggle.
    @ViewBuilder
    func playerGlassButton(prominent: Bool) -> some View {
        modifier(PlayerGlassButtonModifier(prominent: prominent))
    }

    @ViewBuilder
    fileprivate func playerSystemGlassButton(prominent: Bool) -> some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
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
/// moving HDR signal). A 1px stroke gives edge separation instead.
///
/// The note that used to sit here said to watch the diagnostics FPS over Dolby
/// Vision and fall back to the solid fill if it ever stuttered. It did, and that
/// fallback is now automatic: `plozzReducePanelGlass` carries it, so this panel
/// gives up its glass for demanding content while the transport buttons keep
/// theirs.
struct PanelGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 32
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    func body(content: Content) -> some View {
        if reducePanelGlass {
            // A frosted MATERIAL, not a flat black wash.
            //
            // `.thickMaterial` is a static system blur: it still separates the
            // panel from the footage and still reads as a surface, but it is
            // not the live per-frame refraction that costs. The plain
            // `Color.black.opacity` this replaced was cheap in both senses —
            // it looked like a rectangle laid over the video rather than a
            // panel floating above it.
            //
            // The thick variant rather than `.ultraThinMaterial` used elsewhere
            // because this one sits over moving video: a thin frost lets enough
            // of a bright scene through to fight the text on top of it.
            content
                .plozzFrostedBackground(shape)
                .plozzFrostedBorder(shape)
        } else if #available(iOS 26.0, tvOS 26.0, *) {
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

/// Reports the controls layer's own BOTTOM edge in global space, so a measurement
/// taken against the buttons (also global) subtracts two numbers from the same
/// coordinate system. The layer is inset by the tvOS safe area, so its height is NOT
/// its bottom edge — mixing the two put the menus 60pt low, right on the buttons.
struct ControlsBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the track-control row's TOP edge, in the controls layer's coordinate
/// space, so the options menus can be positioned just above the buttons that open
/// them while living outside the transport's view tree.
struct TrackControlsTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the track-control row's width so a menu aligned to one of its buttons
/// can be clamped against the row's trailing edge.
struct TrackControlsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Carries the Speed button's measured leading-edge X (within the track-control
/// row) up to `PlayerControls` so the Speed panel can align to the button. Only the
/// Speed button publishes a value; sibling buttons contribute the default (0), so
/// the reduce keeps the largest (the real measurement) rather than letting a 0
/// clobber it.
struct SpeedButtonLeadingKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif

extension View {
    @ViewBuilder
    func plozzFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder
    func plozzRemoteCommands(
        onExit: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onMove: @escaping (PlozzMoveCommandDirection) -> Void
    ) -> some View {
        #if os(tvOS)
        self
            .onExitCommand(perform: onExit)
            .onPlayPauseCommand(perform: onPlayPause)
            .onMoveCommand { direction in
                switch direction {
                case .up: onMove(.up)
                case .down: onMove(.down)
                case .left: onMove(.left)
                case .right: onMove(.right)
                @unknown default: break
                }
            }
        #else
        self
        #endif
    }

    @ViewBuilder
    func plozzMoveCommand(
        perform action: @escaping (PlozzMoveCommandDirection) -> Void
    ) -> some View {
        #if os(tvOS)
        onMoveCommand { direction in
            switch direction {
            case .up: action(.up)
            case .down: action(.down)
            case .left: action(.left)
            case .right: action(.right)
            @unknown default: break
            }
        }
        #else
        self
        #endif
    }
}

/// The transport buttons' stand-in when live glass is too expensive.
///
/// A style rather than a background modifier because these use the SYSTEM
/// `.glass` / `.glassProminent` button styles, which cannot be told to fall
/// back — hence their staying glass while everything around them had changed,
/// and visibly swapping material the moment a menu opened and re-rendered them.
struct PlayerFrostedButtonStyle: ButtonStyle {
    var prominent: Bool

    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        // Focus takes the same solid white the system glass style uses, so the
        // focused state is identical either way and only the resting one differs.
        let focusedFill = AnyShapeStyle(Color.white)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background {
                if isFocused {
                    shape.fill(focusedFill)
                } else {
                    Color.clear.plozzFrostedBackground(shape, raised: prominent)
                }
            }
            // Dropped when focused, where the white fill is its own boundary and
            // an edge on top of it reads as an outline rather than a shape.
            .plozzFrostedBorder(shape, visible: !isFocused)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


/// Chooses between the system glass button style and the frosted stand-in.
///
/// A modifier rather than a branch inside `playerGlassButton`, because a
/// `View` extension cannot read the environment and the choice depends on it.
private struct PlayerGlassButtonModifier: ViewModifier {
    let prominent: Bool

    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    func body(content: Content) -> some View {
        if reducePanelGlass {
            content.buttonStyle(PlayerFrostedButtonStyle(prominent: prominent))
        } else {
            content.playerSystemGlassButton(prominent: prominent)
        }
    }
}
