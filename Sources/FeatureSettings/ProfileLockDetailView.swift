#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Settings → *profile* → **Profile Lock**.
///
/// Creates, changes and removes the active profile's PIN gate. Three states in
/// one page (no lock / choosing a new PIN / lock set) rather than a stack of
/// sheets, because the whole interaction is eight key presses and a tvOS remote
/// makes every extra layer expensive.
///
/// The raw PIN never leaves this view: it's turned into a salted `ProfileLock`
/// verifier here and only that is handed back up.
struct ProfileLockDetailView: View {
    let context: SettingsContext
    /// Whether these settings currently reach the user's other devices, so the
    /// page can be honest that a lock set with Sync off is device-only.
    let syncEnabled: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    /// Digits typed so far in whichever entry step is active.
    @State private var entry: String = ""
    /// The first PIN of a create/change pair, held while it's confirmed. Kept in
    /// memory for the few seconds between the two entries and never persisted.
    @State private var firstEntry: String?
    @State private var step: Step = .idle
    @State private var errorMessage: LocalizedStringResource?
    /// Whether to mark the new lock as "same PIN as Plex", so unlocking the
    /// profile can also satisfy the Plex Home-user prompt.
    @State private var reusePlexPIN = false

    private enum Step: Equatable {
        /// Showing the summary + actions.
        case idle
        /// Collecting the first entry of a new PIN.
        case creating
        /// Collecting the confirming entry.
        case confirming
    }

    private var profile: Profile { context.activeProfile }
    private var isLocked: Bool { profile.isLocked }

    /// Whether this profile plays as a Plex Home user that already asks for a
    /// PIN — the only case where offering to reuse it makes sense.
    private var boundToProtectedPlexUser: Bool {
        if profile.plexHomeUserRequiresPIN == true { return true }
        return profile.plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

    var body: some View {
        SettingsSplitLayout(title: ProfileLockCopy.title, sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        switch step {
        case .idle: [summarySection]
        case .creating, .confirming: [entrySection]
        }
    }

    // MARK: - Idle: summary + actions

    private var summarySection: SettingsSplitSection {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "explanation",
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
                SettingsSplitRow(
                    id: "device-only",
                    title: ProfileLockCopy.lockIsDeviceOnly
                ) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.yellow)
                }
            )
        }

        rows.append(
            SettingsSplitRow(
                id: "primary",
                title: isLocked ? ProfileLockCopy.editPIN : ProfileLockCopy.create
            ) {
                Button(isLocked ? ProfileLockCopy.editPIN : ProfileLockCopy.create) {
                    beginCreating()
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
                        context.onSetProfileLock(nil)
                    }
                }
            )
        }

        return SettingsSplitSection(id: "profile-lock", header: ProfileLockCopy.title, rows: rows)
    }

    // MARK: - Creating / confirming

    private var entrySection: SettingsSplitSection {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "entry",
                title: step == .creating ? ProfileLockCopy.enterToCreate : ProfileLockCopy.confirm,
                description: errorMessage
            ) {
                PINBoxes(filledCount: entry.count)
            },
            SettingsSplitRow(id: "keypad", title: ProfileLockCopy.title) {
                PINStrip(onDigit: appendDigit, onDelete: deleteDigit)
            }
        ]

        // Only worth offering on the first entry, and only when there's a Plex
        // PIN to match — otherwise it's a toggle that does nothing.
        if step == .creating, boundToProtectedPlexUser {
            rows.append(
                SettingsSplitRow(
                    id: "reuse-plex",
                    title: ProfileLockCopy.usePlexPIN,
                    description: ProfileLockCopy.usePlexPINDetail
                ) {
                    Toggle(ProfileLockCopy.usePlexPIN, isOn: $reusePlexPIN)
                        .labelsHidden()
                }
            )
        }

        rows.append(
            SettingsSplitRow(id: "cancel", title: "Cancel") {
                Button("Cancel", role: .cancel) { reset() }
            }
        )

        return SettingsSplitSection(id: "profile-lock-entry", header: ProfileLockCopy.title, rows: rows)
    }

    // MARK: - Entry handling

    private func beginCreating() {
        entry = ""
        firstEntry = nil
        errorMessage = nil
        step = .creating
    }

    private func reset() {
        entry = ""
        firstEntry = nil
        errorMessage = nil
        step = .idle
    }

    private func appendDigit(_ d: String) {
        guard d.count == 1, d.first?.isNumber == true else { return }
        guard entry.count < ProfileLock.pinLength else { return }
        entry.append(d)
        guard entry.count == ProfileLock.pinLength else { return }

        switch step {
        case .creating:
            firstEntry = entry
            entry = ""
            errorMessage = nil
            step = .confirming
        case .confirming:
            defer { entry = "" }
            guard let first = firstEntry, first == entry else {
                // Start over rather than letting them retry the confirmation:
                // if the two didn't match we don't know which one they meant.
                errorMessage = ProfileLockCopy.mismatch
                firstEntry = nil
                step = .creating
                return
            }
            guard let lock = ProfileLock.make(pin: first, matchesPlexPIN: reusePlexPIN) else {
                errorMessage = ProfileLockCopy.mismatch
                firstEntry = nil
                step = .creating
                return
            }
            context.onSetProfileLock(lock)
            firstEntry = nil
            step = .idle
        case .idle:
            break
        }
    }

    private func deleteDigit() {
        if !entry.isEmpty { entry.removeLast() }
    }
}
#endif
