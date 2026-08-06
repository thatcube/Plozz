#if canImport(SwiftUI)
import CoreUI
import SwiftUI

/// Shown when Home has nothing to draw — when every library has been hidden, or
/// every server switched off.
///
/// This exists for FOCUS, not decoration. An empty Home renders an empty scroll
/// view, and on tvOS a screen with no focusable view strands the viewer: focus
/// has nowhere to land, the remote stops responding, and the tab bar that would
/// lead back to Settings can't be reached. The screen looks frozen even though
/// the app is running normally. One focusable control is enough to restore
/// navigation, so the viewer can always get back to Settings and undo it.
struct HomeNothingVisibleView: View {
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 64))
                .plozzForeground(.secondary)
            Text("Nothing to show here")
                .font(.title2)
            Text(
                "Nothing is switched on for this profile. Turn a server or library back on in Settings › Libraries.",
                comment: "Explains that Home is empty because the viewer switched off every server or library, and where to undo it."
            )
            .font(.title3)
            .plozzForeground(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button("Reload", action: onReload)
                .buttonStyle(SettingsFocusButtonStyle())
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 80)
    }
}
#endif
