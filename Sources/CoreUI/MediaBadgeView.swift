#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// How much to shrink the badges, for surfaces that show them somewhere tighter
/// than the detail hero they were drawn for.
///
/// A scale rather than a second set of numbers: a badge is a wordmark built from
/// a dozen interlocking measurements — the dts dash is positioned against the
/// `H` beside it, the Dolby format word sits under its double-D — and a second
/// hand-tuned set would drift out of agreement with the first. Scaling keeps the
/// one set of relationships and changes only how big it is drawn.
private struct MediaBadgeScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// See ``MediaBadgeScaleKey``. 1 is the size the badges were designed at.
    public var mediaBadgeScale: CGFloat {
        get { self[MediaBadgeScaleKey.self] }
        set { self[MediaBadgeScaleKey.self] = newValue }
    }
}

/// A horizontal row of capability badges (`TV-14`, `4K`, `HDR`, `Dolby Vision`,
/// `Dolby Atmos`, `5.1`, …) for the detail hero. Renders nothing when empty.
public struct MediaBadgeRow: View {
    @Environment(\.mediaBadgeScale) private var scale
    private let badges: [MediaBadge]

    public init(badges: [MediaBadge]) {
        self.badges = badges
    }

    public var body: some View {
        if !badges.isEmpty {
            HStack(alignment: .center, spacing: 10 * scale) {
                ForEach(badges) { badge in
                    MediaBadgeChip(badge: badge)
                }
            }
        }
    }
}

/// A single capability badge painted in one of the three Apple-TV-style
/// treatments:
/// - `.rating` — an outlined pill with a transparent fill (`TV-14`, `PG-13`).
/// - `.spec` — a solid, faintly-filled gray pill (`4K`, `HDR`, `5.1`, `DTS:X`).
/// - `.dolby` — the Dolby double-D logo with a stacked wordmark (`Dolby` over
///   the format name), no pill.
public struct MediaBadgeChip: View {
    private let badge: MediaBadge

    /// The active theme palette, so every badge paints with the theme's primary
    /// text colour (white in dark and Pure Black, near-black in light) instead of a
    /// hardcoded white that vanishes against a light-mode background.
    @Environment(\.themePalette) private var palette

    /// The active appearance. The HDR wordmark's gradient is intentionally bright
    /// (it evokes HDR's luminance range), but those light gold/cyan stops wash out
    /// against a light-mode background — so in light mode we swap in darker, still
    /// fully-saturated versions of the same hues.
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @Environment(\.mediaBadgeScale) private var scale

