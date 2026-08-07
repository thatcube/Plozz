#if canImport(SwiftUI)
import CoreUI
import SwiftUI

/// Why Home has little or nothing to show, when the reason is a SETTING rather
/// than an empty library.
///
/// Worth stating outright: a profile watching nothing renders a Home that looks
/// broken. Some rows can still appear — a watchlist is a durable, deliberately
/// server-independent list, so titles saved before every server was switched off
/// keep showing — which makes the silence around them harder to explain, not
/// easier. The notice says which setting caused it and where to undo it.
public enum HomeContentNotice: Equatable, Sendable {
    /// No servers have been added to this device at all.
    case noServersConfigured
    /// Servers exist, but this profile has switched every one of them off.
    case allServersSwitchedOff
    /// Servers are on, but every library inside them is hidden from Home.
    case allLibrariesHidden

    var message: LocalizedStringResource {
        switch self {
        case .noServersConfigured:
            return LocalizedStringResource(
                "home.notice.noServers",
                defaultValue: "Add a media server in Settings to see your libraries here.",
                comment: "Shown on Home when no media server has been added to the device."
            )
        case .allServersSwitchedOff:
            return LocalizedStringResource(
                "home.notice.serversOff",
                defaultValue: "This profile has every server switched off, so its libraries aren't shown. Turn one back on in Settings › Libraries.",
                comment: "Shown on Home when the profile has disabled every server it could watch from."
            )
        case .allLibrariesHidden:
            return LocalizedStringResource(
                "home.notice.librariesHidden",
                defaultValue: "Every library is hidden from Home. Turn one back on in Settings › Libraries.",
                comment: "Shown on Home when the profile has hidden every library from the Home screen."
            )
        }
    }
}

/// The banner Home shows for a ``HomeContentNotice``.
///
/// Focusable on purpose. Hiding everything can leave Home with no other
/// focusable view, and on tvOS a screen with nothing to focus strands the
/// viewer: focus has nowhere to land, the remote stops responding, and the tab
/// bar that leads back to Settings can't be reached. One focusable control keeps
/// navigation alive, so the setting is always reversible from inside the app.
struct HomeContentNoticeView: View {
    let notice: HomeContentNotice
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            // The same sad-Plozz empty state search and empty libraries use, so
            // every legitimate dead end in the app looks like the same app.
            PlozzEmptyStateView(notice.message)
            Button(
                LocalizedStringResource(
                    "home.notice.reload",
                    defaultValue: "Reload",
                    comment: "Button on the Home empty state that re-fetches content. Also the only focusable control there, so it is what keeps the screen navigable."
                ),
                action: onReload
            )
                .buttonStyle(SettingsFocusButtonStyle())
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 44)
    }
}
#endif
