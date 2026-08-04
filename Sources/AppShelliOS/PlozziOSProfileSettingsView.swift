import CoreModels
import CoreUI
import SwiftUI

/// Settings → Everyone → Profiles → *one profile* on iPhone/iPad.
///
/// The iOS half of the same idea as tvOS: everything true *about* a profile as an
/// entity — appearance, whether it needs a PIN, whether it's restricted, whether
/// it exists — for any profile, not just the active one.
///
/// Managing every profile's lock from one screen is what Netflix does, and it's
/// the only arrangement that works here: a Kids Profile can't reach this section,
/// so a grown-up has to be able to set the child's restrictions (and their own
/// lock) from a profile the child isn't using.
struct PlozziOSProfileSettingsView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let profileID: String

    @State private var showingEditor = false
    @State private var confirmDelete = false

    /// Read live so the page reflects a lock added or the profile renamed.
    private var profile: Profile? {
        appModel.profiles.profiles.first(where: { $0.id == profileID })
    }

    private var canDelete: Bool {
        guard let profile else { return false }
        return !appModel.profiles.isDefault(profile)
    }

    /// Whether any *other* profile carries a lock — a Kids Profile only contains
    /// anyone if there's something locked to keep them out of.
    private var householdHasAnyLock: Bool {
        appModel.profiles.profiles.contains { $0.id != profileID && $0.isLocked }
    }

    var body: some View {
        List {
            if let profile {
                SettingsSectionGroup {
                    Button {
                        showingEditor = true
                    } label: {
                        HStack(spacing: 12) {
                            PlozziOSProfileAvatar(profile: profile, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Appearance")
                                Text("Name, avatar, and colour")
                                    .font(.footnote)
                                    .plozzForeground(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .plozzForeground(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                SettingsSectionGroup {
                    NavigationLink {
                        PlozziOSProfileLockSettingsView(appModel: appModel, profileID: profileID)
                    } label: {
                        HStack {
                            Label(
                                String(localized: ProfileLockCopy.title),
                                systemImage: profile.isLocked ? "lock" : "lock.open"
                            )
                            Spacer()
                            Text(profile.isLocked ? ProfileLockCopy.on : ProfileLockCopy.off)
                                .plozzForeground(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { profile.isKids },
                        set: { appModel.setKidsProfile($0, forProfile: profileID) }
                    )) {
                        Text(KidsProfileCopy.title)
                    }

                    if profile.isKids, !householdHasAnyLock {
                        Label {
                            Text(KidsProfileCopy.pairWithLock)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .plozzForeground(.secondary)
                    }
                } footer: {
                    Text(KidsProfileCopy.explanation)
                }

                if canDelete {
                    SettingsSectionGroup {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(Text(verbatim: profile?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    editingProfile: profile,
                    canDelete: false,
                    onFinished: { showingEditor = false }
                )
            }
            .preferredColorScheme(palette.isLight ? .light : .dark)
        }
        .alert("Delete this profile?", isPresented: $confirmDelete) {
            Button("Delete Profile", role: .destructive) {
                appModel.removeProfile(profileID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes this profile's preferences and which servers it includes. Signed-in server accounts stay shared.")
        }
    }
}
