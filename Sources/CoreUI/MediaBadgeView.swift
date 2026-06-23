#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontal row of capability badges (`TV-14`, `4K`, `HDR`, `Dolby Vision`,
/// `Dolby Atmos`, `5.1`, …) for the detail hero. Renders nothing when empty.
public struct MediaBadgeRow: View {
    private let badges: [MediaBadge]

    public init(badges: [MediaBadge]) {
        self.badges = badges
    }

    public var body: some View {
        if !badges.isEmpty {
            HStack(alignment: .center, spacing: 10) {
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

    /// Shared type scale so every treatment lines up to the same cap height.
    private static let textFont = Font.system(size: 21, weight: .semibold)
    private static let dolbyWordFont = Font.system(size: 16, weight: .semibold)
    private static let dolbyFormatFont = Font.system(size: 13, weight: .medium)
    /// Heavy weights for the HDR wordmark so it reads as a bold logo: the format
    /// name (`HDR`/`HLG`) and its numeric variant (`10`, `10+`).
    private static let hdrHeadFont = Font.system(size: 21, weight: .black)
    private static let hdrSuffixFont = Font.system(size: 16, weight: .heavy)
    /// DTS wordmark weights: a heavy lowercase `dts` head with a slightly
    /// smaller, emphasized format suffix (`X`, `HD`) and a light separator.
    private static let dtsHeadFont = Font.system(size: 22, weight: .black)
    private static let dtsSepFont = Font.system(size: 18, weight: .light)
    private static let dtsSuffixFont = Font.system(size: 19, weight: .heavy)
    private static let cornerRadius: CGFloat = 6
    private static let hPadding: CGFloat = 11
    /// Tighter horizontal padding for the borderless HDR wordmark, which has no
    /// pill background and so doesn't need the inset the filled pills use.
    private static let hdrHPadding: CGFloat = 2
    private static let vPadding: CGFloat = 5
    /// Shared pill height so every pill badge (rating, resolution, spec) lines
    /// up to the exact same height regardless of the font it uses.
    private static let pillHeight: CGFloat = 36

    public init(badge: MediaBadge) {
        self.badge = badge
    }

    public var body: some View {
        switch badge.style {
        case .rating:
            label(badge.label, font: Font.custom("Bungee-Regular", size: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.65), lineWidth: 3)
                )
                .accessibilityLabel(badge.label)
        case .prominent:
            label(badge.label, textColor: .black)
                .background(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.white)
                )
                .accessibilityLabel(badge.label)
        case .spec:
            label(badge.label)
                .background(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                )
                .accessibilityLabel(badge.label)
        case .hdr:
            hdrLabel(badge.label)
                .accessibilityLabel(badge.label)
        case .dts:
            dtsLabel(badge.label)
                .accessibilityLabel(badge.label)
        case .dolby:
            VStack(alignment: .center, spacing: -1) {
                HStack(alignment: .center, spacing: 5) {
                    DolbyDoubleD()
                        .fill(Color.white)
                        .frame(width: 21, height: 14)
                    Text("Dolby")
                        .font(Self.dolbyWordFont)
                        .foregroundStyle(.white)
                }
                Text(badge.dolbyFormatWord.uppercased())
                    .font(Self.dolbyFormatFont)
                    .foregroundStyle(.white)
                    .tracking(1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .accessibilityLabel(badge.label)
        }
    }

    private func label(_ text: String, textColor: Color = .white, font: Font? = nil) -> some View {
        Text(text)
            .font(font ?? Self.textFont)
            .foregroundStyle(textColor)
            .textCase(.uppercase)
            .tracking(0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, Self.hPadding)
            .frame(height: Self.pillHeight)
    }

    /// A two-weight HDR wordmark filled with the HDR gradient (no pill behind
    /// it): the format name (`HDR`/`HLG`) in a heavy cap height with any numeric
    /// variant (`10`, `10+`) set slightly smaller and raised, so `HDR10` reads as
    /// a bold gradient logo rather than flat text.
    private func hdrLabel(_ text: String) -> some View {
        let parts = Self.splitHDR(text)
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(parts.head)
                .font(Self.hdrHeadFont)
            if let suffix = parts.suffix {
                Text(suffix)
                    .font(Self.hdrSuffixFont)
                    .baselineOffset(1)
            }
        }
        .foregroundStyle(Self.hdrGradient)
        .tracking(0.5)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, Self.hdrHPadding)
        .frame(height: Self.pillHeight)
    }

    /// A custom DTS wordmark logo (no pill): lowercase heavy `dts` with the
    /// format suffix (`X`, `HD`) emphasized and the separator (`:`/`-`) set
    /// lighter, so `DTS:X`/`DTS-HD` read as a brand mark beside the Dolby logos
    /// without bundling the trademarked artwork.
    private func dtsLabel(_ text: String) -> some View {
        let parts = Self.splitDTS(text)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(parts.head)
                .font(Self.dtsHeadFont)
                .tracking(-0.5)
            if let separator = parts.separator {
                Text(separator)
                    .font(Self.dtsSepFont)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let suffix = parts.suffix {
                Text(suffix)
                    .font(Self.dtsSuffixFont)
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, Self.hdrHPadding)
        .frame(height: Self.pillHeight)
    }

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
    /// wordmark, evoking the wide luminance range HDR represents.
    private static let hdrGradient = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.80, blue: 0.25),
            Color(red: 0.95, green: 0.35, blue: 0.45),
            Color(red: 0.25, green: 0.75, blue: 0.95)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// The iconic Dolby "double-D" mark: two back-to-back D shapes with their
/// straight edges meeting at the centre and their bellies bulging outward.
/// Drawn as a vector so it stays crisp at any size without bundling a
/// trademarked image asset.
public struct DolbyDoubleD: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let h = rect.height
        let dWidth = h * 0.72
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
