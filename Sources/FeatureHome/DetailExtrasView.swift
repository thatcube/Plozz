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

    private var hasContent: Bool {
        !item.cast.isEmpty || !item.studios.isEmpty || !item.tags.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 28) {
                if !item.cast.isEmpty {
                    CastRowView(people: item.cast)
                }
                if !item.studios.isEmpty {
                    StudiosRow(studios: item.studios)
                }
                if !item.tags.isEmpty {
                    InfoChipsRow(title: "Tags", values: item.tags)
                }
            }
        }
    }
}

/// A labelled, wrapping strip of pill chips (e.g. studios or tags).
private struct InfoChipsRow: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
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
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Studios")
                .font(.system(size: 32, weight: .bold))
            FlowLayout(spacing: 12, lineSpacing: 12) {
                ForEach(ordered) { studio in
                    if let url = studio.logoURL {
                        StudioLogoChip(url: url, name: studio.name)
                    } else {
                        StudioTextChip(name: studio.name)
                    }
                }
            }
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .task(id: studios) { await resolve() }
    }

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

/// A studio rendered as its TMDb logo on a large, squared tile whose background
/// (light or dark) is chosen to contrast the logo's own brightness, so logos of
/// any colour stay legible. Falls back to a text tile if the image can't load.
#if canImport(UIKit)
private struct StudioLogoChip: View {
    let url: URL
    let name: String

    /// Side of the square tile and its inner padding / corner radius.
    private let side: CGFloat = 180
    private let corner: CGFloat = 20
    private let inset: CGFloat = 26

    @State private var image: UIImage?
    @State private var tileIsDark = false
    @State private var failed = false
    @State private var resolved = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(inset)
                    .frame(width: side, height: side)
                    .background(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(tileIsDark ? Color(white: 0.10) : Color(white: 0.96))
                    )
            } else if failed {
                StudioTextTile(name: name, side: side, corner: corner)
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: side, height: side)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard !resolved else { return }
        guard
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
            let loaded = UIImage(data: data)
        else {
            failed = true
            resolved = true
            return
        }
        // A predominantly light logo wants a dark tile, and vice-versa.
        tileIsDark = Self.averageLuminance(of: loaded) > 0.5
        image = loaded
        resolved = true
    }

    /// Alpha-weighted average luminance of the logo's opaque pixels (0 = black,
    /// 1 = white), computed from a tiny downsample. Transparent areas are
    /// ignored so the result reflects the "ink", not the background.
    private static func averageLuminance(of image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = 24, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminanceSum = 0.0
        var alphaSum = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255.0
            guard alpha > 0.05 else { continue }
            // Premultiplied: un-multiply by alpha to recover the true colour.
            let r = Double(pixels[index]) / 255.0 / alpha
            let g = Double(pixels[index + 1]) / 255.0 / alpha
            let b = Double(pixels[index + 2]) / 255.0 / alpha
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminanceSum += luminance * alpha
            alphaSum += alpha
        }
        return alphaSum > 0 ? luminanceSum / alphaSum : 0
    }
}
#else
private struct StudioLogoChip: View {
    let url: URL
    let name: String

    private let side: CGFloat = 180
    private let corner: CGFloat = 20

    var body: some View {
        AsyncImage(url: url) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFit().padding(26)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(white: 0.96))
        )
    }
}
#endif

/// A studio with no usable logo, shown as a squared tile with its name — keeps
/// the row visually consistent with the logo tiles.
private struct StudioTextTile: View {
    let name: String
    let side: CGFloat
    let corner: CGFloat

    var body: some View {
        Text(name)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .padding(18)
            .frame(width: side, height: side)
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
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
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: max(0, height))
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
