#if canImport(SwiftUI) && canImport(UIKit)
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Plex brand constants shared by the sign-in screen.
public enum PlexBrand {
    /// Plex's signature gold/amber (`#E5A00D`). Used for the logo mark and the
    /// QR modules so the scan code reads as on-brand.
    public static let gold = Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
}

/// The Plex ">" chevron, drawn as a thick stroked path so it needs no bundled
/// asset and scales crisply at any size.
public struct PlexLogoMark: View {
    public var color: Color = PlexBrand.gold

    public init(color: Color = PlexBrand.gold) {
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                path.move(to: CGPoint(x: w * 0.30, y: h * 0.10))
                path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.50))
                path.addLine(to: CGPoint(x: w * 0.30, y: h * 0.90))
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: w * 0.26, lineCap: .round, lineJoin: .miter)
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A scan-to-sign-in QR code rendered plainly — brand-tinted (default white)
/// modules on a transparent background, with no surrounding card and no center
/// logo. On the dark sign-in screen this reads as white-on-black, which iOS
/// (and modern scanners) handle as an inverted code.
public struct BrandQRCodeView: View {
    /// The URL the QR encodes (the activation link to open on a phone).
    let payload: String
    /// Colour applied to the QR modules (the "dark" cells).
    var moduleColor: Color
    /// Side length of the QR image.
    var size: CGFloat

    public init(
        payload: String,
        moduleColor: Color = .white,
        size: CGFloat = 440
    ) {
        self.payload = payload
        self.moduleColor = moduleColor
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = QRCodeRenderer.makeQRCode(from: payload, tint: UIColor(moduleColor)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
                    .overlay(ProgressView())
            }
        }
        .frame(width: size, height: size)
    }
}

/// Non-generic QR renderer (a generic type can't hold the cached `CIContext`).
enum QRCodeRenderer {
    private static let ciContext = CIContext()

    static func makeQRCode(from string: String, tint: UIColor) -> UIImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(string.utf8)
        generator.correctionLevel = "M"
        guard let base = generator.outputImage else { return nil }

        // Map dark modules -> tint, light background -> transparent, so the code
        // sits directly on the screen with no white container.
        let colorize = CIFilter.falseColor()
        colorize.inputImage = base
        colorize.color0 = CIColor(color: tint)
        colorize.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let output = colorize.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#endif