    /// Shared type scale so every treatment lines up to the same cap height.
    private var textFont: Font { .system(size: 21 * scale, weight: .semibold) }
    /// Smaller scale for the resolution pill (`4K`, `1080P`, `.prominent`) and the
    /// `.spec` codec/channel pills, which read as chunky at the shared size —
    /// deliberately more compact than the HDR/SDR/DTS marks, which keep their size.
    private var specFont: Font { .system(size: 14 * scale, weight: .bold) }
    private var specPillHeight: CGFloat { 22 * scale }
    private var specHPadding: CGFloat { 8 * scale }
    /// A rounder radius for the resolution/spec pills specifically, so they read
    /// as softer chips than the sharper rating/HDR treatments.
    private var specCornerRadius: CGFloat { 8 * scale }
    private var dolbyWordFont: Font { .system(size: 13 * scale, weight: .semibold) }
    private var dolbyFormatFont: Font { .system(size: 10 * scale, weight: .medium) }
    /// Heavy weights for the HDR/SDR wordmark so it reads as a bold logo: the
    /// format name (`HDR`/`HLG`/`SDR`) and its numeric variant (`10`, `10+`). The
    /// numeric suffix keeps its own size so shrinking the head leaves `10+` intact.
    private var hdrHeadFont: Font { .system(size: 18 * scale, weight: .black) }
    private var hdrSuffixFont: Font { .system(size: 14 * scale, weight: .heavy) }
    /// DTS wordmark weights: a heavy lowercase `dts` head with the `-HD` suffix
    /// rendered as one connected gray unit — a short `HD` (about as tall as the
    /// `s`) with the dash drawn as a solid bar fused to the `H`.
    private var dtsHeadFont: Font { .system(size: 22 * scale, weight: .black) }
    private var dtsSuffixFont: Font { .system(size: 17 * scale, weight: .black) }
    /// The fused dash bar of the dts-HD mark: sized to the shorter `HD`, raised
    /// to the `H`'s mid-height, gapped from the `dts` on its left and overlapped
    /// into the `H` on its right so the two connect.
    private var dtsDashWidth: CGFloat { 7 * scale }
    private var dtsDashThickness: CGFloat { 3 * scale }
    private var dtsDashRaise: CGFloat { 6 * scale }
    private var dtsDashLeading: CGFloat { 2 * scale }
    private var dtsDashOverlap: CGFloat { 2 * scale }
    /// Plain trailing channel-layout number appended to a format logo (the `5.1`
    /// beside a Dolby mark). Sized to the smaller Dolby wordmark.
    private var channelFont: Font { .system(size: 15 * scale, weight: .semibold) }
    /// A bolder channel number for the dts-HD mark specifically.
    private var dtsChannelFont: Font { .system(size: 18 * scale, weight: .heavy) }
    /// The oversized `X` of the dts:X mark, larger than the `dts` head and
    /// filled with the orange dts:X gradient.
    private var dtsXFont: Font { .system(size: 32 * scale, weight: .black) }
    private var cornerRadius: CGFloat { 6 * scale }
    private var hPadding: CGFloat { 11 * scale }
    /// Tighter horizontal padding for the borderless HDR wordmark, which has no
    /// pill background and so doesn't need the inset the filled pills use.
    private var hdrHPadding: CGFloat { 2 * scale }
    private var vPadding: CGFloat { 5 * scale }
    /// Shared pill height so every pill badge (rating, resolution, spec) lines
    /// up to the exact same height regardless of the font it uses.
    private var pillHeight: CGFloat { 36 * scale }

    public init(badge: MediaBadge) {
        self.badge = badge
    }

