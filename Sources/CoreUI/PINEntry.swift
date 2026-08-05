import CoreModels
import SwiftUI

/// Platform metrics for the PIN screen. A 10-foot remote-driven UI and a phone
/// held at arm's length need genuinely different sizes, and these live at file
/// scope because the views that use them are generic (which can't hold static
/// stored properties).
/// The size the identity badge must be built at.
///
/// Public because the scaffold can't fix a mis-sized badge for you: a view that
/// draws at its own intrinsic size (`ProfileAvatarView`) is clipped, not scaled,
/// by an outer `.frame` — which is exactly how the avatar ended up squashed.
public enum PINLayout {
    public static var badgeSize: CGFloat { PINMetrics.badgeSize }
}

enum PINMetrics {
    #if os(tvOS)
    static let horizontalPadding: CGFloat = 110
    static let badgeSize: CGFloat = 72
    static let keyDiameter: CGFloat = 108
    static let keySpacing: CGFloat = 22
    static let dotSize: CGFloat = 30
    #else
    static let horizontalPadding: CGFloat = 24
    static let badgeSize: CGFloat = 48
    static let keyDiameter: CGFloat = 74
    static let keySpacing: CGFloat = 16
    static let dotSize: CGFloat = 24
    #endif

    #if os(tvOS)
    static let titleFont: Font = .system(size: 64, weight: .bold)
    static let subtitleFont: Font = .title3
    static let nameFont: Font = .title3.weight(.semibold)
    static let proseMaxWidth: CGFloat = 720
    #else
    static let titleFont: Font = .largeTitle.bold()
    static let subtitleFont: Font = .body
    static let nameFont: Font = .headline
    static let proseMaxWidth: CGFloat = .infinity
    #endif

    /// Width of the delete key: it spans the two trailing columns of the bottom
    /// row, so it lines up with the grid rather than floating.
    static var deleteKeyWidth: CGFloat { keyDiameter * 2 + keySpacing }

    /// Intrinsic width of the 3-column dial pad.
    static var padWidth: CGFloat { keyDiameter * 3 + keySpacing * 2 }

    #if os(tvOS)
    /// Fixed width for the prose column, rather than letting it absorb every
    /// spare point. See the layout note in ``PINEntryScaffold``.
    static let proseColumnWidth: CGFloat = 720
    /// The real, honest gap between prose and pad.
    static let columnGap: CGFloat = 120
    /// Prose + gap + pad, centered on screen as one unit.
    static var compositionWidth: CGFloat { proseColumnWidth + columnGap + padWidth }
    #endif
}

/// Position inside a chained PIN gate. Omitted for ordinary one-PIN flows.
public struct PINSequenceStep: Equatable, Sendable {
    public let current: Int
    public let total: Int

    public init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }
}

/// The shared 4-digit PIN screen.
///
/// Everything that asks for four digits uses this — unlocking a profile,
/// unlocking a Plex Home user, and creating or confirming a new PIN — so they're
/// visually indistinguishable. That matters most for the "same PIN as Plex"
/// option: if the two systems looked different, the fact that one PIN satisfies
/// both would stop being obvious.
///
/// The layout is a **3×4 dial pad**, not the single row this used to be. On a
/// remote the row meant every digit was up to ten presses away along one axis and
/// 0 sat past 9; a phone-shaped pad puts any digit within two presses across two
/// axes, which is the whole reason phones and TV apps settled on it.
///
/// Owns the entry state (typed digits) but not the *verdict* — the caller decides
/// whether a PIN was right and feeds an error back down, because only it knows
/// whether that means a network round-trip (Plex) or a local hash comparison
/// (`ProfileLock`).
public struct PINEntryScaffold<Badge: View>: View {
    /// Large heading — what this entry is for ("Enter your PIN", "Create a
    /// Profile Lock"). Carries the whole meaning of the screen, so it's the one
    /// thing a caller must supply.
    public let title: LocalizedStringResource
    /// Supporting line under the title.
    public var subtitle: LocalizedStringResource?
    /// Name shown beside the badge — the profile or Plex Home user in question.
    public let name: String
    /// Error from the last attempt, or `nil`. The slot is reserved either way so
    /// the pad doesn't jump when one appears.
    public let errorMessage: String?
    /// Whether an attempt is in flight (shows a spinner, blocks the pad).
    public let isSubmitting: Bool
    /// Optional caveat under the identity block, e.g. the sync warning.
    public var footnote: LocalizedStringResource?
    /// Position inside a chained PIN gate. Nil for ordinary one-PIN flows.
    public var sequenceStep: PINSequenceStep?
    /// Called with the full PIN as soon as the last digit lands.
    public let onSubmit: (String) -> Void
    public let onCancel: () -> Void
    @ViewBuilder public let badge: () -> Badge

