import XCTest
import CoreModels
@testable import ProviderPlex

/// Verifies the Plex capability-expansion policy: the `hybridEngineEnabled` flag
/// advertises raw hybrid containers (Matroska + transport-stream) as direct-play
/// **only** for formats that genuinely need on-device decode (Dolby Vision,
/// hybrid-only video codecs, DTS/DTS-HD/TrueHD/Opus/Vorbis audio, interlaced).
/// Plain SDR/HDR10/HLG H.264/HEVC with mainstream audio transcodes (server remux
/// → AVPlayer), keeping advertise ⇔ route in lockstep with `EngineRouter`.
final class PlexHybridDirectPlayTests: XCTestCase {

    private func makeClient(_ caps: MediaCapabilities, hybrid: Bool) -> PlexClient {
        PlexClient(
            baseURL: URL(string: "https://plex.host:32400")!,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "dev1"),
            token: "TOKEN",
            http: StubHTTPClient(),
            capabilities: caps,
            hybridEngineEnabled: hybrid
        )
    }

    private func decodeMedia(_ json: String) throws -> (PlexMedia, PlexPart) {
        let wrapper = "{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"1\",\"Media\":[\(json)]}]}}"
        let response = try JSONDecoder().decode(PlexMediaContainerResponse.self, from: Data(wrapper.utf8))
        let media = try XCTUnwrap(response.MediaContainer.Metadata?.first?.Media?.first)
        let part = try XCTUnwrap(media.Part?.first)
        return (media, part)
    }

    private func canDirectPlay(_ json: String, caps: MediaCapabilities = .default, hybrid: Bool) throws -> Bool {
        let (media, part) = try decodeMedia(json)
        return makeClient(caps, hybrid: hybrid).canDirectPlay(media: media, part: part)
    }

    // MARK: Matroska container gated on the flag

    private let sdrMKV = """
    {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"ac3",
     "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
       {"id":10,"streamType":1,"index":0,"codec":"hevc"},
       {"id":11,"streamType":2,"index":1,"codec":"ac3"}
     ]}]}
    """

    func testMatroskaTranscodesWhenHybridOff() throws {
        let caps = MediaCapabilities(supportsHEVC: true)
        XCTAssertFalse(try canDirectPlay(sdrMKV, caps: caps, hybrid: false))
    }

    func testPlainSDRMatroskaTranscodesEvenWhenHybridOn() throws {
        // FIX A: plain SDR HEVC + mainstream audio in an MKV is no longer
        // direct-played to mpv — the server remuxes it to HLS for AVPlayer.
        let caps = MediaCapabilities(supportsHEVC: true)
        XCTAssertFalse(try canDirectPlay(sdrMKV, caps: caps, hybrid: true),
                       "Plain SDR MKV must transcode (server remux), not direct-play to mpv")
    }

    func testPlainMPEGTSTranscodesWhenHybridOn() throws {
        // Plain H.264 + AC-3 transport stream → server remuxes to seekable HLS.
        let json = """
        {"id":1,"container":"mpegts","videoCodec":"h264","audioCodec":"ac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.ts","container":"mpegts","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"ac3"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    // MARK: Hybrid-only video codecs in a hybrid container → direct-play to mpv

    func testAV1MatroskaDirectPlaysWhenHybridOn() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"av1","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"av1"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true),
                      "AV1-in-MKV must direct-play to the on-device engine")
    }

    func testVP9WebMDirectPlaysWhenHybridOn() throws {
        let json = """
        {"id":1,"container":"webm","videoCodec":"vp9","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.webm","container":"webm","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"vp9"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    func testDTSMatroskaDirectPlaysWhenHybridOn() throws {
        // DTS audio forces on-device decode regardless of the (plain) video.
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"dts",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc"},
           {"id":11,"streamType":2,"index":1,"codec":"dts"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true)
        XCTAssertTrue(try canDirectPlay(json, caps: caps, hybrid: true))
    }

    // MARK: DoVi-in-MKV is decoded on-device when the device supports Dolby Vision

    func testDolbyVisionMatroskaDirectPlaysWhenHybridOn() throws {
        // AVPlayer can't demux MKV and a DoVi transcode is unreliable, so a DoVi
        // MKV is decoded on-device (HEVC base layer) when the device supports DoVi —
        // matching Infuse.
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"ac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":8},
           {"id":11,"streamType":2,"index":1,"codec":"ac3"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertTrue(try canDirectPlay(json, caps: caps, hybrid: true),
                      "DoVi-in-MKV must direct-play on the on-device engine, not transcode")
    }

    func testDolbyVisionMatroskaTranscodesWhenDeviceLacksDoVi() throws {
        // If the device can't present Dolby Vision, fall back to a transcode rather
        // than direct-playing a DoVi signal it can't handle.
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"ac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":8},
           {"id":11,"streamType":2,"index":1,"codec":"ac3"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: false)
        XCTAssertFalse(try canDirectPlay(json, caps: caps, hybrid: true))
    }

    func testHDR10MatroskaWithDTSDirectPlaysWhenHybridOn() throws {
        // The DTS audio (not the HDR10 range) is what forces on-device decode here;
        // mpv tone-maps HDR as needed.
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"dts",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","colorTrc":"smpte2084"},
           {"id":11,"streamType":2,"index":1,"codec":"dts"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true, supportsHDR10: true)
        XCTAssertTrue(try canDirectPlay(json, caps: caps, hybrid: true))
    }

    func testPlainHDR10MatroskaTranscodesWhenHybridOn() throws {
        // FIX A: plain HDR10 HEVC + mainstream audio in an MKV transcodes (server
        // remux/tonemap) rather than direct-playing to mpv — on any display.
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"eac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","colorTrc":"smpte2084"},
           {"id":11,"streamType":2,"index":1,"codec":"eac3"}
         ]}]}
        """
        let hdrCaps = MediaCapabilities(supportsHEVC: true, supportsHDR10: true)
        let sdrCaps = MediaCapabilities(supportsHEVC: true, supportsHDR10: false, supportsHLG: false)
        XCTAssertFalse(try canDirectPlay(json, caps: hdrCaps, hybrid: true))
        XCTAssertFalse(try canDirectPlay(json, caps: sdrCaps, hybrid: true))
    }

    // MARK: DTS / TrueHD audio in an Apple container gated on the flag

    private let dtsMP4 = """
    {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"dca",
     "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
       {"id":10,"streamType":1,"index":0,"codec":"h264"},
       {"id":11,"streamType":2,"index":1,"codec":"dca"}
     ]}]}
    """

    func testDTSTranscodesWhenHybridOffWithoutPassthrough() throws {
        XCTAssertFalse(try canDirectPlay(dtsMP4, caps: .default, hybrid: false))
    }

    func testDTSDirectPlaysWhenHybridOnWithoutPassthrough() throws {
        XCTAssertTrue(try canDirectPlay(dtsMP4, caps: .default, hybrid: true))
    }

    func testTrueHDDirectPlaysOnlyWhenHybridOn() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"truehd",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"truehd"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    func testInterlacedMp4DirectPlaysOnlyWhenHybridOn() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264","scanType":"interlaced"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    // MARK: Non-regression — the common case is unaffected by the flag

    func testCommonH264AacMP4UnaffectedByFlag() throws {
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"aac"}
         ]}]}
        """
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    // MARK: FLAC audio — always decodable by AVFoundation

    func testFLACInMP4DirectPlaysNativelyWithoutHybrid() throws {
        // FLAC has been natively decodable in AVFoundation since tvOS 11, so it
        // must direct-play regardless of the hybrid flag.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"flac",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"flac"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true)
        XCTAssertTrue(try canDirectPlay(json, caps: caps, hybrid: false),
                      "FLAC must direct-play natively (AVFoundation supports it since tvOS 11)")
        XCTAssertTrue(try canDirectPlay(json, caps: caps, hybrid: true))
    }

    // MARK: Opus / Vorbis audio — hybrid decodable

    func testOpusInMKVDirectPlaysWhenHybridOn() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"opus",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc"},
           {"id":11,"streamType":2,"index":1,"codec":"opus"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true)
        XCTAssertFalse(try canDirectPlay(json, caps: caps, hybrid: false),
                       "Opus-in-MKV must not direct-play when hybrid is off (container blocked)")
        XCTAssertTrue(try canDirectPlay(json, caps: caps, hybrid: true),
                      "Opus-in-MKV must direct-play on the hybrid mpv engine")
    }

    func testOpusInAppleContainerDirectPlaysWhenHybridOn() throws {
        // Opus in an MP4/MOV container — AVPlayer can't decode Opus in these, but
        // when hybrid is on the router sends it to mpv.
        let json = """
        {"id":1,"container":"mp4","videoCodec":"h264","audioCodec":"opus",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mp4","container":"mp4","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"opus"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false),
                       "Opus-in-MP4 must not direct-play without hybrid (AVPlayer can't decode it)")
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true),
                      "Opus-in-MP4 must direct-play when hybrid is on (mpv decodes it)")
    }

    func testVorbisInMKVDirectPlaysWhenHybridOn() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"h264","audioCodec":"vorbis",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"vorbis"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    // MARK: M2TS / TS transport-stream containers — plain content transcodes

    private let sdrM2TS = """
    {"id":1,"container":"m2ts","videoCodec":"h264","audioCodec":"ac3",
     "Part":[{"id":2,"key":"/library/parts/2/16000/file.m2ts","container":"m2ts","Stream":[
       {"id":10,"streamType":1,"index":0,"codec":"h264"},
       {"id":11,"streamType":2,"index":1,"codec":"ac3"}
     ]}]}
    """

    func testM2TSTranscodesWhenHybridOff() throws {
        XCTAssertFalse(try canDirectPlay(sdrM2TS, caps: .default, hybrid: false))
    }

    func testPlainM2TSTranscodesWhenHybridOn() throws {
        // FIX A: a plain H.264 + AC-3 transport stream is remuxed to seekable HLS
        // by the server (no broken AVPlayer file seeking) rather than sent to mpv.
        XCTAssertFalse(try canDirectPlay(sdrM2TS, caps: .default, hybrid: true))
    }

    func testDTSM2TSDirectPlaysWhenHybridOn() throws {
        // DTS audio the server may not remux losslessly → on-device decode.
        let json = """
        {"id":1,"container":"m2ts","videoCodec":"h264","audioCodec":"dts",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.m2ts","container":"m2ts","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"h264"},
           {"id":11,"streamType":2,"index":1,"codec":"dts"}
         ]}]}
        """
        XCTAssertFalse(try canDirectPlay(json, caps: .default, hybrid: false))
        XCTAssertTrue(try canDirectPlay(json, caps: .default, hybrid: true))
    }

    func testPlainHEVCM2TSWithHDR10TranscodesWhenHybridOn() throws {
        // Plain HDR10 HEVC + E-AC-3 transport stream → server remux, not mpv.
        let json = """
        {"id":1,"container":"m2ts","videoCodec":"hevc","audioCodec":"eac3",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.m2ts","container":"m2ts","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","colorTrc":"smpte2084"},
           {"id":11,"streamType":2,"index":1,"codec":"eac3"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true, supportsHDR10: true)
        XCTAssertFalse(try canDirectPlay(json, caps: caps, hybrid: true))
    }
}
