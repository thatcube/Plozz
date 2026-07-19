#if os(iOS)
import CoreModels
import SwiftUI

struct PlozziOSPosterCard: View {
    @Environment(PlozziOSAppModel.self) private var appModel

    let item: MediaItem?
    let cardStyle: CardStyle
    let watchIndicator: WatchStatusIndicator

    var body: some View {
        if let item, !actions(for: item).isEmpty {
            content.contextMenu {
                ForEach(actions(for: item)) { action in
                    Button(
                        action.title,
                        systemImage: action.systemImage,
                        role: action.isDestructive ? .destructive : nil
                    ) {
                        appModel.mediaItemActionHandler.perform(
                            action,
                            on: item,
                            context: .none
                        )
                    }
                }
            }
        } else {
            content
        }
    }

    private var content: some View {
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

    private func actions(for item: MediaItem) -> [MediaItemAction] {
        appModel.mediaItemActionHandler.actions(for: item, context: .none)
            .filter { !$0.isNavigation }
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

    func iOSPosterGridColumns(
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> [GridItem] {
        let minimumWidth = if horizontalSizeClass == .regular {
            max(108, CGFloat(144 * scale))
        } else {
            iOSPosterMinimumWidth
        }
        let spacing: CGFloat = horizontalSizeClass == .regular ? 16 : 12
        return [
            GridItem(
                .adaptive(
                    minimum: minimumWidth,
                    maximum: minimumWidth * 1.55
                ),
                spacing: spacing
            )
        ]
    }

    func iOSHomePosterWidth(
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        max(96, CGFloat((horizontalSizeClass == .regular ? 170 : 140) * scale))
    }

    func iOSHomeLandscapeWidth(
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        max(180, CGFloat((horizontalSizeClass == .regular ? 300 : 250) * scale))
    }

    func iOSHomeLibraryWidth(
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        max(164, CGFloat((horizontalSizeClass == .regular ? 260 : 220) * scale))
    }
}
#endif
