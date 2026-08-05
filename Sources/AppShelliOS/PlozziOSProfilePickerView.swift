#if os(iOS)
import CoreModels
import FeatureProfiles
import Foundation
import SwiftUI
import CoreUI

/// "Who's watching?" — the one screen for choosing a profile, and for changing
/// or adding one.
///
/// Used both at launch and as the switcher reached from Settings, so switching
/// looks the same wherever you start. That mirrors the tvOS picker, which has
/// always carried Add and Edit alongside the tiles.
///
/// Editing has two ways in, because touch has no focused-tile affordance to hang
/// an Edit button on: **long-press a profile**, or turn on **Edit Profiles** and
/// tap. The first is fast, the second is findable.
struct PlozziOSProfilePickerView: View {
    let profiles: [Profile]
    let activeProfileID: String
    let onSelect: (Profile) -> Void
    /// Adds a profile. Omitted at launch, where the roster isn't the point.
    var onAddProfile: (() -> Void)?
    /// Opens a profile's settings. Omitted at launch.
    var onEditProfile: ((Profile) -> Void)?
    /// Closes the picker. `nil` at launch, where there's nothing to go back to.
    var onCancel: (() -> Void)?

    @State private var isEditing = false

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 24)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 8) {
                        Text(isEditing ? "Edit Profiles" : "Who’s watching?")
                            .font(.largeTitle.bold())
                        Text(isEditing
                            ? "Choose a profile to change it."
                            : "Choose a profile to continue.")
                            .plozzForeground(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(profiles) { profile in
                            Button {
                                if isEditing, let onEditProfile {
                                    onEditProfile(profile)
                                } else {
                                    onSelect(profile)
                                }
                            } label: {
                                profileCard(profile)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.name)
                            .accessibilityHint(isEditing
                                ? "Opens this profile’s settings"
                                : "Switches to this profile")
                            .contextMenu {
                                if let onEditProfile {
                                    Button("Edit Profile", systemImage: "pencil") {
                                        onEditProfile(profile)
                                    }
                                }
                            }
                        }

                        if let onAddProfile, !isEditing {
                            Button(action: onAddProfile) {
                                addCard
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Add Profile"))
                        }
                    }
                    .frame(maxWidth: 760)

                    // Full-size controls under the grid rather than a small
                    // toolbar button: they're as prominent as what they act on.
                    if onEditProfile != nil || onCancel != nil {
                        VStack(spacing: 12) {
                            if onEditProfile != nil {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                                } label: {
                                    Label(
                                        isEditing ? "Done" : "Edit Profiles",
                                        systemImage: isEditing ? "checkmark.circle" : "pencil"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                            if let onCancel, !isEditing {
                                Button("Cancel", action: onCancel)
                                    .buttonStyle(.plain)
                                    .plozzForeground(.secondary)
                            }
                        }
                        .frame(maxWidth: 360)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
            }
            .background(.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Matches a profile card's shape so the grid stays even.
    private var addCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.quaternary)
                Image(systemName: "plus")
                    .font(.system(size: 40, weight: .semibold))
                    .plozzForeground(.secondary)
            }
            .frame(width: 116, height: 116)

            Text("Add Profile")
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func profileCard(_ profile: Profile) -> some View {
        VStack(spacing: 14) {
            // Shared avatar renderer so the picker matches every other avatar
            // surface (Settings list, editor preview): symbol / emoji on the
            // profile's CHOSEN colour, or a borrowed photo. The old local
            // `fallbackAvatar` painted a flat accent tint and ignored the
            // profile's colour entirely.
            ProfileAvatarView(profile: profile, size: 116)
                .frame(width: 116, height: 116)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            Text(profile.name)
                .font(.headline)
                .lineLimit(1)

        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
#endif
