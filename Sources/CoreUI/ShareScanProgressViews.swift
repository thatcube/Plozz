#if canImport(SwiftUI)
import CoreModels
import SwiftUI

// MARK: - Progress bar

/// A themed, capsule progress bar shared by every media-share scan surface
/// (Settings header, library cards) on **tvOS and iOS/iPadOS**.
///
/// Two modes, driven purely by whether a fraction is known:
/// - **Determinate** (`fraction != nil`) — an accent-gradient fill that animates
///   smoothly to each new value. Used while enrichment reports "N of M".
/// - **Indeterminate** (`fraction == nil`) — a soft accent band that sweeps the
///   track. Used during the directory walk, where the total is unknowable until
///   the walk finishes.
///
/// The sweep is a single Core Animation `repeatForever` on an offset (GPU-driven,
/// no per-frame SwiftUI invalidation), and it collapses to a static half-lit
/// track under **Reduce Motion**.
public struct ShareScanProgressBar: View {
    /// Completion in 0...1, or `nil` to run indeterminate.
    private let fraction: Double?
    private let height: CGFloat

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    public init(fraction: Double?, height: CGFloat = 6) {
        self.fraction = fraction
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.fill)

                if let fraction {
                    Capsule(style: .continuous)
                        .fill(fillGradient)
                        .frame(width: max(height, width * CGFloat(min(max(fraction, 0), 1))))
                        // Animate the WIDTH only, so a climbing counter glides
                        // instead of stepping — and nothing else in the row moves.
                        .animation(.easeOut(duration: 0.35), value: fraction)
                } else if reduceMotion {
                    // No motion: a static, half-length band still reads as
                    // "working, length unknown" without anything sliding.
                    Capsule(style: .continuous)
                        .fill(fillGradient)
                        .frame(width: width * 0.45)
                        .opacity(0.65)
                } else {
                    Capsule(style: .continuous)
                        .fill(sweepGradient)
                        .frame(width: width * 0.45)
                        .offset(x: sweep ? width * 0.55 : -width * 0.45)
                        .onAppear {
                            withAnimation(
                                .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                            ) {
                                sweep = true
                            }
                        }
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var fillGradient: LinearGradient {
        LinearGradient(
            colors: [palette.accent, palette.accent.opacity(0.62)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Feathered at both ends so the travelling band has no hard edge.
    private var sweepGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: palette.accent.opacity(0.0), location: 0),
                .init(color: palette.accent.opacity(0.9), location: 0.5),
                .init(color: palette.accent.opacity(0.0), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Settings row

/// One busy media share, as it appears at the top of Settings and above a
/// library's grid: share name, the trailing percentage while a fraction is
/// known, a progress bar, and the live phase + counter beneath it.
///
/// Deliberately glyph-free — the phase is already spelled out in words on the
/// line below, so a leading icon only added visual noise and pushed the text off
/// the container's leading edge (which has to line up with the poster wall).
///
/// Shared verbatim by tvOS and iOS/iPadOS; only the container around it differs
/// (see ``ShareScanStatusCard`` / ``ShareScanProgressBanner``).
public struct ShareScanStatusRow: View {
    private let state: ShareScanState

    public init(state: ShareScanState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.displayName)
                    .font(titleFont)
                    .plozzForeground(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let percent = state.percentText {
                    Text(percent)
                        .font(valueFont)
                        .monospacedDigit()
                        .plozzForeground(.secondary)
                }
            }

            ShareScanProgressBar(fraction: state.fraction, height: barHeight)

            Text(detailLine)
                .font(detailFont)
                .monospacedDigit()
                .plozzForeground(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.displayName), \(detailLine)")
    }

    /// "Scanning · 1,204 folders · 8,930 items" / "Updating artwork · 142 of 900".
    private var detailLine: String {
        guard let progress = state.progressDetail else { return state.phase }
        return "\(state.phase) · \(progress.trimmingCharacters(in: .whitespaces))"
    }

    #if os(tvOS)
    private var barHeight: CGFloat { 8 }
    private var titleFont: Font { .system(size: 30, weight: .semibold) }
    private var valueFont: Font { .system(size: 26, weight: .semibold) }
    private var detailFont: Font { .system(size: 24) }
    #else
    private var barHeight: CGFloat { 6 }
    private var titleFont: Font { .subheadline.weight(.semibold) }
    private var valueFont: Font { .subheadline.weight(.semibold) }
    private var detailFont: Font { .caption }
    #endif
}

// MARK: - Settings card

/// The media-share scan status block pinned to the **top of Settings** on both
/// platforms. Renders nothing at all when no share is busy, so Settings looks
/// exactly as before while everything is idle.
///
/// This replaced the floating pill that used to sit over the top-right of tvOS
/// Home: the same information, but somewhere the user goes to *look* for it
/// rather than over the artwork they came to browse.
///
/// Prefer ``ShareScanStatusHeader`` at call sites — it does the (high-frequency)
/// status lookup in its own body so progress ticks can't invalidate the whole
/// Settings page.
public struct ShareScanStatusCard: View {
    private let states: [ShareScanState]

    @Environment(\.themePalette) private var palette

    /// - Parameter states: busy shares, already scoped by the caller to the
    ///   media-share accounts signed in on this device (see
    ///   ``ShareScanStatusModel/busyStates(forShareIDs:)``).
    public init(states: [ShareScanState]) {
        self.states = states
    }

    public var body: some View {
        if states.isEmpty {
            EmptyView()
        } else {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 22) {
                Text(headerTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .plozzForeground(.secondary)
                    .textCase(.uppercase)

                VStack(alignment: .leading, spacing: 24) {
                    ForEach(states) { state in
                        if state.id != states.first?.id {
                            Rectangle()
                                .fill(palette.separator)
                                .frame(height: 1)
                        }
                        ShareScanStatusRow(state: state)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plozzSurface(.raised, cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
            #else
            SettingsSectionGroup(headerTitle) {
                ForEach(states) { state in
                    ShareScanStatusRow(state: state)
                }
            } footer: {
                Text("Your libraries stay usable while this finishes — titles and artwork keep filling in.")
            }
            #endif
        }
    }

    private var headerTitle: String {
        states.count > 1 ? "Updating \(states.count) libraries" : "Updating library"
    }
}

/// Render-isolated Settings header. Scan/enrich progress mutates the status
/// dictionary many times a second; doing the lookup **inside this small view's
/// body** means a progress tick invalidates only the card — not the whole
/// Settings page it heads. (Same containment trick `ShareCatalogRefreshObserver`
/// uses to keep ticks off the library grid.)
public struct ShareScanStatusHeader: View {
    private let status: ShareScanStatusModel?
    private let shareIDs: Set<String>

    /// - Parameters:
    ///   - status: the app-wide status model (optional for previews/tests).
    ///   - shareIDs: media-share account ids signed in on this device, so a
    ///     removed share's late event can't leave a ghost row.
    public init(status: ShareScanStatusModel?, shareIDs: Set<String>) {
        self.status = status
        self.shareIDs = shareIDs
    }

    public var body: some View {
        ShareScanStatusCard(states: states)
    }

    private var states: [ShareScanState] {
        guard let status, !shareIDs.isEmpty else { return [] }
        return status.busyStates(forShareIDs: shareIDs)
    }
}

// MARK: - Library page banner

/// The scan/enrich banner shown at the **top of an opened library** whose media
/// share is still filling in. Explains a grid that's short or gaining titles as
/// you look at it, in the exact same shape as the Settings card — same row, same
/// bar — so the two surfaces read as one feature.
///
/// It deliberately lives here and NOT on the Home library tiles: one share fans
/// out to several libraries, so a per-tile badge printed the identical counter
/// three times over. Home stays clean; the detail is one tap away, where it's
/// about the library you're actually looking at.
///
/// **Render-isolated on purpose:** the banner does its own status lookup, so a
/// share reporting progress dozens of times a second invalidates only the banner
/// — never the poster grid behind it. Renders nothing (and reads nothing) for a
/// library that isn't backed by a busy share.
public struct ShareScanProgressBanner: View {
    private let status: ShareScanStatusModel?
    private let shareID: String?

    /// - Parameters:
    ///   - status: the app-wide status model (optional for previews/tests).
    ///   - shareID: the library's media-share account id, or `nil` when the
    ///     library is a Plex/Jellyfin section — the banner then never draws and
    ///     never observes.
    public init(status: ShareScanStatusModel?, shareID: String?) {
        self.status = status
        self.shareID = shareID
    }

    public var body: some View {
        ZStack {
            if let state {
                ShareScanStatusRow(state: state)
                    .padding(rowInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .plozzSurface(
                        .raised,
                        cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state?.isBusy)
    }

    private var state: ShareScanState? {
        guard let shareID, let status,
              let state = status.state(forShareID: shareID),
              state.isBusy
        else { return nil }
        return state
    }

    #if os(tvOS)
    private var rowInset: CGFloat { 28 }
    #else
    private var rowInset: CGFloat { 16 }
    #endif
}
#endif