    @Environment(\.themePalette) private var palette
    @State private var pin: String = ""

    public init(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        name: String,
        errorMessage: String? = nil,
        isSubmitting: Bool = false,
        footnote: LocalizedStringResource? = nil,
        sequenceStep: PINSequenceStep? = nil,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.title = title
        self.subtitle = subtitle
        self.name = name
        self.errorMessage = errorMessage
        self.isSubmitting = isSubmitting
        self.footnote = footnote
        self.sequenceStep = sequenceStep
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.badge = badge
    }

    public var body: some View {
        ZStack {
            // Opaque, not a translucent scrim. The keys are liquid glass and
            // glass has to sample a real backdrop — floating them over
            // `.ultraThinMaterial` was glass on glass, which reads muddy and
            // costs a second blur pass for nothing.
            AppBackground(palette: palette).ignoresSafeArea()

            #if os(tvOS)
            // Prose on the left, pad on the right, and the PAIR centered on
            // screen as one composition — the same scheme the wide iOS layout
            // below uses.
            //
            // The prose column is sized explicitly instead of absorbing all the
            // slack. When it was greedy, the pad landed near 75% of the screen
            // and had to be dragged back with a hand-tuned `.offset`, which
            // moved pixels without moving layout: the declared spacing became
            // fiction, the pad rendered inside the prose's reserved column, and
            // any change to padding or key size silently shifted it again.
            // Sizing both columns makes the gap a real number.
            HStack(alignment: .center, spacing: PINMetrics.columnGap) {
                prose(centered: false)
                    .frame(width: PINMetrics.proseColumnWidth, alignment: .leading)
                padColumn
            }
            .frame(maxWidth: PINMetrics.compositionWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, PINMetrics.horizontalPadding)
            #else
            GeometryReader { proxy in
                if usesTwoColumnLayout(proxy.size) {
                    HStack(alignment: .center, spacing: 56) {
                        prose(centered: false)
                            .frame(width: 360, alignment: .leading)
                        VStack(spacing: 24) {
                            padColumn
                            Button("Cancel", action: onCancel)
                        }
                    }
                    // Centre the COMPOSITION, not each column independently.
                    .frame(maxWidth: 780, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 40)
                } else {
                    VStack(spacing: 32) {
                        Spacer(minLength: 0)
                        prose(centered: true)
                            .frame(maxWidth: .infinity, alignment: .center)
                        padColumn
                        Spacer(minLength: 0)
                        Button("Cancel", action: onCancel)
                            .padding(.bottom, 24)
                    }
                    .padding(.horizontal, PINMetrics.horizontalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            #endif
        }
        #if os(tvOS)
        // Menu on the Siri remote backs out. iOS has no equivalent command, so
        // the Cancel button is the way out there.
        .onExitCommand(perform: onCancel)
        #endif
        .onChange(of: errorMessage) { _, newValue in
            if newValue != nil { pin = "" }
        }
    }

    // MARK: Prose column

    private func prose(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 20) {
            if let sequenceStep, sequenceStep.total > 1 {
                PINSequenceIndicator(step: sequenceStep)
                    .padding(.bottom, 4)
            }

            Text(title)
                .font(PINMetrics.titleFont)
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(centered ? .center : .leading)

            if let subtitle {
                Text(subtitle)
                    .font(PINMetrics.subtitleFont)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(centered ? .center : .leading)
            }

            // Whose PIN this is. Small and secondary — the person already knows
            // who they picked; this is confirmation, not the headline.
            HStack(spacing: 14) {
                badge()
                    .clipShape(Circle())
                Text(verbatim: name)
                    .font(PINMetrics.nameFont)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            .padding(.top, 4)

            // Reserved either way so nothing shifts between attempts.
            Text(verbatim: errorMessage ?? " ")
                .font(.callout)
                .foregroundStyle(errorMessage == nil ? Color.clear : .red)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(centered ? .center : .leading)

            if let footnote {
                Label {
                    Text(footnote)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(palette.secondaryText)
            }
        }

        .frame(
            maxWidth: PINMetrics.proseMaxWidth,
            alignment: centered ? .center : .leading
        )
    }

    /// Geometry, not device model: adapts correctly to iPad split view, external
    /// displays and iPhone landscape.
    private func usesTwoColumnLayout(_ size: CGSize) -> Bool {
        size.width >= 760 && size.height >= 620
    }

    // MARK: Pad column

    @ViewBuilder
    private var padColumn: some View {
        VStack(spacing: 28) {
            HStack(spacing: 18) {
                PINProgressDots(filledCount: pin.count)
                if isSubmitting {
                    ProgressView().controlSize(.large)
                }
            }
            PINDialPad(onDigit: appendDigit, onDelete: deleteDigit)
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.5 : 1.0)
        }
        #if os(tvOS)
        // Keep the pad a single focus region so Left from any key returns to the
        // prose side rather than hunting between rows.
        .focusSection()
        #endif
    }

    // MARK: Entry

    private func appendDigit(_ d: String) {
        guard !isSubmitting else { return }
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < ProfileLock.pinLength else { return }
        pin.append(d)
        if pin.count == ProfileLock.pinLength {
            // Auto-submit the moment the last digit lands. Snappy is the goal.
            //
            // Clear immediately rather than waiting for an error to come back: a
            // caller that reports the same message twice in a row (two wrong
            // PINs, same string) produces no change for `onChange` to see, which
            // would leave four filled dots and a pad that ignores every press.
            let entered = pin
            pin = ""
            onSubmit(entered)
        }
    }

    private func deleteDigit() {
        guard !isSubmitting else { return }
        if !pin.isEmpty { pin.removeLast() }
    }

}

/// Quiet progress for a chained profile-PIN then Plex-PIN gate.
///
/// The rail says "this is one continuous two-step action" before the first PIN
/// is entered, while the text removes any ambiguity about why another PIN screen
/// follows. Single-PIN flows pass no step and render nothing.
private struct PINSequenceIndicator: View {
    let step: PINSequenceStep

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(1 ... step.total, id: \.self) { index in
                    Capsule()
                        .fill(
                            index <= step.current
                                ? ThemePalette.brandBlue
                                : palette.secondaryText.opacity(0.28)
                        )
                        .frame(width: 42, height: 6)
                }
            }
            Text("PIN \(step.current) of \(step.total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN \(step.current) of \(step.total)")
    }
}

/// The four progress dots above the pad.
///
/// Outlines that fill in, rather than the boxes-with-dots this used to draw: at a
/// distance a filled circle reads as progress instantly, and it keeps the pad and
/// its indicator in one visual language.
public struct PINProgressDots: View {
    public let filledCount: Int

