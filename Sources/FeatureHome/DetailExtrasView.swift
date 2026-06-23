#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

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

/// A studio rendered as its TMDb logo on a light pill, sized to align with the
/// text chips. Falls back to a text chip if the logo image fails to load.
private struct StudioLogoChip: View {
    let url: URL
    let name: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(height: 28)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 18)
                    .background(Capsule().fill(Color.white))
            case .failure:
                StudioTextChip(name: name)
            default:
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 120, height: 44)
            }
        }
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
