#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import CoreModels

/// The HDR/Dolby-Vision dynamic-range class of a source, derived from the
/// provider's `MediaSourceMetadata`. Drives the tvOS display-mode switch so the
/// Apple TV negotiates the correct HDMI signalling (true Dolby Vision, HDR10,
/// HLG, or plain SDR) with the panel before `AVPlayer` starts rendering.
///
/// This is the *native* (AVPlayer) path's contribution to true Dolby Vision:
/// only Apple's own pipeline can light up the DoVi handshake, and a custom
/// `AVPlayerLayer`-based player (as opposed to `AVPlayerViewController`) has to
/// drive `AVDisplayManager.preferredDisplayCriteria` itself — tvOS won't switch
/// the display for us automatically.
enum HDRDisplayMode: Equatable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision

    /// Classifies a source from its declared range tokens. Mirrors Jellyfin's
    /// `VideoRangeType` vocabulary (`DOVI`, `DOVIWithHDR10`, `DOVIWithSDR`,
    /// `DOVIWithHLG`, `HDR10`, `HLG`) with `colorTransfer`/`videoRange` as a
    /// fallback. Any Dolby Vision profile maps to `.dolbyVision` so the panel is
    /// driven into DoVi mode; the RPU base layer is handled downstream.
    init(_ metadata: MediaSourceMetadata?) {
        let rangeType = metadata?.video?.videoRangeType?.uppercased() ?? ""
        let range = metadata?.video?.videoRange?.uppercased() ?? ""
        let transfer = metadata?.video?.colorTransfer?.lowercased() ?? ""

        if rangeType.hasPrefix("DOVI") {
            self = .dolbyVision
        } else if rangeType == "HLG" || transfer == "arib-std-b67" {
            self = .hlg
        } else if rangeType == "HDR10" || rangeType == "HDR" || transfer == "smpte2084"
            || range == "HDR" {
            self = .hdr10
        } else {
            self = .sdr
        }
    }

    var isHDR: Bool { self != .sdr }
}

#if os(tvOS)
/// Builds the `AVDisplayCriteria` that asks tvOS to switch the connected display
/// into the dynamic range that matches `mode`. Returns `nil` for SDR (the caller
/// clears any prior preference instead of forcing SDR).
///
/// The criteria is constructed from a synthetic `CMVideoFormatDescription` whose
/// codec FourCC selects Dolby Vision (`dvh1`) vs HDR/SDR HEVC (`hvc1`) and whose
/// colour extensions advertise BT.2020 primaries/matrix with the PQ or HLG
/// transfer function — the same signalling AVKit derives from a real DoVi/HDR
/// sample entry.
func makeDisplayCriteria(mode: HDRDisplayMode, metadata: MediaSourceMetadata?) -> AVDisplayCriteria? {
    guard mode != .sdr else { return nil }

    let width = Int32(metadata?.video?.width ?? 3840)
    let height = Int32(metadata?.video?.height ?? 2160)
    // 0.0 tells tvOS to leave the current refresh rate untouched (dynamic-range
    // switch only) when the source frame rate is unknown.
    let refreshRate = Float(metadata?.video?.frameRate ?? 0)

    // 'dvh1' Dolby Vision HEVC; otherwise standard HEVC.
    let dolbyVisionCodecType: CMVideoCodecType = 0x64766831 // 'dvh1'
    let codecType: CMVideoCodecType = (mode == .dolbyVision)
        ? dolbyVisionCodecType
        : kCMVideoCodecType_HEVC

    let transferFunction: CFString = (mode == .hlg)
        ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ

    let extensions: [CFString: Any] = [
        kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
        kCMFormatDescriptionExtension_TransferFunction: transferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
    ]

    var formatDescription: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: width,
        height: height,
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else { return nil }

    return AVDisplayCriteria(refreshRate: refreshRate, formatDescription: formatDescription)
}
#endif
#endif