    @Environment(\.themePalette) private var palette

    public init(filledCount: Int) { self.filledCount = filledCount }

    public var body: some View {
        HStack(spacing: 18) {
            ForEach(0 ..< ProfileLock.pinLength, id: \.self) { idx in
                let filled = idx < filledCount
                Circle()
                    .strokeBorder(palette.secondaryText.opacity(0.75), lineWidth: 2)
                    .background(Circle().fill(filled ? palette.primaryText : .clear))
                    .frame(width: PINMetrics.dotSize, height: PINMetrics.dotSize)
                    // The dot is the payoff for a key press, so it pops rather
                    // than cross-fades — the two together are what make the pad
                    // feel connected to what you typed.
                    .scaleEffect(filled ? 1.0 : 0.9)
                    .animation(.spring(response: 0.26, dampingFraction: 0.55), value: filled)
            }
        }
        .accessibilityLabel("\(filledCount) of \(ProfileLock.pinLength) digits entered")
    }
}

/// The 3×4 dial pad: 1–9, then 0 and a wide delete key on the bottom row.
///
/// Each key is a focusable Button so focus is always anchored and Menu/Back can't
/// fall through to the system. Round keys, because the shape is what makes a
/// 10-foot target readable at a glance — and because delete can then be a capsule
/// that visibly spans two columns without looking like a mistake.
public struct PINDialPad: View {
    public let onDigit: (String) -> Void
    public let onDelete: () -> Void

    public init(onDigit: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.onDigit = onDigit
        self.onDelete = onDelete
    }

    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    private var digitFont: Font {
        .system(size: PINMetrics.keyDiameter * 0.34, weight: .semibold, design: .rounded)
    }

    public var body: some View {
        VStack(spacing: PINMetrics.keySpacing) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: PINMetrics.keySpacing) {
                    ForEach(row, id: \.self) { digit in
                        Button { onDigit(digit) } label: {
                            Text(verbatim: digit).font(digitFont)
                        }
                        .buttonStyle(PINKeyStyle(width: PINMetrics.keyDiameter))
                    }
                }
            }
            HStack(spacing: PINMetrics.keySpacing) {
                Button { onDigit("0") } label: {
                    Text(verbatim: "0").font(digitFont)
                }
                .buttonStyle(PINKeyStyle(width: PINMetrics.keyDiameter))

                Button(action: onDelete) {
                    Image(systemName: "delete.backward")
                        .font(.system(size: PINMetrics.keyDiameter * 0.28, weight: .semibold))
                }
                .buttonStyle(PINKeyStyle(width: PINMetrics.deleteKeyWidth))
                .accessibilityLabel("Delete")
            }
        }
    }
}

