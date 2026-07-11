#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// The lower-detail metadata block: cast row, plus a studios/tags information
/// strip. Shown beneath the hero on movie and series detail pages so the rich
/// metadata Jellyfin already holds (and the web client shows) is finally
/// surfaced on tvOS — most valuable for anime, where voice cast, studios and
/// tags are the defining metadata.
struct DetailExtrasView: View {
    let item: MediaItem
    /// Leading inset so the cast row and chip strips align with the hero text
    /// above. Defaults to the standard screen padding.
    var leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding
    /// Series pages supply their cosmetic recede model so only Cast participates
    /// in the browser transition. Movie detail leaves this nil and stays visible.
    var seriesRecedeModel: SeriesHeroRecedeModel? = nil

    private var hasContent: Bool {
        !item.cast.isEmpty || !item.studios.isEmpty || !item.tags.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 28) {
                if !item.cast.isEmpty {
                    CastRowView(people: item.cast, leadingInset: leadingInset)
                        .modifier(SeriesCastRevealModifier(model: seriesRecedeModel))
                }
                if !item.studios.isEmpty {
                    StudiosRow(studios: item.studios)
                }
                if !item.tags.isEmpty {
                    InfoChipsRow(title: "Tags", values: Array(item.tags.prefix(40)), leadingInset: leadingInset)
                }
            }
        }
    }
}

private struct SeriesCastRevealModifier: ViewModifier {
    let model: SeriesHeroRecedeModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let revealed = model?.isReceded ?? true
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 48)
            .disabled(!revealed)
            .accessibilityHidden(!revealed)
            .animation(
                reduceMotion
                    ? nil
                    : (revealed
                        ? SeriesHeroRevealTransition.entrance
                        : .easeOut(duration: 0.14)),
                value: revealed
            )
    }
}

/// A labelled, wrapping strip of pill chips (e.g. studios or tags).
private struct InfoChipsRow: View {
    let title: String
    let values: [String]
    var leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
            FlowLayout(spacing: 12, lineSpacing: 12) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.10))
                        )
                }
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
    }
}

/// The studios strip. Resolves a TMDb company logo per studio name (works for
/// both Jellyfin and Plex, neither of which serves studio logos reliably), and
/// renders studios that have a logo first — as logo chips — followed by the
/// remaining studios as plain text chips. Falls back to text for every studio
/// when the TMDb token is absent or no logo is found.
private struct StudiosRow: View {
    private let studios: [String]

    @State private var ordered: [Studio]
    @State private var didResolve = false
    @Environment(\.plozzMetrics) private var metrics

    init(studios: [String]) {
        self.studios = studios
        _ordered = State(initialValue: studios.map { Studio(name: $0, logoURL: nil) })
    }

    private struct Studio: Identifiable {
        let id = UUID()
        let name: String
        let logoURL: URL?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Studios")
                .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
            if !logoStudios.isEmpty {
                FlowLayout(spacing: 16, lineSpacing: 16) {
                    ForEach(logoStudios) { studio in
                        if let url = studio.logoURL {
                            StudioLogoChip(url: url, name: studio.name)
                        }
                    }
                }
            }
            // Studios without a logo always wrap onto their own line(s) below.
            if !textStudios.isEmpty {
                FlowLayout(spacing: 12, lineSpacing: 12) {
                    ForEach(textStudios) { studio in
                        StudioTextChip(name: studio.name)
                    }
                }
            }
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .task(id: studios) { await resolve() }
    }

    private var logoStudios: [Studio] { ordered.filter { $0.logoURL != nil } }
    private var textStudios: [Studio] { ordered.filter { $0.logoURL == nil } }

    private func resolve() async {
        guard !didResolve else { return }
        let names = studios
        let logos = await withTaskGroup(of: (Int, URL?).self) { group -> [Int: URL?] in
            for (index, name) in names.enumerated() {
                group.addTask {
                    (index, await TMDbArtworkResolver.shared.companyLogoURL(name: name))
                }
            }
            var result: [Int: URL?] = [:]
            for await (index, url) in group { result[index] = url }
            return result
        }

        let resolved = names.enumerated().map { index, name in
            Studio(name: name, logoURL: logos[index] ?? nil)
        }
        // Studios with a logo come first (in original order), then text-only.
        ordered = resolved.filter { $0.logoURL != nil } + resolved.filter { $0.logoURL == nil }
        didResolve = true
    }
}

/// A studio rendered as its TMDb logo on a tile. The tile keeps a fixed height
/// and adapts its width to the logo's aspect ratio (square logos get a near-
/// square tile, wide wordmarks get a wide tile) so every tile reads as the same
/// "size". The background (light or dark) is chosen so the logo stays legible:
/// transparent logos get a tile that contrasts their ink, while logos that ship
/// their own opaque background get a tile that blends with it. Falls back to a
/// text tile if the image can't load.
#if canImport(UIKit)
private struct StudioLogoChip: View {
    let url: URL
    let name: String

    /// Fixed tile height; width is derived from the logo's aspect ratio and
    /// clamped to this range so nothing gets too narrow or runs off the row.
    private let tileHeight: CGFloat = 135
    private let minWidth: CGFloat = 113
    private let maxWidth: CGFloat = 345
    private let corner: CGFloat = 17
    private let inset: CGFloat = 20

