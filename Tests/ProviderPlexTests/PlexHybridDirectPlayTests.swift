import XCTest
import CoreModels
@testable import ProviderPlex

/// Verifies the Plex capability-expansion policy: the `hybridEngineEnabled` flag
/// flips exactly the extra direct-play formats the on-device VLCKit engine can
/// handle (Matroska container; DTS / DTS-HD / TrueHD audio), while keeping
/// DoVi/HDR-in-MKV out of direct play so advertise ⇔ route stays in lockstep.
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

    func testSDRMatroskaDirectPlaysWhenHybridOn() throws {
        let caps = MediaCapabilities(supportsHEVC: true)
        XCTAssertTrue(try canDirectPlay(sdrMKV, caps: caps, hybrid: true))
    }

    // MARK: DoVi/HDR-in-MKV must stay out of direct play even with hybrid on

    func testDolbyVisionMatroskaTranscodesEvenWithHybridOn() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"truehd",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","DOVIPresent":true,"DOVIProfile":8},
           {"id":11,"streamType":2,"index":1,"codec":"truehd"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true, supportsDolbyVision: true)
        XCTAssertFalse(try canDirectPlay(json, caps: caps, hybrid: true),
                       "DoVi-in-MKV must transcode to HLS so it renders on AVPlayer")
    }

    func testHDR10MatroskaTranscodesEvenWithHybridOn() throws {
        let json = """
        {"id":1,"container":"mkv","videoCodec":"hevc","audioCodec":"dts",
         "Part":[{"id":2,"key":"/library/parts/2/16000/file.mkv","container":"mkv","Stream":[
           {"id":10,"streamType":1,"index":0,"codec":"hevc","colorTrc":"smpte2084"},
           {"id":11,"streamType":2,"index":1,"codec":"dts"}
         ]}]}
        """
        let caps = MediaCapabilities(supportsHEVC: true, supportsHDR10: true)
        XCTAssertFalse(try canDirectPlay(json, caps: caps, hybrid: true))
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
}
