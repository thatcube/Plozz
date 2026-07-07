#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders a QR code for an arbitrary string using CoreImage. tvOS has no
/// browser, so a scannable code is how Plozz hands a URL off to a phone (used
/// by both the About panel's repo link and the Report a Problem flow).
///
/// The generated image is nearest-neighbour scaled so the code stays crisp at
/// display size. `correctionLevel` trades error-resilience for density: use
/// "H" for short URLs (About repo link) and "M" for longer pre-filled URLs
/// (the GitHub issue link) so the code stays scannable on a TV at ~10 feet.
struct SettingsQRCode: View {
    let string: String
    var correctionLevel: String = "H"
    var centerMark: String? = "GitHubMark"

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image = Self.makeQRCode(from: string, correctionLevel: correctionLevel) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous))
                    .overlay {
                        if let centerMark {
                            Image(centerMark)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                                .padding(8)
                                .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
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
        RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
            .fill(Color.secondary.opacity(0.2))
    }

    #if canImport(UIKit)
    private static func makeQRCode(from string: String, correctionLevel: String) -> UIImage? {
        let context = CIContext()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}
#endif
