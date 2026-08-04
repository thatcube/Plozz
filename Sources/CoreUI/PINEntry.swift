import CoreModels
import SwiftUI

/// Platform metrics for the PIN screen. A 10-foot remote-driven UI and a phone
/// held at arm's length need genuinely different sizes, and these live at file
/// scope because the views that use them are generic (which can't hold static
/// stored properties).
enum PINMetrics {
    #if os(tvOS)
    static let horizontalPadding: CGFloat = 90
    static let badgeSize: CGFloat = 180
    static let lockSize: CGFloat = 52
    #else
    static let horizontalPadding: CGFloat = 24
    static let badgeSize: CGFloat = 108
    static let lockSize: CGFloat = 34
    #endif
}

/// The shared 4-digit PIN screen.
///
/// Two things ask for a PIN now — the Plex Home user switch Plozz has always
/// had, and a profile's own `ProfileLock` — and they should be visually
/// indistinguishable. A person setting the same PIN in both places should not be
/// able to tell which system is asking; that's the whole point of offering to
/// reuse the Plex PIN. So the chrome, the boxes, the keypad and the auto-submit
/// behaviour live here once and both callers supply only what differs: the badge
/// image, the name, and what to do with the digits.
///
/// Owns the entry state (typed digits, submitting) but not the *verdict* — the
/// caller decides whether a PIN was right and feeds an error back down, because
/// only it knows whether that means a network round-trip (Plex) or a local hash
/// comparison (`ProfileLock`).
public struct PINEntryScaffold<Badge: View>: View {
    /// Name shown under the badge — the profile or Plex Home user being opened.
    public let name: String
    /// Error from the last attempt, or `nil`. The slot is reserved either way so
    /// the keypad doesn't jump when one appears.
    public let errorMessage: String?
    /// Whether an attempt is in flight (shows a spinner, blocks the keypad).
    public let isSubmitting: Bool
    /// Optional line under the keypad, e.g. the sync caveat.
    public var footnote: LocalizedStringResource?
    /// Called with the full PIN as soon as the last digit lands.
    public let onSubmit: (String) -> Void
    public let onCancel: () -> Void
    @ViewBuilder public let badge: () -> Badge

    @Environment(\.themePalette) private var palette
    @State private var pin: String = ""

    public init(
        name: String,
        errorMessage: String?,
        isSubmitting: Bool,
        footnote: LocalizedStringResource? = nil,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.name = name
        self.errorMessage = errorMessage
        self.isSubmitting = isSubmitting
        self.footnote = footnote
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.badge = badge
    }

    /// Clears the typed digits. Callers drive this from their error state so a
    /// wrong PIN resets the boxes instead of making the user backspace four times.
    private func reset() { pin = "" }

    public var body: some View {
        ZStack {
            // Full-bleed dimmed backdrop so the PIN screen reads as a modal OVER
            // the app (like Plex does), not as an opaque context switch.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer(minLength: 0)
                badge()
                Text(verbatim: name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    PINBoxes(filledCount: pin.count)
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.large)
                    }
                }
                // Reserve the error slot so the strip doesn't jump up/down when
                // an error appears/clears between attempts.
                Text(verbatim: errorMessage ?? " ")
                    .font(.callout)
                    .foregroundStyle(errorMessage == nil ? Color.clear : .red)
                    .multilineTextAlignment(.center)
                PINStrip(onDigit: appendDigit, onDelete: deleteDigit)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.5 : 1.0)
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .plozzForeground(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, PINMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // tvOS only: Menu on the Siri remote backs out of the prompt. iOS has no
        // equivalent command (the Cancel button is the way out there).
        #if os(tvOS)
        .onExitCommand(perform: onCancel)
        #endif
        .onChange(of: errorMessage) { _, newValue in
            if newValue != nil { reset() }
        }
    }

    private func appendDigit(_ d: String) {
        guard !isSubmitting else { return }
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard pin.count < ProfileLock.pinLength else { return }
        pin.append(d)
        if pin.count == ProfileLock.pinLength {
            // Auto-submit the moment the last digit lands. Snappy is the goal.
            //
            // Clear immediately rather than waiting for an error to come back:
            // a caller that reports the same message twice in a row (two wrong
            // PINs, same string) produces no change for `onChange` to see, which
            // would leave four filled boxes and a keypad that silently ignores
            // every press.
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

/// Large circular badge with a small lock in the corner — the shape both Plex's
/// tvOS PIN screen and ours use. `image` supplies whatever identity art the
/// caller has (a Plex thumb, a profile avatar, or a fallback glyph).
public struct PINBadge<Content: View>: View {
    @Environment(\.themePalette) private var palette
    @ViewBuilder public let image: () -> Content

    public init(@ViewBuilder image: @escaping () -> Content) {
        self.image = image
    }



    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(palette.fillSubtle)
                image()
            }
            .frame(width: PINMetrics.badgeSize, height: PINMetrics.badgeSize)
            .clipShape(Circle())

            ZStack {
                Circle().fill(Color.green)
                Image(systemName: "lock.fill")
                    .font(.system(size: PINMetrics.lockSize * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: PINMetrics.lockSize, height: PINMetrics.lockSize)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 2))
            .offset(x: 4, y: 4)
        }
    }
}

