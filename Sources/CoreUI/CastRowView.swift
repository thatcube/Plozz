#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontally-scrolling, focusable row of cast/crew members, each shown as a
/// circular headshot with their name and (for actors) the character they play.
/// For anime this surfaces the voice cast — exactly the metadata the web client
/// shows but that Plozz previously dropped.
public struct CastRowView: View {
    private let title: String
    private let people: [MediaPerson]
    /// Leading inset for the title and first headshot. Detail pages pass the
    /// hero leading padding so the cast row aligns with the hero text above.
    private let leadingInset: CGFloat
    private let onFocusEntered: (() -> Void)?

    @Environment(\.plozzMetrics) private var metrics

    public init(
        title: String = "Cast",
        people: [MediaPerson],
        leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding,
        onFocusEntered: (() -> Void)? = nil
    ) {
        self.title = title
        self.people = people
        self.leadingInset = leadingInset
        self.onFocusEntered = onFocusEntered
    }

    public var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                        .padding(.leading, leadingInset)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: metrics.cardSpacing) {
                        ForEach(people) { person in
                            CastMemberCard(person: person, onFocusEntered: onFocusEntered)
                        }
                    }
                    .padding(.leading, leadingInset)
                    .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                    // Keep the rail clipping (no `scrollClipDisabled`) so the focus
                    // engine holds the first/last card at its inset, and reserve room
                    // *inside* the clip for the focused card's lift + shadow. The
                    // negative outer padding restores the original 12/24 insets, so
                    // the row's height is unchanged — only the clip grows.
                    .padding(.vertical, metrics.railShadowClearance)
                }
                .padding(.top, metrics.railClearanceOffset(for: PlozzTheme.Spacing.small))
                .padding(.bottom, metrics.railClearanceOffset(for: PlozzTheme.Spacing.large))
            }
        }
    }
}

/// A single cast member: a circular avatar that lifts on focus with the shared
/// circular glass halo, and the person's name and role beneath. A deliberately
/// smaller, density-aware variant of the artist/profile circular style.
private struct CastMemberCard: View {
    let person: MediaPerson
    let onFocusEntered: (() -> Void)?

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        let diameter = metrics.castTileDiameter
        let slot = diameter + metrics.circleFocusPadding * 2
        CircularFocusTile(
            diameter: diameter,
            focusPadding: metrics.circleFocusPadding,
            action: {},
            onFocusChange: { focused in
                if focused { onFocusEntered?() }
            },
            avatar: { avatar },
            caption: { _ in
                VStack(spacing: 2) {
                    Text(person.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let role = person.role {
                        Text(role)
                            .font(.system(size: 19))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: slot)
                .multilineTextAlignment(.center)
            }
        )
    }

    @ViewBuilder
    private var avatar: some View {
        if let imageURL = person.imageURL {
            FallbackAsyncImage(urls: [imageURL], variant: .personHeadshot) { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.12))
            Text(initials)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }
}

#endif
