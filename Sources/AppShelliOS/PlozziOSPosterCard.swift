#if os(iOS)
import CoreModels
import SwiftUI

struct PlozziOSPosterCard: View {
    let item: MediaItem?
    let cardStyle: CardStyle
    let watchIndicator: WatchStatusIndicator

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            poster

            Text(item?.title ?? "Loading…")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .redacted(reason: item == nil ? .placeholder : [])
        }
        .padding(cardStyle == .framed ? 8 : 0)
        .background {
            if cardStyle == .framed {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.thinMaterial)
            }
        }
    }

    private var poster: some View {
        AsyncImage(url: item?.posterURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.secondary.opacity(0.14))
                .overlay {
                    if item == nil {
                        ProgressView()
                    } else {
                        Image(systemName: item?.kind == .series ? "tv" : "film")
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            watchBadge
                .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardStyle == .framed ? 10 : 12))
    }

    @ViewBuilder
    private var watchBadge: some View {
        if let item {
            switch watchIndicator {
            case .watched where item.isPlayed:
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(.black.opacity(0.35), in: Circle())
            case .unwatched where !item.isPlayed:
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.blue, in: Circle())
            default:
                EmptyView()
            }
        }
    }
}

extension UIDensity {
    var iOSPosterMinimumWidth: CGFloat {
        max(86, CGFloat(116 * scale))
    }
}
#endif
