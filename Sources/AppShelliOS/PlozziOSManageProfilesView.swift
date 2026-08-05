#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The list of profiles as things to *change*, rather than things to switch to.
///
/// A separate page instead of a mode on the picker. Editing and switching are
/// different intents that happened to want the same rows, and every attempt to
/// serve both from one list made the common case (switching) worse: first an ⓘ
/// on every row, then a Manage toggle that had to live in a footnote-sized
/// uppercase header. Splitting them lets each list mean exactly one thing.
struct PlozziOSManageProfilesView: View {
    let appModel: PlozziOSAppModel

    @Environment(\.themePalette) private var palette
    /// One optional route owned by this page. A row cannot activate another
    /// row's destination, and there is no per-row NavigationLink state for
    /// SwiftUI's split-view reconciliation to accidentally stack.
    @State private var selectedProfileRoute: PlozziOSProfileSettingsRoute?

    var body: some View {
        List {
            SettingsSectionGroup {
                ForEach(appModel.profiles.profilesByRecency) { profile in
                    Button {
                        selectedProfileRoute = PlozziOSProfileSettingsRoute(
                            profileID: profile.id
                        )
                    } label: {
                        HStack(spacing: 12) {
                            PlozziOSProfileAvatar(profile: profile, size: 34)
                            Text(verbatim: profile.name)
                            Spacer()
                            // Glance the access state so the list answers
                            // "who's locked?" without opening each one.
                            if profile.isKids {
                                Image(systemName: "figure.and.child.holdinghands")
                                    .plozzForeground(.secondary)
                            }
                            if profile.isLocked {
                                Image(systemName: "lock.fill")
                                    .plozzForeground(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .plozzForeground(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if !appModel.profiles.isDefault(profile) {
                            Button("Delete", role: .destructive) {
                                appModel.removeProfile(profile.id)
                            }
                        }
                    }
                }
            } footer: {
                Text("Choose a profile to change its libraries, lock, and appearance.")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Manage Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedProfileRoute) { route in
            PlozziOSProfileSettingsView(
                appModel: appModel,
                profileID: route.profileID
            )
        }
    }
}
#endif
