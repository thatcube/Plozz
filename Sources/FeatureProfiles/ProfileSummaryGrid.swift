#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// A set of profiles shown as avatars with names, wrapping onto as many rows as
/// it takes.
///
/// Both shells drew this as a plain `HStack`, which silently clips once there
/// are more profiles than fit — and clips at BOTH ends, because an overflowing
/// `HStack` centres itself, so the household's first and last profiles simply
/// aren't there. Nothing indicates anything is missing.
///
/// Wrapping rather than scrolling horizontally: these appear on summary screens
/// ("here's what was set up"), where the point is to confirm at a glance that
/// everything came across. A scroll view would hide exactly the thing the screen
/// exists to show, and there's nothing on a static summary to suggest scrolling.
///
/// Shared because the layout is the only part that was wrong, and it was wrong
/// identically in both places. Sizes differ per platform — a tvOS avatar is seen
/// from across a room — so those are parameters, not copies.
public struct ProfileSummaryGrid: View {
    private let profiles: [Profile]
    private let avatarSize: CGFloat
    private let itemWidth: CGFloat
    private let spacing: CGFloat
    private let nameFont: Font

    public init(
        profiles: [Profile],
        avatarSize: CGFloat,
        itemWidth: CGFloat,
        spacing: CGFloat,
        nameFont: Font
    ) {
        self.profiles = profiles
        self.avatarSize = avatarSize
        self.itemWidth = itemWidth
        self.spacing = spacing
        self.nameFont = nameFont
    }

    public var body: some View {
        LazyVGrid(
            // Fixed-width columns rather than flexible ones: the tiles are
            // avatars, so stretching them to fill a row would leave a household
            // with three profiles showing three very spread-out names.
            columns: [GridItem(.adaptive(minimum: itemWidth, maximum: itemWidth), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            ForEach(profiles, id: \.id) { profile in
                VStack(spacing: avatarSize * 0.11) {
                    ProfileAvatarView(profile: profile, size: avatarSize)
                    Text(profile.name)
                        .font(nameFont)
                        .lineLimit(1)
                        // A long name shrinks a little before it truncates: these
                        // are names people chose, and "Christopher" reading as
                        // "Christo…" next to a picture of them is a poor trade
                        // for a couple of points of width.
                        .minimumScaleFactor(0.8)
                }
                .frame(width: itemWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
