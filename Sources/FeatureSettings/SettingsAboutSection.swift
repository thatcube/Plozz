#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Footer panel for Settings showing app identity, release notes, open-source
/// info, and a QR code linking to the GitHub repo. Its two explicit rows provide
/// focus targets, so the surrounding informational card does not need focus.
struct SettingsAboutSection: View {
    let version: String
    let build: String
    let repoURL: String
    /// Invoked on each remote-select of the panel — drives the hidden Developer
    /// Mode unlock (seven selects). `nil` leaves the panel inert.
    var onActivate: (() -> Void)? = nil

    var body: some View {
        SettingsPanel {
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) {
                    Image("PlozzLogo")
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 72, height: 72)

                    if let onActivate {
                        Button(action: onActivate) {
                            versionRow
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    } else {
                        versionRow
                    }

                    if ReleaseNotesModel.shared.isAvailable {
                        NavigationLink(value: SettingsRoute.releaseNotes) {
                            SettingsRowLabel(
                                icon: "doc.text",
                                title: "Release Notes",
                                trailing: {
                                    Image(systemName: "chevron.forward")
                                        .font(.caption.weight(.semibold))
                                        .settingsRowSecondary()
                                }
                            )
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    }

                    Text("Bring all of your media together into one unified experience. Free forever and open source.")
                        .font(.callout)
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    SettingsQRCode(string: repoURL)
                        .frame(width: 180, height: 180)

                    Text("Scan to view the\nGitHub repo")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .plozzForeground(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Scan to view the Plozz GitHub repository")
            }
        }
    }

    private var versionRow: some View {
        SettingsRowLabel(
            icon: "number",
            title: "Version \(version) (Build \(build))"
        )
        .accessibilityLabel("Version \(version), build \(build)")
    }
}

#endif
