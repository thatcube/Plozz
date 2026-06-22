#if canImport(SwiftUI) && canImport(CoreImage)
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders a QR code for a string (typically a URL) so a user can scan it with a
/// phone instead of typing a code. Generated on-device with Core Image; no
/// network access.
///
/// Draw it on a light background — QR scanners expect dark modules on a light
/// field, so callers should place this over white (e.g. a white rounded card).
public struct QRCodeView: View {
    private let content: String

    public init(_ content: String) {
        self.content = content
    }

    public var body: some View {
        if let image = Self.makeImage(from: content) {
            image
                .interpolation(.none) // keep crisp module edges when scaled up
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    private static func makeImage(from string: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale the 1-module-per-pixel output up so the rendered CGImage is sharp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
#endif
