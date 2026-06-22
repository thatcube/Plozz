#if canImport(Libmpv) && canImport(UIKit)
import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import Metal
import CoreModels

/// The colorimetry mode the engine drives the render surface (and, on tvOS, the
/// display) into for a given stream.
///
/// - `sdr`: plain 8-bit BT.709 — no HDR surface, no display-mode switch.
/// - `pq`: SMPTE-2084 (PQ) BT.2020 — HDR10, HDR10+, and Dolby Vision (after
///   libplacebo reshapes the P5/P8 RPU to PQ).
/// - `hlg`: ARIB STD-B67 (HLG) BT.2020.
enum MPVHDRMode: String, Sendable {
    case sdr
    case pq
    case hlg

    var isHDR: Bool { self != .sdr }
}

/// Pure helpers mapping provider HDR metadata + the chosen mode onto concrete
/// Metal / Core Media / mpv configuration. Kept free of side effects so they're
/// trivially testable and usable from both the view and the engine.
enum MPVHDR {
    /// Classifies a stream's dynamic range from the provider's source metadata.
    ///
    /// Dolby Vision is treated as `pq`: libplacebo parses the RPU and reshapes
    /// the base layer to PQ HDR10, so the correct output surface is PQ BT.2020.
    static func mode(from video: MediaSourceMetadata.VideoStream?) -> MPVHDRMode {
        guard let video else { return .sdr }
        let rangeType = (video.videoRangeType ?? "").uppercased()
        let transfer = (video.colorTransfer ?? "").lowercased()
        let range = (video.videoRange ?? "").uppercased()

        // Dolby Vision (any base layer) → PQ: libplacebo reshapes the RPU to PQ
        // HDR10 regardless of base layer, so check DoVi before the HLG token
        // (DOVIWithHLG would otherwise be misread as HLG).
        if rangeType.contains("DOVI") || rangeType.contains("DV") {
            return .pq
        }
        // HLG (its tokens don't overlap the PQ set).
        if rangeType.contains("HLG") || transfer.contains("arib-std-b67") || transfer.contains("hlg") {
            return .hlg
        }
        // PQ-based: HDR10 / HDR10+.
        if rangeType.contains("HDR10")
            || transfer.contains("smpte2084") || transfer.contains("pq") {
            return .pq
        }
        // Generic "HDR" with no finer token — assume PQ (the common case).
        if range == "HDR" { return .pq }
        return .sdr
    }

    /// The Metal drawable format for the mode. HDR needs a wide-precision format
    /// (half-float) so libplacebo can emit 10-bit PQ/HLG without banding; SDR
    /// stays on the cheap 8-bit BGRA path.
    static func metalPixelFormat(for mode: MPVHDRMode) -> MTLPixelFormat {
        mode.isHDR ? .rgba16Float : .bgra8Unorm
    }

    /// The CoreGraphics colorspace to tag the `CAMetalLayer` with. On tvOS there
    /// is no per-layer EDR opt-in (`wantsExtendedDynamicRangeContent` is
    /// unavailable); HDR is realized by tagging the surface BT.2020 PQ/HLG and
    /// switching the display into an HDR mode via `AVDisplayManager`.
    static func colorspace(for mode: MPVHDRMode) -> CGColorSpace? {
        switch mode {
        case .sdr: return CGColorSpace(name: CGColorSpace.sRGB)
        case .pq: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        }
    }

    /// mpv's `target-trc` value (transfer characteristics) for the mode, or `nil`
    /// for SDR (let mpv keep its default / the surface hint decide).
    static func mpvTargetTRC(for mode: MPVHDRMode) -> String? {
        switch mode {
        case .sdr: return nil
        case .pq: return "pq"
        case .hlg: return "hlg"
        }
    }

    /// A `CMVideoFormatDescription` carrying the stream's HDR colorimetry, used to
    /// build the `AVDisplayCriteria` that requests an HDR display-mode switch.
    /// Returns `nil` for SDR (no switch needed).
    static func formatDescription(for mode: MPVHDRMode, video: MediaSourceMetadata.VideoStream?) -> CMVideoFormatDescription? {
        guard mode.isHDR else { return nil }

        let transfer: CFString = mode == .hlg
            ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
            : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        let extensions: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCVImageBufferTransferFunctionKey: transfer,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ]

        let width = Int32(video?.width ?? 3840)
        let height = Int32(video?.height ?? 2160)

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType(for: video?.codec),
            width: width,
            height: height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    private static func codecType(for codec: String?) -> CMVideoCodecType {
        switch (codec ?? "").lowercased() {
        case "av1": return kCMVideoCodecType_AV1
        case "h264", "avc": return kCMVideoCodecType_H264
        default: return kCMVideoCodecType_HEVC
        }
    }
}

/// A snapshot of what the HDR path actually realized, for diagnostics. All fields
/// are plain values so it can be read off the engine (and later surfaced in the
/// diagnostics overlay) without touching mpv or UIKit internals.
public struct MPVHDRStatus: Sendable, Equatable {
    /// The dynamic range the engine targeted for the current stream.
    public var requestedMode: String
    /// The Metal pixel format the layer ended up with (e.g. `rgba16Float`).
    public var layerPixelFormat: String
    /// The CoreGraphics colorspace name tagged on the layer, if any.
    public var layerColorspace: String?
    /// Whether the engine asked the display to switch into an HDR mode.
    public var displaySwitchRequested: Bool
    /// Whether the user's tvOS settings currently allow display-mode matching
    /// (`false` means our `preferredDisplayCriteria` will be ignored by the OS).
    public var displayMatchingEnabled: Bool

    public init(
        requestedMode: String = "sdr",
        layerPixelFormat: String = "",
        layerColorspace: String? = nil,
        displaySwitchRequested: Bool = false,
        displayMatchingEnabled: Bool = false
    ) {
        self.requestedMode = requestedMode
        self.layerPixelFormat = layerPixelFormat
        self.layerColorspace = layerColorspace
        self.displaySwitchRequested = displaySwitchRequested
        self.displayMatchingEnabled = displayMatchingEnabled
    }
}

extension MTLPixelFormat {
    /// A short human-readable token for the formats this engine uses.
    var debugName: String {
        switch self {
        case .rgba16Float: return "rgba16Float"
        case .bgra8Unorm: return "bgra8Unorm"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        case .bgr10a2Unorm: return "bgr10a2Unorm"
        case .rgb10a2Unorm: return "rgb10a2Unorm"
        default: return "raw(\(rawValue))"
        }
    }
}
#endif
