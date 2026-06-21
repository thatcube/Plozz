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

/// A scan-to-sign-in QR code on a white rounded card with a brand logo inset in
/// the center, mirroring the Twozz sign-in screens so both apps feel consistent.
///
/// The modules are tinted to the brand colour and the center logo occludes part
/// of the code, so the QR is generated at the highest error-correction level
/// ("H", ~30% recoverable) to stay scannable.
public struct BrandQRCodeView<Logo: View>: View {
    /// The URL the QR encodes (the activation link to open on a phone).
    let payload: String
    /// Colour applied to the QR modules (the "dark" cells).
    var moduleColor: Color
    /// Side length of the QR image inside the white card.
    var size: CGFloat
    /// Brand logo inset in the center of the code.
    @ViewBuilder var logo: () -> Logo

    public init(
        payload: String,
        moduleColor: Color = .black,
        size: CGFloat = 460,
        @ViewBuilder logo: @escaping () -> Logo
    ) {
        self.payload = payload
        self.moduleColor = moduleColor
        self.size = size
        self.logo = logo
    }

    public var body: some View {
        Group {
            if let image = QRCodeRenderer.makeQRCode(from: payload, tint: UIColor(moduleColor)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .overlay { logoBadge }
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.06))
                    .overlay(ProgressView())
            }
        }
        .frame(width: size, height: size)
        .padding(32)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 36))
    }

    private var logoBadge: some View {
        logo()
            .padding(size * 0.035)
            .frame(width: size * 0.22, height: size * 0.22)
            .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.045))
    }
}

/// Non-generic QR renderer (a generic type can't hold the cached `CIContext`).
enum QRCodeRenderer {
    private static let ciContext = CIContext()

    static func makeQRCode(from string: String, tint: UIColor) -> UIImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(string.utf8)
        generator.correctionLevel = "H"
        guard let base = generator.outputImage else { return nil }

        // Map black modules -> brand tint, white background -> white.
        let colorize = CIFilter.falseColor()
        colorize.inputImage = base
        colorize.color0 = CIColor(color: tint)
        colorize.color1 = CIColor(color: .white)
        guard let output = colorize.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#endif
