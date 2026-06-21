#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Footer panel for Settings showing app identity, the auto-stamped version /
/// build, open-source info, and a QR code linking to the GitHub repo. tvOS has
/// no browser, so a scannable code is how we hand the URL off to a phone.
struct SettingsAboutSection: View {
    let version: String
    let build: String
    let repoURL: String

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 10) {
                    infoRow("Name", "Plozz")
                    infoRow("Version", version)
                    infoRow("Build", build)
                }

                Text("Plozz is free and open source — an unofficial tvOS client for Jellyfin, not affiliated with or endorsed by Jellyfin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                QRCodeView(string: repoURL)
                    .frame(width: 180, height: 180)

                Text("Scan to view the\nGitHub repo")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
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
