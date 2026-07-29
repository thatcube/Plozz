import XCTest
@testable import CoreModels

/// A viewer picks a *kind* of file, not a file. These pin the behaviour that
/// makes that carry across a series, where every episode's files have their own
/// provider ids and an id-based memory can never match.
final class MediaVersionDescriptorTests: XCTestCase {
    private func version(
        id: String,
        height: Int? = nil,
        range: String? = nil,
        codec: String? = nil,
        name: String? = nil,
        edition: String? = nil,
        audioChannels: Int? = nil,
        audioProfile: String? = nil,
        isDefault: Bool = false,
        bitrate: Int? = nil
    ) -> MediaVersion {
        var version = MediaVersion(id: id)
        version.height = height
        version.videoRange = range
        version.videoCodec = codec
        version.name = name
        version.edition = edition
        version.audioChannels = audioChannels
        version.audioProfile = audioProfile
        version.isDefault = isDefault
        version.bitrate = bitrate
        return version
    }

    func testCarriesA4KChoiceOntoTheNextEpisodesOwnFiles() {
        // The whole point: episode 3's chosen file id appears nowhere in episode
        // 4's versions, but "2160p Dolby Vision AV1" does.
        let chosen = version(id: "ep3-uhd", height: 2160, range: "DOVI", codec: "av1")
        let descriptor = MediaVersionDescriptor(version: chosen)

        let nextEpisode = [
            version(id: "ep4-hd", height: 1080, range: "SDR", codec: "h264"),
            version(id: "ep4-uhd", height: 2160, range: "DOVI", codec: "av1")
        ]
        XCTAssertEqual(nextEpisode.bestMatch(for: descriptor)?.id, "ep4-uhd")
    }

    func testFallsBackWhenTheEpisodeHasNothingLikeIt() {
        // A show that drops to a single 480p file for one episode should play its
        // best available version, not be forced onto a bad "closest" match.
        let descriptor = MediaVersionDescriptor(
            version: version(id: "uhd", height: 2160, range: "DOVI", codec: "av1")
        )
        let sparse = [version(id: "sd", height: 480, range: "SDR", codec: "h264")]
        XCTAssertNil(sparse.bestMatch(for: descriptor))
    }

    func testPrefersTheNearestResolutionWhenTheExactOneIsMissing() {
        // 1440p is a far better stand-in for 2160p than 480p, so a show that
        // varies its masters still tracks the viewer's intent.
        let descriptor = MediaVersionDescriptor(version: version(id: "uhd", height: 2160))
        let mixed = [
            version(id: "sd", height: 480),
            version(id: "qhd", height: 1440)
        ]
        XCTAssertEqual(mixed.bestMatch(for: descriptor)?.id, "qhd")
    }

    func testCarriesA4KChoiceToA1080pOnlyEpisode() {
        let descriptor = MediaVersionDescriptor(version: version(id: "uhd", height: 2160))
        let nextEpisode = [
            version(id: "sd", height: 480),
            version(id: "hd", height: 1080)
        ]
        XCTAssertEqual(nextEpisode.bestMatch(for: descriptor)?.id, "hd")
    }

    func testDoesNotTreat720pAsCloseEnoughToA4KOnlyPreference() {
        let descriptor = MediaVersionDescriptor(version: version(id: "uhd", height: 2160))
        XCTAssertNil([version(id: "hd", height: 720)].bestMatch(for: descriptor))
    }

    func testAnExplicitEditionOutranksEveryTechnicalField() {
        // Edition is a CONTENT choice. A 4K Theatrical cut is the wrong film to
        // someone who asked for the Director's Cut, however good the file is.
        let chosen = version(id: "dc-1080", height: 1080, name: "Director's Cut 1080p")
        let descriptor = MediaVersionDescriptor(version: chosen)
        XCTAssertNotNil(descriptor.edition, "the edition must be captured for this test to mean anything")

        let candidates = [
            version(id: "theatrical-2160", height: 2160, name: "Theatrical 2160p"),
            version(id: "dc-2160", height: 2160, name: "Director's Cut 2160p")
        ]
        XCTAssertEqual(candidates.bestMatch(for: descriptor)?.id, "dc-2160")
    }

    func testMissingCandidateEditionIsUnknownRatherThanAMismatch() {
        let descriptor = MediaVersionDescriptor(
            version: version(
                id: "dc",
                height: 2160,
                range: "DOVI",
                edition: "Director's Cut"
            )
        )
        let candidates = [
            version(id: "theatrical", height: 2160, range: "DOVI", edition: "Theatrical"),
            version(id: "unlabelled", height: 2160, range: "DOVI")
        ]
        XCTAssertEqual(candidates.bestMatch(for: descriptor)?.id, "unlabelled")
    }

    func testAudioOnlyPreferenceCanChooseAtmos() {
        let descriptor = MediaVersionDescriptor(
            version: version(id: "atmos-1", audioProfile: "Dolby Atmos")
        )
        let candidates = [
            version(id: "stereo", audioChannels: 2),
            version(id: "atmos-2", audioProfile: "Dolby Atmos")
        ]
        XCTAssertEqual(candidates.bestMatch(for: descriptor)?.id, "atmos-2")
    }

