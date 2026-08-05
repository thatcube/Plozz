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
    /// Supplied when this picker is being used as the switcher rather than the
    /// launch gate. Its presence is what turns on Add and Edit.
    ///
    /// The picker drives those flows through its OWN navigation stack instead of
    /// handing them back to the caller. A second presentation from the same host
    /// as this cover is the arrangement SwiftUI drops silently, and the caller
    /// (the tab shell) already owns the Settings sheet.
    var manager: PlozziOSAppModel?
    /// Closes the picker. `nil` at launch, where there's nothing to go back to.
    var onCancel: (() -> Void)?

    @State private var isEditing = false
    @State private var route: Route?

    /// What the picker has pushed on top of itself.
    private enum Route: Hashable, Identifiable {
        case add(isKids: Bool)
        case edit(profileID: String)
        var id: Self { self }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 24)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 8) {
                        // With a single profile there is nobody to choose
                        // between, so the screen says what it can actually do.
                        Text(isEditing
                            ? "Edit Profiles"
                            : (profiles.count > 1 ? "Who’s watching?" : "Profiles"))
                            .font(.largeTitle.bold())
                        Text(isEditing
                            ? "Choose a profile to change it."
                            : (profiles.count > 1
                                ? "Choose a profile to continue."
                                : "Add a profile, or change the one you have."))
                            .plozzForeground(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(profiles) { profile in
                            Button {
                                if isEditing, manager != nil {
                                    route = .edit(profileID: profile.id)
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
                                if manager != nil {
                                    Button("Edit Profile", systemImage: "pencil") {
                                        route = .edit(profileID: profile.id)
                                    }
                                }
                            }
                        }

                        if manager != nil, !isEditing {
                            Button { route = .add(isKids: false) } label: {
                                addCard(
                                    title: "Add Profile",
                                    systemImage: "plus"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Add Profile"))

                            // Its own tile, matching tvOS. Creating a child's
                            // profile and then remembering to mark it as one is
                            // a step people skip, and the consequence is a
                            // profile that isn't restricted.
                            Button { route = .add(isKids: true) } label: {
                                addCard(
                                    title: KidsProfileCopy.addTile,
                                    systemImage: "figure.and.child.holdinghands"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(KidsProfileCopy.addTile))
                        }
                    }
                    .frame(maxWidth: 760)

                    // Full-size controls under the grid rather than a small
                    // toolbar button: they're as prominent as what they act on.
                    if manager != nil || onCancel != nil {
                        VStack(spacing: 12) {
                            if manager != nil {
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
            .navigationDestination(item: $route) { route in
                destination(for: route)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        if let manager {
            switch route {
            case let .add(isKids):
                PlozziOSProfileEditorHost(
                    appModel: manager,
                    createsKidsProfile: isKids
                ) {
                    self.route = nil
                    // Close the whole picker: a brand-new profile owes its setup
                    // pass, and that cover is presented by the root — which can't
                    // while this one is up.
                    onCancel?()
                }
            case let .edit(profileID):
                PlozziOSProfileSettingsView(appModel: manager, profileID: profileID)
            }
        }
    }

    /// Matches a profile card's shape so the grid stays even.
    private func addCard(
        title: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.quaternary)
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .plozzForeground(.secondary)
            }
            .frame(width: 116, height: 116)

            Text(title)
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
