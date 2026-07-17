import XCTest
import CoreModels
@testable import FeaturePlayback

/// Direct unit tests for `TrackMenuBuilder`, the pure collaborator that builds
/// the audio / subtitle / secondary-subtitle picker menus and the small
/// selection/eligibility decisions that feed them. These pin the fiddly rules
/// (audio-selection priority, "Off" pinning, preferred-language sort, bitmap
/// exclusion, engine-dual vs sidecar sourcing) that used to be buried in
/// `PlayerViewModel.loadTrackOptions`.
final class TrackMenuBuilderTests: XCTestCase {

    private func audio(_ id: Int, lang: String? = nil, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .audio, displayTitle: "Audio \(id)", language: lang, isDefault: isDefault)
    }

    private func sub(
        _ id: Int,
        lang: String? = nil,
        codec: String? = nil,
        isImageBased: Bool = false,
        hasSidecar: Bool = false,
        isExternal: Bool = false
    ) -> MediaTrack {
        MediaTrack(
            id: id,
            kind: .subtitle,
            displayTitle: "Sub \(id)",
            language: lang,
            codec: codec,
            deliverySource: hasSidecar ? .localFile(URL(fileURLWithPath: "/tmp/\(id).vtt")) : nil,
            isImageBasedSubtitle: isImageBased,
            isExternal: isExternal
        )
    }

    // MARK: - resolveSelectedAudioTrackID

    func testAudioSelectionPrefersPendingWhenPresent() {
        let tracks = [audio(1), audio(2)]
        // Engine not yet on the pending pick → keep pending, don't clear it.
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 1, pending: 2, engineActive: 1, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertFalse(r.clearPending)
    }

    func testAudioSelectionClearsPendingOnceEngineConfirms() {
        let tracks = [audio(1), audio(2)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 2, pending: 2, engineActive: 2, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertTrue(r.clearPending)
    }

    func testAudioSelectionPendingIgnoredWhenNotInTrackList() {
        let tracks = [audio(1), audio(2)]
        // pending 9 absent → fall through to engine active (2), clearing pending.
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 1, pending: 9, engineActive: 2, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertTrue(r.clearPending)
    }

    func testAudioSelectionFallsBackToEngineActive() {
        let tracks = [audio(1), audio(2)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: nil, pending: nil, engineActive: 2, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertTrue(r.clearPending)
    }

    func testAudioSelectionDefaultFlagHeuristicOnlyWhenNothingKnown() {
        let tracks = [audio(1), audio(2, isDefault: true)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: nil, pending: nil, engineActive: nil, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertFalse(r.clearPending)
    }

    func testAudioSelectionDefaultFallsBackToFirstTrack() {
        let tracks = [audio(5), audio(6)]
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: nil, pending: nil, engineActive: nil, tracks: tracks)
        XCTAssertEqual(r.selected, 5)
    }

    func testAudioSelectionKeepsCurrentWhenNothingElseMatches() {
        let tracks = [audio(1), audio(2)]
        // current set, no pending, engineActive absent/unmatched → unchanged.
        let r = TrackMenuBuilder.resolveSelectedAudioTrackID(current: 2, pending: nil, engineActive: 99, tracks: tracks)
        XCTAssertEqual(r.selected, 2)
        XCTAssertFalse(r.clearPending)
    }

    // MARK: - audioOptions

    func testAudioOptionsSortPreferredLanguageFirstAndMarkSelected() {
        let tracks = [audio(1, lang: "jpn"), audio(2, lang: "eng")]
        let options = TrackMenuBuilder.audioOptions(tracks: tracks, selectedID: 1, preferred: ["eng"])
        XCTAssertEqual(options.map(\.id), [2, 1])       // English sorted to top
        XCTAssertTrue(options.first { $0.id == 1 }!.isSelected)
        XCTAssertFalse(options.first { $0.id == 2 }!.isSelected)
    }

    // MARK: - subtitleOptions

    func testSubtitleOptionsEmptyWhenNoTracks() {
        XCTAssertTrue(
            TrackMenuBuilder.subtitleOptions(tracks: [], selectedID: nil, preferred: [], detectedLanguages: [:]).isEmpty
        )
    }

    func testSubtitleOptionsPinOffFirstAndReflectSelection() {
        let tracks = [sub(1, lang: "eng"), sub(2, lang: "jpn")]
        let options = TrackMenuBuilder.subtitleOptions(
            tracks: tracks, selectedID: nil, preferred: ["eng"], detectedLanguages: [:]
        )
        XCTAssertEqual(options.first?.id, PlayerTrackOption.offID)
        XCTAssertEqual(options.first?.title, "Off")
        XCTAssertTrue(options.first!.isSelected)         // "Off" is selected when primary is off
        XCTAssertEqual(options.dropFirst().map(\.id), [1, 2]) // eng first
    }

    func testSubtitleOptionsMarkExternalFlag() {
        let tracks = [sub(1, isExternal: true), sub(2)]
        let options = TrackMenuBuilder.subtitleOptions(
            tracks: tracks, selectedID: 1, preferred: [], detectedLanguages: [:]
        )
        XCTAssertTrue(options.first { $0.id == 1 }!.isExternal)
        XCTAssertFalse(options.first { $0.id == 2 }!.isExternal)
        XCTAssertFalse(options.first { $0.id == PlayerTrackOption.offID }!.isSelected)
        XCTAssertTrue(options.first { $0.id == 1 }!.isSelected)
    }

    // MARK: - eligibleSecondaryTracks

    func testSecondaryEligibilityBitmapPrimaryDisablesDual() {
        let engineTracks = [sub(1, codec: "pgs"), sub(2, hasSidecar: true)]
        let eligible = TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: 1, engineTracks: engineTracks, providerTracks: engineTracks,
            engineSupportsDualDecode: false
        )
        XCTAssertTrue(eligible.isEmpty)
    }

    func testSecondaryEligibilityEngineDualSourcesFromEngineTracks() {
        // Engine-dual: embedded tracks (no sidecar) are eligible, primary + bitmap excluded.
        let engineTracks = [sub(1), sub(2), sub(3, codec: "pgs")]
        let eligible = TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: 1, engineTracks: engineTracks, providerTracks: [],
            engineSupportsDualDecode: true
        )
        XCTAssertEqual(eligible.map(\.id), [2])   // 1 is primary, 3 is bitmap
    }

    func testSecondaryEligibilitySidecarRequiresDeliverySource() {
        let providerTracks = [sub(1, hasSidecar: true), sub(2), sub(3, hasSidecar: true)]
        let eligible = TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: 1, engineTracks: [], providerTracks: providerTracks,
            engineSupportsDualDecode: false
        )
        XCTAssertEqual(eligible.map(\.id), [3])   // 1 is primary, 2 has no sidecar
    }

    // MARK: - secondaryOptions

    func testSecondaryOptionsEmptyWhenNoEligible() {
        XCTAssertTrue(
            TrackMenuBuilder.secondaryOptions(eligible: [], selectedID: nil, preferred: [], detectedLanguages: [:]).isEmpty
        )
    }

    func testSecondaryOptionsPinOffAndReflectSelection() {
        let options = TrackMenuBuilder.secondaryOptions(
            eligible: [sub(2, lang: "eng"), sub(3, lang: "jpn")],
            selectedID: 3, preferred: ["eng"], detectedLanguages: [:]
        )
        XCTAssertEqual(options.first?.id, PlayerTrackOption.offID)
        XCTAssertFalse(options.first!.isSelected)
        XCTAssertEqual(options.dropFirst().map(\.id), [2, 3])  // eng first
        XCTAssertTrue(options.first { $0.id == 3 }!.isSelected)
    }

    // MARK: - imagePrimaryFormat

    func testImagePrimaryFormatNilForTextPrimary() {
        let tracks = [sub(1, hasSidecar: true)]
        XCTAssertNil(TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: 1, engineTracks: tracks, providerTracks: tracks
        ))
    }

    func testImagePrimaryFormatNilWhenPrimaryOff() {
        XCTAssertNil(TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: nil, engineTracks: [sub(1, codec: "pgs")], providerTracks: []
        ))
    }

    func testImagePrimaryFormatReportsHintForBitmapPrimary() {
        let tracks = [sub(1, codec: "pgssub")]
        let hint = TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: 1, engineTracks: tracks, providerTracks: tracks
        )
        XCTAssertNotNil(hint)
    }
}