    func testStereoIsRememberedFromChannelCountWhenProfileIsMissing() {
        let descriptor = MediaVersionDescriptor(
            version: version(id: "stereo-1", audioChannels: 2)
        )
        XCTAssertEqual(descriptor.audioProfile, "stereo")
        let candidates = [
            version(id: "atmos", audioProfile: "Dolby Atmos"),
            version(id: "stereo-2", audioChannels: 2)
        ]
        XCTAssertEqual(candidates.bestMatch(for: descriptor)?.id, "stereo-2")
    }

    func testMatchesDynamicRangeWithoutOtherFacts() {
        let descriptor = MediaVersionDescriptor(
            version: version(id: "dovi-1", range: "DOVI")
        )
        let candidates = [
            version(id: "sdr", range: "SDR"),
            version(id: "hdr10", range: "HDR10"),
            version(id: "dovi-2", range: "DOVI")
        ]
        XCTAssertEqual(candidates.bestMatch(for: descriptor)?.id, "dovi-2")
    }

    func testDynamicRangeMatchWinsWhenResolutionScoresWouldTie() {
        let descriptor = MediaVersionDescriptor(
            version: version(id: "chosen", height: 2160, range: "SDR")
        )
        let candidates = [
            version(id: "same-resolution-wrong-range", height: 2160, range: "DOVI"),
            version(id: "lower-resolution-same-range", height: 1080, range: "SDR")
        ]
        XCTAssertEqual(
            candidates.bestMatch(for: descriptor)?.id,
            "lower-resolution-same-range"
        )
    }

    func testUncensoredAnimeEditionCarriesAcrossEpisodes() {
        let descriptor = MediaVersionDescriptor(
            version: version(id: "uncensored-1", name: "Episode 3 Uncensored 1080p")
        )
        XCTAssertEqual(descriptor.edition, "uncensored")
        let candidates = [
            version(id: "broadcast", name: "Episode 4 Censored 1080p"),
            version(id: "uncensored-2", name: "Episode 4 Uncensored 1080p")
        ]
        XCTAssertEqual(candidates.bestMatch(for: descriptor)?.id, "uncensored-2")
    }

    func testRemembersNothingWhenThereWasNothingToRemember() {
        // A version with no stated facts carries no intent, so it must not
        // silently pin the show to whatever file happened to be picked.
        let descriptor = MediaVersionDescriptor(version: version(id: "bare"))
        XCTAssertTrue(descriptor.isEmpty)
        XCTAssertNil([version(id: "other", height: 2160)].bestMatch(for: descriptor))
    }

    func testKnownPreferenceDoesNotMatchCandidatesWithNoFacts() {
        let descriptor = MediaVersionDescriptor(
            version: version(id: "known", height: 2160, range: "DOVI")
        )
        XCTAssertNil([
            version(id: "bare-a"),
            version(id: "bare-b")
        ].bestMatch(for: descriptor))
    }

    func testResolvesTheSameWayEveryTimeForEquallyGoodCandidates() {
        // Two identical-shape files must not alternate between launches.
        let descriptor = MediaVersionDescriptor(version: version(id: "x", height: 2160))
        let duplicates = [
            version(id: "a", height: 2160, bitrate: 20_000_000),
            version(id: "b", height: 2160, bitrate: 40_000_000)
        ]
        let first = duplicates.bestMatch(for: descriptor)?.id
        XCTAssertEqual(first, duplicates.reversed().bestMatch(for: descriptor)?.id)
        XCTAssertEqual(first, "b", "the better file wins the tiebreak")
    }
}

/// Independent checks on the cases a real library actually throws at this,
/// written after the scoring was redesigned around comparable evidence.
extension MediaVersionDescriptorTests {
    func testAShowThatLabelsEditionsOnlySometimesStillMatches() {
        // The regression that motivated the redesign: a descriptor carrying an
        // edition must not disqualify every unlabelled file, or a show that names
        // the cut on one episode and not the rest falls back forever.
        var chosen = MediaVersion(id: "s1e1", height: 2160)
        chosen.name = "Uncensored 2160p"
        let descriptor = MediaVersionDescriptor(version: chosen)
        XCTAssertNotNil(descriptor.edition)

        let unlabelled = [
            MediaVersion(id: "s1e2-hd", height: 1080),
            MediaVersion(id: "s1e2-uhd", height: 2160)
        ]
        XCTAssertEqual(unlabelled.bestMatch(for: descriptor)?.id, "s1e2-uhd")
    }

    func testA1080pEpisodeInAnOtherwise4KShowStillPlays() {
        // One SD-mastered episode shouldn't silently revert the whole show to the
        // server default; 1080p is the honest best answer to "the 4K one".
        let descriptor = MediaVersionDescriptor(version: MediaVersion(id: "uhd", height: 2160))
        let onlyHD = [MediaVersion(id: "hd", height: 1080)]
        XCTAssertEqual(onlyHD.bestMatch(for: descriptor)?.id, "hd")
    }

    func test720pIsNotAcceptedAsA4KSubstitute() {
        let descriptor = MediaVersionDescriptor(version: MediaVersion(id: "uhd", height: 2160))
        XCTAssertNil([MediaVersion(id: "sd", height: 720)].bestMatch(for: descriptor))
    }
}
