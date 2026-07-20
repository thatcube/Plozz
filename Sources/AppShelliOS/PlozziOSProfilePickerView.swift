#if os(iOS)
import CoreModels
import Foundation
import SwiftUI

struct PlozziOSProfilePickerView: View {
    let profiles: [Profile]
    let activeProfileID: String
    let onSelect: (Profile) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 24)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 8) {
                        Text("Who’s watching?")
                            .font(.largeTitle.bold())
                        Text("Choose a profile to continue.")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(profiles) { profile in
                            Button {
                                onSelect(profile)
                            } label: {
                                profileCard(profile)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.name)
                            .accessibilityHint("Switches to this profile")
                        }
                    }
                    .frame(maxWidth: 760)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
            }
            .background(.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func profileCard(_ profile: Profile) -> some View {
        VStack(spacing: 14) {
            profileAvatar(profile)
                .frame(width: 116, height: 116)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(
                            profile.id == activeProfileID
                                ? Color.accentColor
                                : Color.clear,
                            lineWidth: 4
                        )
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            Text(profile.name)
                .font(.headline)
                .lineLimit(1)

            if profile.id == activeProfileID {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func profileAvatar(_ profile: Profile) -> some View {
        if let rawURL = profile.avatarImageURL,
           let url = URL(string: rawURL) {
            AsyncImage(url: url) { phase in
                if case let .success(image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    fallbackAvatar(profile)
                }
            }
        } else {
            fallbackAvatar(profile)
        }
    }

    private func fallbackAvatar(_ profile: Profile) -> some View {
        ZStack {
            Color.accentColor.opacity(0.16)
            if let emoji = profile.avatarEmoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 54))
            } else {
                Image(systemName: profile.avatarSymbol)
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
    }
}
#endif
