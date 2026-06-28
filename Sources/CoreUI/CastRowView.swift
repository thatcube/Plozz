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

    public init(
        title: String = "Cast",
        people: [MediaPerson],
        leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding
    ) {
        self.title = title
        self.people = people
        self.leadingInset = leadingInset
    }

    public var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: PlozzTheme.Metrics.sectionTitleSpacing) {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .padding(.leading, leadingInset)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: PlozzTheme.Metrics.cardSpacing) {
                        ForEach(people) { person in
                            CastMemberCard(person: person)
                        }
                    }
                    .padding(.leading, leadingInset)
                    .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                    .padding(.top, PlozzTheme.Spacing.small)
                    .padding(.bottom, PlozzTheme.Spacing.large)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// A single cast member: a circular avatar that lifts on focus, with the
/// person's name and role beneath.
private struct CastMemberCard: View {
    let person: MediaPerson

    @FocusState private var isFocused: Bool

    private static let avatarSize: CGFloat = 160

    var body: some View {
        VStack(spacing: 12) {
            avatar
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(
                        isFocused ? Color.white : Color.white.opacity(0.12),
                        lineWidth: isFocused ? 4 : 1
                    )
                )
                .scaleEffect(isFocused ? 1.1 : 1.0)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)

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
            .frame(width: Self.avatarSize + 40)
            .multilineTextAlignment(.center)
        }
        .focusable(true)
        .focused($isFocused)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    @ViewBuilder
    private var avatar: some View {
        if let imageURL = person.imageURL {
            FallbackAsyncImage(urls: [imageURL]) { placeholder }
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