    @State private var image: UIImage?
    @State private var tileIsDark = false
    @State private var tileWidth: CGFloat = 180
    @State private var failed = false
    @State private var resolved = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(inset)
                    .frame(width: tileWidth, height: tileHeight)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(tileIsDark ? Color(white: 0.10) : Color(white: 0.96))
                    )
            } else if failed {
                StudioTextTile(name: name, width: tileWidth, height: tileHeight, corner: corner)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: tileWidth, height: tileHeight)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard !resolved else { return }
        guard
            let (data, response) = try? await ArtworkSession.shared.data(from: url),
            (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
            // Studio tiles are ~180×135pt; a 400px thumbnail is crisp yet a
            // fraction of a full-size company logo's bitmap. Falls back to a full
            // decode only if the thumbnail path fails, so a logo never vanishes.
            let loaded = ArtworkImageCache.downsample(data, maxPixelSize: 400) ?? UIImage(data: data)
        else {
            failed = true
            resolved = true
            return
        }
        tileIsDark = Self.prefersDarkTile(for: loaded)
        tileWidth = tileWidthForAspect(of: loaded)
        image = loaded
        resolved = true
    }

    /// Derives the tile width from the logo's aspect ratio, keeping the inner
    /// content area at the fixed tile height so all tiles share one height and
    /// only differ in width.
    private func tileWidthForAspect(of image: UIImage) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 180 }
        let contentHeight = tileHeight - inset * 2
        let contentWidth = contentHeight * (size.width / size.height)
        return min(maxWidth, max(minWidth, contentWidth + inset * 2))
    }

    /// Decides whether the tile behind a logo should be dark or light.
    ///
    /// Distinguishes two cases by how much of the image is transparent:
    /// - **Opaque/baked-in background** (essentially *no* transparency — a solid
    ///   card, e.g. dark text on a white rectangle): sample the corners (the
    ///   background) and match the tile to them so the logo blends in instead of
    ///   showing as a "box within a box".
    /// - **Transparent logo** (any meaningful transparency — the common case,
    ///   including logos whose ink reaches the image edges like 20th Century
    ///   Fox): pick the tile that *contrasts* the logo's own "ink" so a white
    ///   logo gets a dark tile and a black logo a light one. Corner sampling is
    ///   deliberately *not* used here, because a transparent logo's corners are
    ///   often its own ink, not a background.
    private static func prefersDarkTile(for image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let size = 28
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        func luminance(at i: Int, alpha: Double) -> Double {
            let r = Double(pixels[i]) / 255.0 / alpha
            let g = Double(pixels[i + 1]) / 255.0 / alpha
            let b = Double(pixels[i + 2]) / 255.0 / alpha
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        let lastIndex = size - 1
        var transparentCount = 0.0
        var inkLumSum = 0.0, inkAlphaSum = 0.0
        var cornerLumSum = 0.0, cornerWeight = 0.0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let alpha = Double(pixels[i + 3]) / 255.0
                if alpha < 0.05 { transparentCount += 1 }
                if alpha > 0.05 {
                    inkLumSum += luminance(at: i, alpha: alpha) * alpha
                    inkAlphaSum += alpha
                }
                let isCorner = (x == 0 || x == lastIndex) && (y == 0 || y == lastIndex)
                if isCorner, alpha > 0.05 {
                    cornerLumSum += luminance(at: i, alpha: alpha) * alpha
                    cornerWeight += alpha
                }
            }
        }

        let transparentFraction = transparentCount / Double(size * size)
        // Essentially fully opaque ⇒ the logo is a solid card carrying its own
        // background; blend the tile with that background's corner shade.
        if transparentFraction < 0.02, cornerWeight > 0 {
            return (cornerLumSum / cornerWeight) < 0.5
        }
        // Transparent logo ⇒ contrast against the ink.
        let inkLuminance = inkAlphaSum > 0 ? inkLumSum / inkAlphaSum : 0
        return inkLuminance > 0.5
    }
}
#else
private struct StudioLogoChip: View {
    let url: URL
    let name: String

    private let tileHeight: CGFloat = 135
    private let corner: CGFloat = 17

    var body: some View {
        AsyncImage(url: url) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFit().padding(20)
            } else {
                Color.clear
            }
        }
        .frame(width: 180, height: tileHeight)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(white: 0.96))
        )
    }
}
#endif

/// A studio with no usable logo, shown as a tile with its name — keeps a
/// failed logo load visually consistent with the logo tiles.
private struct StudioTextTile: View {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let corner: CGFloat

    var body: some View {
        Text(name)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .padding(18)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            )
    }
}

/// A studio rendered as a plain text pill (used when no logo is available).
private struct StudioTextChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 18)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
    }
}

/// A minimal flow (wrapping) layout so chips wrap onto new lines instead of
/// overflowing the screen width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 12

    /// Finite width to wrap at when the layout is proposed an unbounded width
    /// (which can otherwise make `sizeThatFits` return the summed width of *every*
    /// chip on a single row — hundreds of tags then blow the page far past the
    /// viewport and shove the whole detail page sideways).
    private static var fallbackWidth: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return 1920
        #endif
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let proposed = proposal.width
        let maxWidth: CGFloat = (proposed != nil && proposed!.isFinite && proposed! > 0) ? proposed! : Self.fallbackWidth
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(CGFloat(0)) { acc, row in
            let rowHeight = row.map(\.height).max() ?? 0
            return acc + rowHeight + lineSpacing
        } - (rows.isEmpty ? 0 : lineSpacing)
        return CGSize(width: maxWidth, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#endif
