#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontal row of capability badges (`TV-14`, `4K`, `Dolby Vision`,
/// `Dolby Atmos`, `5.1`, …) for the detail hero. Renders nothing when empty.
public struct MediaBadgeRow: View {
    private let badges: [MediaBadge]

    public init(badges: [MediaBadge]) {
        self.badges = badges
    }

    public var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 10) {
                ForEach(badges) { badge in
                    MediaBadgeChip(badge: badge)
                }
            }
        }
    }
}

/// A single capability badge rendered as a rounded pill. `.outlined` badges use
/// a hairline border over a faint fill; `.prominent` badges (premium formats)
/// use a brighter translucent fill so they stand out, matching the dense
/// "4K · Dolby Vision · Dolby Atmos" cluster on the Apple TV detail page.
public struct MediaBadgeChip: View {
    private let badge: MediaBadge

    public init(badge: MediaBadge) {
        self.badge = badge
    }

    public var body: some View {
        Text(badge.label)
            .font(.caption)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
            .accessibilityLabel(badge.label)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch badge.style {
        case .outlined:
            shape.fill(Color.primary.opacity(0.08))
        case .prominent:
            shape.fill(Color.primary.opacity(0.20))
        }
    }

    private var borderColor: Color {
        switch badge.style {
        case .outlined: return Color.primary.opacity(0.35)
        case .prominent: return Color.primary.opacity(0.65)
        }
    }
}

#endif
