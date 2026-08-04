#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

/// Settings → Everyone → Profiles → *name* → **Profile Lock**.
///
/// A summary page only: whether the profile is locked, and the actions. Choosing
/// the PIN itself is `ProfileLockSetupView` presented full-screen, which the
/// picker's post-create step uses too — so there is exactly one implementation of
/// "type it, type it again" and the two can't drift.
struct ProfileLockDetailView: View {
    let context: SettingsContext
    /// The profile being locked — not necessarily the active one. Locks are
    /// managed for the whole household from Everyone › Profiles, so a grown-up
    /// can lock their own profile without switching into it first.
    let profileID: String
    /// Whether these settings currently reach the user's other devices, so the
    /// page can be honest that a lock set with Sync off is device-only.
    let syncEnabled: Bool

    @State private var settingPIN = false

    /// Read live from the context so the page updates as the lock is set/cleared.
    private var profile: Profile {
        context.profiles.first(where: { $0.id == profileID }) ?? context.activeProfile
    }

    private var isLocked: Bool { profile.isLocked }

    /// Whether this profile plays as a Plex Home user that already asks for a
    /// PIN — the only case where offering to reuse it makes sense.
    private var boundToProtectedPlexUser: Bool {
        if profile.plexHomeUserRequiresPIN == true { return true }
        return profile.plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

    var body: some View {
        SettingsSplitLayout(title: ProfileLockCopy.title, sections: [summarySection])
            .fullScreenCover(isPresented: $settingPIN) {
                ProfileLockSetupView(
                    profile: profile,
                    offersPlexPINReuse: boundToProtectedPlexUser,
                    syncEnabled: syncEnabled,
                    onComplete: { lock in
                        context.onSetProfileLock(profileID, lock)
                        settingPIN = false
                    },
                    onCancel: { settingPIN = false }
                )
            }
    }

    private var summarySection: SettingsSplitSection {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "state",
                title: isLocked ? ProfileLockCopy.on : ProfileLockCopy.off,
                description: ProfileLockCopy.explanation
            ) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 28))
                    .plozzForeground(isLocked ? .primary : .secondary)
            }
        ]

        if !syncEnabled {
            rows.append(
                SettingsSplitRow(id: "device-only", title: ProfileLockCopy.lockIsDeviceOnly) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.yellow)
                }
            )
        }

        rows.append(
            SettingsSplitRow(id: "primary", title: isLocked ? ProfileLockCopy.editPIN : ProfileLockCopy.create) {
                Button(isLocked ? ProfileLockCopy.editPIN : ProfileLockCopy.create) {
                    settingPIN = true
                }
            }
        )

        if isLocked {
            rows.append(
                SettingsSplitRow(
                    id: "delete",
                    title: ProfileLockCopy.delete,
                    description: ProfileLockCopy.forgotPINDetail
                ) {
                    Button(ProfileLockCopy.delete, role: .destructive) {
                        context.onSetProfileLock(profileID, nil)
                    }
                }
            )
        }

        return SettingsSplitSection(id: "profile-lock", header: ProfileLockCopy.title, rows: rows)
    }
}
#endif
