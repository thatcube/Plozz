import CoreModels
import CoreUI
import SwiftUI

/// Settings → *profile* → **Profile Lock** on iPhone/iPad.
///
/// Same three states as the Apple TV page (no lock / choosing a PIN / lock set)
/// and the same shared copy, so the feature reads identically wherever you meet
/// it. The raw PIN is turned into a salted `ProfileLock` verifier here and never
/// leaves this view.
struct PlozziOSProfileLockSettingsView: View {
    let appModel: PlozziOSAppModel

    @State private var entry: String = ""
    @State private var firstEntry: String?
    @State private var isCreating = false
    @State private var isConfirming = false
    @State private var errorMessage: LocalizedStringResource?
    @State private var reusePlexPIN = false
    @State private var confirmDelete = false

    private var profile: Profile { appModel.profiles.activeProfile }
    private var isLocked: Bool { profile.isLocked }
    private var syncEnabled: Bool { SyncSetupFeatureFlag().isEnabled }

    /// Only offer to reuse the Plex PIN when this profile actually plays as a
    /// Plex Home user that asks for one.
    private var boundToProtectedPlexUser: Bool {
        if profile.plexHomeUserRequiresPIN == true { return true }
        return profile.plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

    var body: some View {
        List {
            if isCreating || isConfirming {
                entrySection
            } else {
                summarySection
            }
        }
        .navigationTitle(Text(ProfileLockCopy.title))
        .navigationBarTitleDisplayMode(.inline)
        .alert(Text(ProfileLockCopy.delete), isPresented: $confirmDelete) {
            Button(String(localized: ProfileLockCopy.delete), role: .destructive) {
                appModel.setLockForActiveProfile(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProfileLockCopy.forgotPINDetail)
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summarySection: some View {
        SettingsSectionGroup {
            HStack {
                Label {
                    Text(isLocked ? ProfileLockCopy.on : ProfileLockCopy.off)
                } icon: {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open")
                }
                Spacer()
            }
            Button {
                begin()
            } label: {
                Text(isLocked ? ProfileLockCopy.editPIN : ProfileLockCopy.create)
            }
            if isLocked {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text(ProfileLockCopy.delete)
                }
            }
        } footer: {
            if syncEnabled {
                Text(ProfileLockCopy.explanation)
            } else {
                Text(ProfileLockCopy.explanation) + Text(verbatim: "\n\n") + Text(ProfileLockCopy.lockIsDeviceOnly)
            }
        }
    }

    // MARK: Entry

    @ViewBuilder
    private var entrySection: some View {
        SettingsSectionGroup {
            VStack(spacing: 20) {
                Text(isConfirming ? ProfileLockCopy.confirm : ProfileLockCopy.enterToCreate)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                PINBoxes(filledCount: entry.count)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                PINStrip(onDigit: appendDigit, onDelete: deleteDigit)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            if !isConfirming, boundToProtectedPlexUser {
                Toggle(isOn: $reusePlexPIN) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ProfileLockCopy.usePlexPIN)
                        Text(ProfileLockCopy.usePlexPINDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Cancel", role: .cancel) { reset() }
        }
    }

    // MARK: Actions

    private func begin() {
        entry = ""
        firstEntry = nil
        errorMessage = nil
        isConfirming = false
        isCreating = true
    }

    private func reset() {
        entry = ""
        firstEntry = nil
        errorMessage = nil
        isCreating = false
        isConfirming = false
    }

    private func appendDigit(_ d: String) {
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard entry.count < ProfileLock.pinLength else { return }
        entry.append(d)
        guard entry.count == ProfileLock.pinLength else { return }

        if !isConfirming {
            firstEntry = entry
            entry = ""
            errorMessage = nil
            isConfirming = true
            return
        }

        let confirmation = entry
        entry = ""
        guard let first = firstEntry, first == confirmation,
              let lock = ProfileLock.make(pin: first, matchesPlexPIN: reusePlexPIN) else {
            // Start over rather than letting them retry just the confirmation: if
            // the two didn't match we don't know which one they meant.
            errorMessage = ProfileLockCopy.mismatch
            firstEntry = nil
            isConfirming = false
            return
        }
        appModel.setLockForActiveProfile(lock)
        reset()
    }

    private func deleteDigit() {
        if !entry.isEmpty { entry.removeLast() }
    }
}
