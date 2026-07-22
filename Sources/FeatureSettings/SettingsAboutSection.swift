#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Footer panel for Settings showing app identity, the auto-stamped version /
/// build, open-source info, and a QR code linking to the GitHub repo. tvOS has
/// no browser, so a scannable code is how we hand the URL off to a phone.
///
/// The whole panel is focusable so that on tvOS it can actually be reached: a
/// non-interactive view never receives focus, which previously meant the user
/// could not scroll the content into view and the About text was effectively
/// unreadable on the 10-foot UI. It uses the shared `FocusableSettingsPanel`
/// focus look — a soft, theme-tinted outline blooming around the whole panel,
/// matching the avatar/cast/profile-tile treatment — so focus never inverts the
/// panel's contrast.
struct SettingsAboutSection: View {
    let version: String
    let build: String
    let repoURL: String
    /// Invoked on each remote-select of the panel — drives the hidden Developer
    /// Mode unlock (seven selects). `nil` leaves the panel inert.
    var onActivate: (() -> Void)? = nil

    var body: some View {
        FocusableSettingsPanel(onActivate: onActivate) {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) {
                    Image("PlozzLogo")
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 72, height: 72)

                    Text("Version \(version) (Build \(build))")
                        .font(.headline)

                    Text("Bring all of your media together into one unified experience. Free forever and open source.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    SettingsQRCode(string: repoURL)
                        .frame(width: 180, height: 180)

                    Text("Scan to view the\nGitHub repo")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("About Plozz. Version \(version), build \(build). Bring all of your media together into one unified experience. Free forever and open source. Scan the on-screen code to view the GitHub repository.")
        }
    }

}

#endif
