#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Choosing a different profile from inside Settings on iPhone/iPad.
///
/// Always reachable, **including from a Kids Profile**. The Profiles row lives in
/// the household group, which a Kids Profile hides — so a child's profile had no
/// route to switching at all and was a dead end on iOS. Hiding the exit was never
/// the protection anyway: `ProfilesModel.requiresParentalPIN(switchingFrom:to:)`
/// is, and it still applies to every selection made here.
///
/// Closes Settings before switching. The Parental PIN and profile-lock gates are
/// presented from the root, and asking for a cover from underneath an open sheet
/// is the arrangement that fails silently.
struct PlozziOSSwitchProfileView: View {
    let appModel: PlozziOSAppModel
    let onClose: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        List {
            SettingsSectionGroup {
                ForEach(appModel.profiles.profilesByRecency) { profile in
                    Button {
                        guard profile.id != appModel.profiles.activeProfileID else {
                            onClose()
                            return
                        }
                        onClose()
                        appModel.selectProfile(profile.id)
                    } label: {
                        HStack(spacing: 12) {
                            PlozziOSProfileAvatar(profile: profile, size: 34)
                            Text(verbatim: profile.name)
                            if profile.isKids {
                                Image(systemName: "figure.and.child.holdinghands")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                            Spacer()
                            if profile.id == appModel.profiles.activeProfileID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(palette.accent)
                            } else if profile.isLocked {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(Text("Switch Profile"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