    public var body: some View {
        Group {
            switch badge.style {
            case .rating:
                label(
                    badge.label,
                    textColor: palette.primaryText,
                    font: ratingFont,
                    height: ratingPillHeight,
                    hPadding: ratingHPadding
                )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                palette.primaryText.opacity(0.65),
                                lineWidth: ratingBorderWidth
                            )
                    )
                    .accessibilityLabel(badge.label)
            case .prominent:
                // The eye-catching "chip": a solid fill of the theme's primary colour
                // with the background colour punched through as the text, so it stays
                // a high-contrast highlight in every theme (white-on-dark in light
                // mode, dark-on-white in dark and Pure Black) rather than white-on-white.
                // This is the resolution pill (`4K`/`1080p`); it uses the same compact
                // sizing as `.spec` so it stays smaller than the HDR/SDR/DTS marks.
                label(
                    badge.label,
                    textColor: palette.backgroundBase,
                    font: specFont,
                    height: specPillHeight,
                    hPadding: specHPadding
                )
                    .background(
                        RoundedRectangle(cornerRadius: specCornerRadius, style: .continuous)
                            .fill(palette.primaryText)
                    )
                    .accessibilityLabel(badge.label)
            case .spec:
                label(
                    badge.label,
                    textColor: palette.primaryText,
                    font: specFont,
                    height: specPillHeight,
                    hPadding: specHPadding
                )
                    .background(
                        RoundedRectangle(cornerRadius: specCornerRadius, style: .continuous)
                            .fill(palette.primaryText.opacity(0.16))
                    )
                    .accessibilityLabel(badge.label)
            case .hdr:
                hdrLabel(badge.label)
                    .accessibilityLabel(badge.label)
            case .sdr:
                sdrBrushedLabel(badge.label)
                    .accessibilityLabel(badge.label)
            case .dts:
                HStack(alignment: .center, spacing: 6 * scale) {
                    dtsLabel(badge.label)
                    if let detail = badge.detail {
                        // DTS-HD: nudge the channel number down/left to sit better
                        // against the shorter, baseline-aligned dts-HD wordmark, and
                        // render it a little bolder.
                        channelText(detail, font: dtsChannelFont)
                            .offset(x: -2 * scale, y: 2 * scale)
                    }
                }
                .accessibilityLabel(badge.accessibilityText)
            case .dolby:
                HStack(alignment: .center, spacing: 6 * scale) {
                    VStack(alignment: .center, spacing: -2 * scale) {
                        HStack(alignment: .center, spacing: 4 * scale) {
                            DolbyDoubleD()
                                .fill(palette.primaryText)
                                .frame(width: 14 * scale, height: 10 * scale)
                            Text("Dolby")
                                .font(dolbyWordFont)
                                .foregroundStyle(palette.primaryText)
                        }
                        Text(badge.dolbyFormatWord.uppercased())
                            .font(dolbyFormatFont)
                            .foregroundStyle(palette.primaryText)
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    if let detail = badge.detail {
                        channelText(detail)
                    }
                }
                .accessibilityLabel(badge.accessibilityText)
            }
        }
        // A badge is one visual wordmark/chip. Let rows overflow as a unit rather
        // than independently truncating "Dolby Digital+" or a trailing channel
        // count while later badges remain visible.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A trailing channel-layout number (`5.1`/`7.1`) rendered as plain white
    /// text with no pill, so it reads as part of the preceding format logo.
    private func channelText(_ text: String, font: Font? = nil) -> some View {
        Text(text)
            .font(font ?? channelFont)
            .foregroundStyle(palette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var ratingFont: Font {
        #if os(iOS)
        return .custom(
            "Bungee-Regular",
            size: (horizontalSizeClass == .compact ? 13 : 15) * scale
        )
        #else
        return .custom("Bungee-Regular", size: 18 * scale)
        #endif
    }

    private var ratingPillHeight: CGFloat {
        #if os(iOS)
        return (horizontalSizeClass == .compact ? 28 : 32) * scale
        #else
        return pillHeight
        #endif
    }

    private var ratingHPadding: CGFloat {
        #if os(iOS)
        return (horizontalSizeClass == .compact ? 8 : 9) * scale
        #else
        return hPadding
        #endif
    }

    private var ratingBorderWidth: CGFloat {
        #if os(iOS)
        return 2 * scale
        #else
        return 3
        #endif
    }

    private func label(
        _ text: String,
        textColor: Color,
        font: Font? = nil,
        height: CGFloat? = nil,
        hPadding: CGFloat? = nil
    ) -> some View {
        Text(text)
            .font(font ?? textFont)
            .foregroundStyle(textColor)
            .textCase(.uppercase)
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, hPadding ?? self.hPadding)
            .frame(height: height ?? pillHeight)
    }

    /// A two-weight HDR wordmark filled with the HDR gradient (no pill behind
    /// it): the format name (`HDR`/`HLG`) in a heavy cap height with any numeric
    /// variant (`10`, `10+`) set slightly smaller and raised, so `HDR10` reads as
    /// a bold gradient logo rather than flat text.
    private func hdrLabel(_ text: String) -> some View {
        let parts = Self.splitHDR(text)
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(parts.head)
                .font(hdrHeadFont)
            if let suffix = parts.suffix {
                Text(suffix)
                    .font(hdrSuffixFont)
                    .baselineOffset(1)
            }
        }
        .foregroundStyle(hdrGradient)
        .tracking(0.5)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, hdrHPadding)
        .frame(height: pillHeight)
    }

    /// The SDR counterpart to ``hdrLabel``: the same borderless heavy wordmark
    /// (no pill), but filled with a muted, theme-aware brushed-metal sheen instead
    /// of HDR's vibrant luminance gradient — a matte logo that reads as the
    /// deliberate opposite of the shiny HDR mark while still sitting in the badge
    /// row as a peer.
    private func sdrBrushedLabel(_ text: String) -> some View {
        Text(text)
            .font(hdrHeadFont)
            .textCase(.uppercase)
            .foregroundStyle(sdrBrushedGradient)
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, hdrHPadding)
            .frame(height: pillHeight)
    }

    /// Diagonal satin sheen for the brushed-metal SDR wordmark: a mid-neutral base
    /// with a single brighter band crossing on the diagonal, theme-aware so it
    /// stays a muted silver in dark and Pure Black and a muted graphite in light.
    private var sdrBrushedGradient: LinearGradient {
        let stops: [Gradient.Stop] = colorScheme == .light
            ? [
                .init(color: Color(white: 0.34), location: 0.0),
                .init(color: Color(white: 0.30), location: 0.40),
                .init(color: Color(white: 0.58), location: 0.50),
                .init(color: Color(white: 0.32), location: 0.60),
                .init(color: Color(white: 0.34), location: 1.0)
            ]
            : [
                .init(color: Color(white: 0.62), location: 0.0),
                .init(color: Color(white: 0.66), location: 0.40),
                .init(color: Color(white: 0.96), location: 0.50),
                .init(color: Color(white: 0.64), location: 0.60),
                .init(color: Color(white: 0.62), location: 1.0)
            ]
        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Muted gray for the `-HD` portion of the dts-HD mark: the theme's secondary
    /// text knocked back a bit further so the `HD` reads as a quieter gray than
    /// the surrounding metadata in both light and dark.
    private var dtsHDColor: Color { palette.secondaryText.opacity(0.72) }

    /// A custom DTS wordmark logo (no pill): lowercase heavy `dts` with the
    /// format suffix (`X`, `HD`) emphasized and the separator (`:`/`-`) set
    /// lighter, so `DTS:X`/`DTS-HD` read as a brand mark beside the Dolby logos
    /// without bundling the trademarked artwork.
    private func dtsLabel(_ text: String) -> some View {
        let parts = Self.splitDTS(text)
        let isX = parts.suffix?.uppercased() == "X"
        return HStack(alignment: isX ? .center : .firstTextBaseline, spacing: isX ? 1 : 0) {
            Text(parts.head)
                .font(dtsHeadFont)
                .tracking(-0.5)
                .foregroundStyle(palette.primaryText)
            if isX {
                Text("X")
                    .font(dtsXFont)
                    .foregroundStyle(Self.dtsXGradient)
            } else if parts.separator == "-", let suffix = parts.suffix {
                // dts-HD: a short, much smaller `HD` sitting on the dts baseline,
                // with the dash drawn as a solid bar at the `H`'s mid-height and
                // overlapped into it so the two fuse. The whole unit is gray.
                Rectangle()
                    .fill(dtsHDColor)
                    .frame(width: dtsDashWidth, height: dtsDashThickness)
                    .padding(.leading, dtsDashLeading)
                    .padding(.trailing, -dtsDashOverlap)
                    .alignmentGuide(.firstTextBaseline) { _ in
                        dtsDashThickness / 2 + dtsDashRaise
                    }
                Text(suffix)
                    .font(dtsSuffixFont)
                    .foregroundStyle(dtsHDColor)
            } else {
                Text(verbatim: (parts.separator ?? "") + (parts.suffix ?? ""))
                    .font(dtsSuffixFont)
                    .foregroundStyle(dtsHDColor)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, hdrHPadding)
        .frame(height: pillHeight)
    }

    /// The orange dts:X gradient (light orange highlight → deep orange) used to
    /// fill the oversized `X`, evoking the official mark.
    private static let dtsXGradient = LinearGradient(
        colors: [
            Color(red: 0.99, green: 0.72, blue: 0.36),
            Color(red: 0.95, green: 0.52, blue: 0.16),
            Color(red: 0.90, green: 0.40, blue: 0.08)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Splits a DTS label into a lowercase wordmark head (`dts`), an optional
    /// separator (`:`/`-`), and an optional format suffix (`X`/`HD`).
    private static func splitDTS(_ text: String) -> (head: String, separator: String?, suffix: String?) {
        let upper = text.uppercased()
        guard upper.hasPrefix("DTS") else { return (text.lowercased(), nil, nil) }
        let rest = String(upper.dropFirst(3))
        guard let first = rest.first else { return ("dts", nil, nil) }
        let separator = String(first)
        let suffix = String(rest.dropFirst())
        return ("dts", separator, suffix.isEmpty ? nil : suffix)
    }
    private static func splitHDR(_ text: String) -> (head: String, suffix: String?) {
        let upper = text.uppercased()
        if upper.hasPrefix("HDR") {
            let suffix = String(upper.dropFirst(3))
            return ("HDR", suffix.isEmpty ? nil : suffix)
        }
        return (upper, nil)
    }

    /// HDR accent gradient (warm highlight → cool shadow) used to fill the HDR
    /// wordmark, evoking the wide luminance range HDR represents. In dark and Pure Black the
    /// stops are bright (gold → pink → cyan); in light mode they're replaced with
    /// darker, deeply-saturated versions of the *same* hues so the logo keeps its
    /// vibrant identity while staying legible against a light background.
    private var hdrGradient: LinearGradient {
        let colors: [Color] = colorScheme == .light
            ? [
                Color(red: 0.82, green: 0.55, blue: 0.00),
                Color(red: 0.80, green: 0.12, blue: 0.28),
                Color(red: 0.05, green: 0.42, blue: 0.72)
            ]
            : [
                Color(red: 1.00, green: 0.80, blue: 0.25),
                Color(red: 0.95, green: 0.35, blue: 0.45),
                Color(red: 0.25, green: 0.75, blue: 0.95)
            ]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The iconic Dolby "double-D" mark: two back-to-back D shapes with their
/// straight edges meeting at the centre and their bellies bulging outward.
/// Drawn as a vector so it stays crisp at any size without bundling a
/// trademarked image asset.
public struct DolbyDoubleD: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let h = rect.height
        let dWidth = h * 0.62
        let gap = h * 0.16
        let totalWidth = dWidth * 2 + gap
        let startX = rect.midX - totalWidth / 2

        let leftRect = CGRect(x: startX, y: rect.minY, width: dWidth, height: h)
        let rightRect = CGRect(x: startX + dWidth + gap, y: rect.minY, width: dWidth, height: h)

        var path = Path()
        // Right-side D is normal; left-side D mirrors it. Their curved bellies
        // meet toward the centre and the straight stems sit on the outer edges —
        // the orientation of the real Dolby double-D mark.
        path.addPath(dShape(in: leftRect, mirrored: false))
        path.addPath(dShape(in: rightRect, mirrored: true))
        return path
    }

    /// A solid "D": one straight vertical edge plus a curved belly bulging away
    /// from it. `mirrored` flips the straight edge to the right so a pair reads
    /// as the back-to-back Dolby mark.
    private func dShape(in r: CGRect, mirrored: Bool) -> Path {
        let straightX = mirrored ? r.maxX : r.minX
        // Push the control points past the far edge so the belly reaches it.
        let controlX = mirrored ? r.minX - r.width * 0.33 : r.maxX + r.width * 0.33
        var p = Path()
        p.move(to: CGPoint(x: straightX, y: r.minY))
        p.addLine(to: CGPoint(x: straightX, y: r.maxY))
        p.addCurve(
            to: CGPoint(x: straightX, y: r.minY),
            control1: CGPoint(x: controlX, y: r.maxY),
            control2: CGPoint(x: controlX, y: r.minY)
        )
        p.closeSubpath()
        return p
    }
}

#endif