/// Four large rounded boxes that fill as digits land. Each is dark/outline when
/// empty and solid+dot when filled. The next-to-fill box gets a thin highlight
/// so entry progress is visible without any focus on the boxes themselves (the
/// strip below owns focus).
public struct PINBoxes: View {
    public let filledCount: Int

    public init(filledCount: Int) { self.filledCount = filledCount }

    #if os(tvOS)
    private static let boxWidth: CGFloat = 72
    private static let boxHeight: CGFloat = 84
    private static let boxSpacing: CGFloat = 18
    #else
    private static let boxWidth: CGFloat = 56
    private static let boxHeight: CGFloat = 68
    private static let boxSpacing: CGFloat = 14
    #endif

    public var body: some View {
        HStack(spacing: Self.boxSpacing) {
            ForEach(0 ..< ProfileLock.pinLength, id: \.self) { idx in
                let filled = idx < filledCount
                let next = !filled && idx == filledCount
                ZStack {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                        .fill(filled ? Color.white.opacity(0.95) : Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                        .strokeBorder(
                            next ? Color.white.opacity(0.85) : Color.white.opacity(filled ? 0 : 0.25),
                            lineWidth: next ? 3 : 2
                        )
                    if filled {
                        Circle()
                            .fill(Color.black)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: Self.boxWidth, height: Self.boxHeight)
            }
        }
    }
}

/// Single horizontal row of digit keys 0–9 plus a delete key — the layout Plex
/// itself uses on tvOS, and the one-axis path the Siri remote handles best. Each
/// key is a focusable Button so focus is always anchored and Menu/Back can't fall
/// through to the system.
///
/// Compact, FIXED-size keys (no tile-to-fill). With 11 keys at 84pt + 10×16
/// spacing the strip is ~1080pt and centers naturally on a 1920pt tvOS screen,
/// leaving ~400pt clearance per side — zero clipping, and plenty of room for the
/// focused-key scale lift.
public struct PINStrip: View {
    public let onDigit: (String) -> Void
    public let onDelete: () -> Void

    public init(onDigit: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.onDigit = onDigit
        self.onDelete = onDelete
    }

    private let digits: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    #if os(tvOS)
    private let digitKeyWidth: CGFloat = 84
    private let deleteKeyWidth: CGFloat = 104
    private let keyHeight: CGFloat = 100
    #else
    private let digitKeyWidth: CGFloat = 78
    private let deleteKeyWidth: CGFloat = 78
    private let keyHeight: CGFloat = 66
    #endif

    public var body: some View {
        #if os(tvOS)
        // One row: the shape Plex uses on tvOS and the single axis the Siri
        // remote handles best. ~1080pt wide, which centres comfortably on a
        // 1920pt screen.
        HStack(spacing: 16) {
            ForEach(digits, id: \.self) { d in digitKey(d) }
            deleteKey
        }
        // Vertical slack so the focus lift has clearance without bumping
        // neighbors in the column.
        .padding(.vertical, 12)
        #else
        // A phone is nowhere near wide enough for the tvOS strip (11 keys would
        // need ~1080pt against an iPhone's ~390), so touch platforms get the
        // familiar 3-across dial pad instead.
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(Array(digits.prefix(9)).chunked(into: 3), id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { d in digitKey(d) }
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                digitKey("0")
                deleteKey
            }
        }
        .padding(.vertical, 12)
        #endif
    }

    private func digitKey(_ d: String) -> some View {
        Button {
            onDigit(d)
        } label: {
            Text(verbatim: d)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
        }
        .buttonStyle(PINKeyStyle(width: digitKeyWidth, height: keyHeight, isDestructive: false))
    }

    private var deleteKey: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 28, weight: .semibold))
        }
        .buttonStyle(PINKeyStyle(width: deleteKeyWidth, height: keyHeight, isDestructive: true))
        .accessibilityLabel("Delete")
    }
}

private extension Array {
    /// Splits into fixed-size rows for the dial-pad grid.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

/// Fixed-size, focus-friendly key button. Drawn entirely by this style so the
/// key's rendered frame is exactly width×height — no auto-expanding fill from a
/// bordered/prominent style and no inheritance from the parent layout. Focused
/// state lifts (scale 1.08) and brightens, with a soft drop shadow for depth.
public struct PINKeyStyle: ButtonStyle {
    public let width: CGFloat
    public let height: CGFloat
    public let isDestructive: Bool

    public init(width: CGFloat, height: CGFloat, isDestructive: Bool) {
        self.width = width
        self.height = height
        self.isDestructive = isDestructive
    }

    public func makeBody(configuration: Configuration) -> some View {
        PINKeyBody(
            configuration: configuration,
            width: width,
            height: height,
            isDestructive: isDestructive
        )
    }
}

private struct PINKeyBody: View {
    let configuration: ButtonStyle.Configuration
    let width: CGFloat
    let height: CGFloat
    let isDestructive: Bool
    @Environment(\.isFocused) private var isFocused

    public var body: some View {
        configuration.label
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(0.18))
            )
            .foregroundStyle(
                isFocused
                    ? (isDestructive ? Color.red : Color.black)
                    : Color.primary
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.38 : 0),
                radius: isFocused ? 14 : 0,
                y: isFocused ? 6 : 0
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