/// A pill/circular key. Drawn entirely by the style so the rendered frame is
/// exactly the size asked for — no auto-expanding fill from a bordered style and
/// no inheritance from the parent layout. Focus inverts it to a solid light key
/// with a soft bloom, which is what makes the focused digit obvious from a sofa.
public struct PINKeyStyle: ButtonStyle {
    public let width: CGFloat

    public init(width: CGFloat) { self.width = width }

    public func makeBody(configuration: Configuration) -> some View {
        PINKeyBody(configuration: configuration, width: width)
    }
}

private struct PINKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let width: CGFloat

    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    /// A press is latched rather than read straight from
    /// `configuration.isPressed`.
    ///
    /// A tap — remote click or finger — can lift in well under 100ms, so the raw
    /// flag is often true for a single frame. The pad registered those presses
    /// correctly but drew a state nobody could perceive, which is exactly what
    /// makes a working control feel dead. Latching guarantees a minimum on-screen
    /// dwell, so every digit is *seen* to land.
    @State private var showsPress = false
    /// Pointer hover (iPad trackpad/mouse). tvOS does the same job with focus.
    @State private var isHovering = false
    /// Bumped once per press. Drives haptics, and tags the release so a stale
    /// unlatch from a previous press can't cancel the current one during fast
    /// typing.
    @State private var pressCount = 0

    /// Focus and hover are the same idea on their respective platforms: "this is
    /// the key you're about to hit."
    private var isHighlighted: Bool { isFocused || isHovering }

    private var highlightScale: CGFloat {
        if isFocused { return 1.06 }
        if isHovering { return 1.04 }
        return 1.0
    }

    /// Highlight and press compose rather than override, so a focused key still
    /// visibly depresses instead of snapping back to its resting size.
    private var scale: CGFloat { highlightScale * (showsPress ? 0.94 : 1.0) }

    /// The wash flips polarity with the surface beneath it. A highlighted key is
    /// already bright, so it darkens; a resting key is dark, so it lights up.
    /// Either way the press reads as the key being pushed in.
    private var pressWash: Color { isHighlighted ? .black : palette.primaryText }

    var body: some View {
        configuration.label
            .foregroundStyle(palette.primaryText)
            .frame(width: width, height: PINMetrics.keyDiameter)
            // The app's own liquid-glass card surface, cornered to a capsule.
            // Using it rather than a hand-rolled fill means the keys pick up the
            // same focus bloom, the same Reduce Transparency fallback, and the
            // same tvOS-26 treatment as every card in the app — and can't drift
            // from them.
            .plozzGlassCard(
                cornerRadius: PINMetrics.keyDiameter / 2,
                isFocused: isHighlighted
            )
            .overlay {
                // A capsule matches the key at both widths: the delete key is
                // wider, but the corner radius is driven by the shared height.
                Capsule()
                    .fill(pressWash)
                    .opacity(showsPress ? 0.18 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isHighlighted ? 0.36 : 0), radius: 20, y: 10)
            .scaleEffect(scale)
            // One animation per driver, so a press curve can be snappy without
            // dragging the slower focus bloom along with it.
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .animation(.spring(response: 0.24, dampingFraction: 0.62), value: showsPress)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    pressCount += 1
                    showsPress = true
                } else {
                    releasePress()
                }
            }
            #if !os(tvOS)
            .onHover { hovering in isHovering = hovering }
            #endif
            #if os(iOS)
            // A glass key has no travel and no click, so touch is the only
            // channel left to confirm a digit actually landed.
            .sensoryFeedback(
                .impact(flexibility: .soft, intensity: 0.7),
                trigger: pressCount
            )
            #endif
    }

    private func releasePress() {
        let token = pressCount
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            // A newer press has taken over; leave the key depressed for it.
            guard pressCount == token else { return }
            showsPress = false
        }
    }
}

/// Circular badge slot for the identity beside the title. Kept as its own type so
/// the Plex prompt — which has no avatar view of its own to lean on — can drop an
/// `AsyncImage` or a glyph in and get the same shape as a profile avatar.
public struct PINBadge<Content: View>: View {
    @Environment(\.themePalette) private var palette
    @ViewBuilder public let image: () -> Content

    public init(@ViewBuilder image: @escaping () -> Content) {
        self.image = image
    }

    public var body: some View {
        ZStack {
            Circle().fill(palette.fillSubtle)
            image()
        }
        // Own the proposal. A resizable AsyncImage otherwise accepts the whole
        // prose column and turns a 48pt identity badge into a screen-sized circle.
        .frame(width: PINLayout.badgeSize, height: PINLayout.badgeSize)
        .clipShape(Circle())
    }
}
