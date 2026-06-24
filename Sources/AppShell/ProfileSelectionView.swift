#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import FeatureProfiles

/// Hosts the profile picker.
///
/// Used at launch (when "Ask which profile on startup" is on and the
/// household has more than one profile) and from Settings → Profile →
/// "Switch Profile." Editing and adding profiles live in Settings.
struct ProfileSelectionView: View {
    @Bindable var appState: AppState
    /// `true` when there is already an active session behind the picker, so
    /// the picker can be cancelled (Settings entry); `false` at first launch.
    let canCancel: Bool

    var body: some View {
        ProfilePickerView(
            profiles: appState.profilesModel.profiles,
            activeProfileID: appState.profilesModel.activeProfileID,
            onSelect: { appState.switchProfile(to: $0.id) },
            onAddProfile: nil,
            onCancel: canCancel ? { appState.cancelProfileSelection() } : nil
        )
    }
}
#endif
