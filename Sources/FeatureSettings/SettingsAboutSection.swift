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
/// The whole panel is made **focusable** so that on tvOS it can actually be
/// reached: a non-interactive view never receives focus, which previously meant
/// the user could not scroll the content into view and the About text was
/// effectively unreadable on the 10-foot UI. Focusing it lets the parent
/// `ScrollView` scroll to it and shows a subtle highlight.
struct SettingsAboutSection: View {
    let version: String
    let build: String
    let repoURL: String

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var focusFill: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    private var focusForeground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 16) {
                Image("PlozzLogo")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 10) {
                    infoRow("Name", "Plozz")
                    infoRow("Version", version)
                    infoRow("Build", build)
                }

                Text("Plozz is free and open source — an unofficial tvOS client for Jellyfin and Plex, not affiliated with or endorsed by Jellyfin or Plex.")
                    .font(.callout)
                    .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground.opacity(0.72)) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                QRCodeView(string: repoURL)
                    .frame(width: 180, height: 180)

                Text("Scan to view the\nGitHub repo")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground.opacity(0.72)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(20)
        // Unified focus look: native tvOS "inverted card" — white-on-black in
        // light mode, black-on-white in dark mode — matching the row style in
        // SettingsRowStyle.swift. Only the highlight expands outward; the
        // content stays anchored in place (no full-label scale).
        .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground) : AnyShapeStyle(.primary))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? focusFill : Color.clear)
                .padding(.horizontal, isFocused ? -10 : 0)
                .padding(.vertical, isFocused ? -6 : 0)
                .shadow(
                    color: Color.black.opacity(isFocused ? 0.28 : 0),
                    radius: isFocused ? 14 : 0,
                    y: isFocused ? 6 : 0
                )
        )
        .focusable()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("About Plozz. Version \(version), build \(build). Free and open source, an unofficial tvOS client for Jellyfin and Plex. Scan the on-screen code to view the GitHub repository.")
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
        }
        .font(.headline)
    }
}

/// Renders a QR code for an arbitrary string using CoreImage. The generated
/// image is nearest-neighbor scaled so the code stays crisp at display size.
private struct QRCodeView: View {
    let string: String

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image = Self.makeQRCode(from: string) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        Image("GitHubMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.secondary.opacity(0.2))
    }

    #if canImport(UIKit)
    private static func makeQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

#endif
