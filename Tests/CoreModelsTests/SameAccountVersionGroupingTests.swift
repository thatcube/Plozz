import XCTest
@testable import CoreModels

/// Tests for grouping **same-account** duplicate items of the same movie into
/// one detail page with a multi-entry version picker — the Jellyfin/Plex parity
/// fix for the case where Jellyfin holds two distinct movie items for one film
/// instead of folding them into a single multi-MediaSource item like Plex does.
///
/// Plex auto-merges several files for one title into one item with multiple
/// `<Media>` elements. Jellyfin doesn't — each file shows up as its own item,
/// each with a single `MediaSources` entry (so its `versions == []` in our
/// model). The grouping/synthesis below is what lets Plozz present those
/// duplicates as one detail page whose version picker offers each file, each
/// carrying its own backing-item id so playback repoints correctly.
final class SameAccountVersionGroupingTests: XCTestCase {
    private let jellyAccount = "acct-jelly"
    private let plexAccount = "acct-plex"

    private func info(_ accountID: String) -> SourceServerInfo? {
        switch accountID {
        case jellyAccount: return SourceServerInfo(providerKind: .jellyfin, serverName: "Home Jellyfin")
        case plexAccount: return SourceServerInfo(providerKind: .plex, serverName: "Home Plex")
        default: return nil
        }
    }

    private func sameServerDuplicate(
        id: String,
        title: String = "Office Turbulence",
        year: Int = 2018,
        tmdb: String = "194",
        width: Int = 3840,
        height: Int = 2160,
        videoRange: String = "HDR10",
        sizeBytes: Int64? = nil
    ) -> MediaItem {
        MediaItem(
            id: id, title: title, kind: .movie, productionYear: year,
            providerIDs: ["Tmdb": tmdb],
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: width, height: height,
                             videoRangeType: videoRange),
                audio: .init(codec: "eac3", channels: 6, channelLayout: "5.1")
            ),
            sourceAccountID: jellyAccount,
            versions: []
        )
    }

    // MARK: Merger — same-account duplicates

    func testTwoSameAccountSameTmdbItemsMergeIntoOneWithTwoSources() {
        let a = sameServerDuplicate(id: "jf-A")
        let b = sameServerDuplicate(id: "jf-B")
        let merged = MediaItemMerger.merge([a, b], serverInfo: info)
        XCTAssertEqual(merged.count, 1, "Same-account same-tmdb items must group")
        let result = merged[0]
        XCTAssertEqual(result.sources.count, 2, "Both backing items must be remembered as sources")
        XCTAssertEqual(Set(result.sources.map(\.accountID)), [jellyAccount])
        XCTAssertEqual(result.sources.map(\.itemID), ["jf-A", "jf-B"])
    }

    func testSameAccountMergeSynthesizesOneVersionPerBackingItem() {
        let a = sameServerDuplicate(id: "jf-A", videoRange: "HDR10")
        let b = sameServerDuplicate(id: "jf-B", videoRange: "DOVI")
        let merged = MediaItemMerger.merge([a, b], serverInfo: info)
        guard let primary = merged.first else { return XCTFail("Missing merged item") }

        // Each source gets one synthesised version pointing back at its own item.
        XCTAssertEqual(primary.sources[0].versions.count, 1)
        XCTAssertEqual(primary.sources[1].versions.count, 1)
        XCTAssertEqual(primary.sources[0].versions[0].sourceItemID, "jf-A")
        XCTAssertEqual(primary.sources[0].versions[0].sourceAccountID, jellyAccount)
        XCTAssertEqual(primary.sources[1].versions[0].sourceItemID, "jf-B")
        XCTAssertEqual(primary.sources[1].versions[0].sourceAccountID, jellyAccount)

        // The synthesised versions surface their distinguishing media facts so
        // the picker rows can tell the two files apart.
        XCTAssertEqual(primary.sources[0].versions[0].hdrLabel, "HDR10")
        XCTAssertEqual(primary.sources[1].versions[0].hdrLabel, "Dolby Vision")
    }

    func testTwoDifferentFilmsDoNotMergeEvenWhenOnSameAccount() {
        // Conservative identity safety: two genuinely different films must never
        // collapse just because they happen to live on the same account.
        let dune = sameServerDuplicate(id: "jf-dune", title: "Dune", year: 2021, tmdb: "438631")
        let arrival = sameServerDuplicate(id: "jf-arrival", title: "Arrival", year: 2016, tmdb: "329865")
        let merged = MediaItemMerger.merge([dune, arrival], serverInfo: info)
        XCTAssertEqual(Set(merged.map(\.id)), ["jf-dune", "jf-arrival"])
        XCTAssertTrue(merged.allSatisfy { $0.sources.isEmpty },
                      "Items that don't share identity must not become each other's sources")
    }

    func testTwoSameTitleSameYearMoviesGroupViaTitleIdentityWhenNoIDs() {
        // Title identity is movies-only; on the same account two title+year
        // duplicates should still merge (it's the same film by definition).
        let a = MediaItem(id: "jf-A", title: "Some Indie Film", kind: .movie,
                          productionYear: 2018, sourceAccountID: jellyAccount)
        let b = MediaItem(id: "jf-B", title: "Some Indie Film", kind: .movie,
                          productionYear: 2018, sourceAccountID: jellyAccount)
        let merged = MediaItemMerger.merge([a, b], serverInfo: info)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sources.map(\.itemID), ["jf-A", "jf-B"])
    }

    func testSeriesWithSameTitleYearDoNotMerge() {
        // Series must not get a title identity — two same-name shows are
        // routinely different shows (reboot vs original). Belt-and-braces.
        let a = MediaItem(id: "jf-S1", title: "House of Cards", kind: .series,
                          productionYear: 2013, sourceAccountID: jellyAccount)
        let b = MediaItem(id: "jf-S2", title: "House of Cards", kind: .series,
                          productionYear: 2013, sourceAccountID: jellyAccount)
        let merged = MediaItemMerger.merge([a, b], serverInfo: info)
        XCTAssertEqual(Set(merged.map(\.id)), ["jf-S1", "jf-S2"])
    }

    // MARK: MediaVersion.synthesized

    func testSynthesizedVersionCarriesBackingItemAndMediaFacts() {
        let item = sameServerDuplicate(id: "jf-A", width: 1920, height: 1080,
                                       videoRange: "SDR")
        let version = MediaVersion.synthesized(from: item)
        // `id` is prefixed `synth:` so it can never be mistaken for a real
        // Jellyfin MediaSource UUID if it ever leaked through the play path.
        XCTAssertEqual(version.id, "synth:jf-A")
        XCTAssertEqual(version.sourceItemID, "jf-A")
        XCTAssertEqual(version.sourceAccountID, jellyAccount)
        XCTAssertEqual(version.resolutionLabel, "1080p")
        XCTAssertEqual(version.videoCodec, "hevc")
        XCTAssertEqual(version.audioCodec, "eac3")
        XCTAssertEqual(version.container, "mkv")
        XCTAssertFalse(version.isHDR)
    }

    /// The regression this whole change exists to prevent: a synthesised version
    /// for a real 4K Dolby Vision (HDR10 base layer) + Atmos file must render the
    /// SAME badges its own item's hero would — `[4K, Dolby Vision, Dolby Atmos,
    /// HDR10]` — NOT a lossy "720p · SDR" downgrade. Badges flow through the
    /// carried `sourceMetadata`, so they go through the authoritative
    /// `MediaSourceMetadata.technicalBadges` path rather than re-derivation from
    /// the flattened (HDRRange-limited) fields.
    func testSynthesizedVersionBadgesComeFromRealMetadataNotLossyFlattening() {
        let item = MediaItem(
            id: "jf-4K", title: "Fallout", kind: .movie, productionYear: 2024,
            providerIDs: ["Tmdb": "194"],
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: 3840, height: 1600,
                             videoRange: "HDR", videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos",
                             channels: 6, channelLayout: "5.1")
            ),
            sourceAccountID: jellyAccount,
            versions: []
        )
        let version = MediaVersion.synthesized(from: item)
        XCTAssertEqual(version.sourceMetadata, item.mediaInfo)
        XCTAssertTrue(version.isHDR)
        XCTAssertEqual(version.resolutionLabel, "4K")
        // The hero badge row reads exactly these, Dolby-grouped:
        XCTAssertEqual(version.technicalBadges, item.mediaInfo?.technicalBadges)
        XCTAssertEqual(
            version.technicalBadges.map(\.label),
            ["4K", "Dolby Vision", "Dolby Atmos", "HDR10"]
        )
    }

    /// HDR10+ has no `HDRRange` enum case, so the OLD flattened path silently
    /// dropped it to SDR. Through `sourceMetadata` it survives as `HDR10+`.
    func testSynthesizedVersionPreservesHDR10PlusThatFlatteningWouldDrop() {
        let item = MediaItem(
            id: "jf-HDR10Plus", title: "Fallout", kind: .movie, productionYear: 2024,
            providerIDs: ["Tmdb": "194"],
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: 3840, height: 2160,
                             videoRange: "HDR", videoRangeType: "HDR10Plus"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6)
            ),
            sourceAccountID: jellyAccount,
            versions: []
        )
        let version = MediaVersion.synthesized(from: item)
        XCTAssertTrue(version.isHDR)
        XCTAssertEqual(version.hdrLabel, "HDR10+")
        XCTAssertTrue(version.technicalBadges.map(\.label).contains("HDR10+"))
    }

    /// A lower-quality sibling must still read accurately so the picker rows are
    /// genuinely distinguishable: a 720p SDR stereo file reads `[720p, SDR]`.
    func testSynthesized720pSDRVersionReadsAccurately() {
        let item = MediaItem(
            id: "jf-720", title: "Fallout", kind: .movie, productionYear: 2024,
            providerIDs: ["Tmdb": "194"],
            mediaInfo: MediaSourceMetadata(
                container: "mp4",
                video: .init(codec: "h264", width: 1280, height: 720,
                             videoRange: "SDR", videoRangeType: "SDR"),
                audio: .init(codec: "aac", channels: 2, channelLayout: "stereo")
            ),
            sourceAccountID: jellyAccount,
            versions: []
        )
        let version = MediaVersion.synthesized(from: item)
        XCTAssertFalse(version.isHDR)
        XCTAssertEqual(version.resolutionLabel, "720p")
        XCTAssertEqual(version.technicalBadges.map(\.label), ["720p", "SDR"])
    }

    /// The 4K HDR Atmos sibling must out-rank the 720p SDR one regardless of
    /// arrival order, so the picker defaults to / leads with the better file.
    func testHDRSiblingOutranksSDRSiblingInPickerOrder() {
        let sd = MediaVersion.synthesized(from: MediaItem(
            id: "jf-720", title: "Fallout", kind: .movie,
            providerIDs: ["Tmdb": "194"],
            mediaInfo: MediaSourceMetadata(
                video: .init(codec: "h264", width: 1280, height: 720,
                             videoRange: "SDR", videoRangeType: "SDR")),
            sourceAccountID: jellyAccount, versions: []))
        let uhd = MediaVersion.synthesized(from: MediaItem(
            id: "jf-4K", title: "Fallout", kind: .movie,
            providerIDs: ["Tmdb": "194"],
            mediaInfo: MediaSourceMetadata(
                video: .init(codec: "hevc", width: 3840, height: 2160,
                             videoRange: "HDR", videoRangeType: "HDR10Plus")),
            sourceAccountID: jellyAccount, versions: []))
        XCTAssertEqual([sd, uhd].sortedForPicker().map(\.sourceItemID), ["jf-4K", "jf-720"])
        XCTAssertEqual([uhd, sd].sortedForPicker().map(\.sourceItemID), ["jf-4K", "jf-720"])
    }

    func testResolverDiscoversSameAccountSiblingWhilstExcludingPrimaryItself() async {
        let primary = sameServerDuplicate(id: "jf-A")
        let sibling = sameServerDuplicate(id: "jf-B")
        let unrelated = MediaItem(id: "jf-other", title: "Other", kind: .movie,
                                  productionYear: 1999, providerIDs: ["Tmdb": "999"],
                                  sourceAccountID: jellyAccount)

        // The search always returns both the primary itself, the sibling, and an
        // unrelated film. The resolver must filter out the primary's own id (so
        // the merger sees only the sibling) and the unrelated film must NOT
        // attach because its tmdb id doesn't match.
        let sources = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: [jellyAccount],
            search: { _, _ in [primary, sibling, unrelated] },
            serverInfo: info
        )
        XCTAssertEqual(sources.count, 2, "Primary + sibling, unrelated excluded by identity")
        XCTAssertEqual(Set(sources.map(\.itemID)), ["jf-A", "jf-B"])
        XCTAssertEqual(Set(sources.map(\.accountID)), [jellyAccount])
    }

    // MARK: MediaItem.selectingSource — repoint to backing item

    func testSelectingSourceRepointsItemIDToBackingItem() {
        // The primary item carries id "jf-A"; selecting the sibling's source
        // must repoint id/sourceAccountID/etc to "jf-B" so playback resolves
        // against the right file.
        let primary = sameServerDuplicate(id: "jf-A")
        let siblingRef = MediaSourceRef(
            accountID: jellyAccount,
            itemID: "jf-B",
            providerKind: .jellyfin,
            versions: [MediaVersion.synthesized(from: sameServerDuplicate(id: "jf-B"))]
        )
        let retargeted = primary.selectingSource(siblingRef)
        XCTAssertEqual(retargeted.id, "jf-B")
        XCTAssertEqual(retargeted.sourceAccountID, jellyAccount)
        XCTAssertEqual(retargeted.selectedSourceAccountID, jellyAccount)
    }

    // MARK: Play routing — selecting a version picks the right backing item

    /// BUG A reproducer: the user reported pressing Play on the 4K-labelled
    /// picker entry started the 720p file. Asserts the play routing always
    /// repoints to the version's backing item id when the version carries
    /// `sourceItemID`/`sourceAccountID`, regardless of which sources are
    /// present in the list at the moment Play fires.
    func testSelectingVersionRoutesPlaybackToItsBackingItemID() {
        let primary = sameServerDuplicate(id: "jf-720p", width: 1280, height: 720, videoRange: "SDR")
        let sibling = sameServerDuplicate(id: "jf-4K", width: 3840, height: 2160, videoRange: "HDR10")
        let merged = MediaItemMerger.merge([primary, sibling], serverInfo: info)
        guard let item = merged.first else { return XCTFail("Missing merged item") }
        let versions = item.sources.flatMap(\.versions).sortedForPicker()
        guard let fourKVersion = versions.first else { return XCTFail("Missing 4K version") }
        XCTAssertEqual(fourKVersion.sourceItemID, "jf-4K", "Sorted order must put 4K first")

        let retargeted = MediaItem.retargetedForPlayback(
            item: item, sources: item.sources,
            activeAccountID: jellyAccount,
            versionID: fourKVersion.id
        )
        XCTAssertEqual(retargeted.id, "jf-4K", "Play must repoint to the 4K backing item")
        XCTAssertNil(retargeted.selectedVersionID,
                     "Synthesized version ids must NOT leak as Jellyfin MediaSourceIds")
    }

    func testPlayRoutingFallsBackToBackingItemEvenIfSourcesListIsStale() {
        // Race-case Bug A defense: the version carries a backing
        // `(accountID, itemID)` stamp but the matching MediaSourceRef hasn't
        // been folded into `sources` yet (e.g. discovery still in flight,
        // snapshot lag). The router must still repoint via the version's own
        // stamp instead of silently downgrading to the primary's id.
        let primary = sameServerDuplicate(id: "jf-720p")
        let staleVersion = MediaVersion.synthesized(from:
            sameServerDuplicate(id: "jf-4K", width: 3840, height: 2160))
        // sources holds only the 720p ref (no 4K source yet), but the picker
        // somehow surfaced the 4K version. Play must still target jf-4K.
        let primaryRef = MediaSourceRef(accountID: jellyAccount, itemID: "jf-720p",
                                        providerKind: .jellyfin,
                                        versions: [MediaVersion.synthesized(from: primary), staleVersion])
        let retargeted = MediaItem.retargetedForPlayback(
            item: primary, sources: [primaryRef],
            activeAccountID: jellyAccount,
            versionID: staleVersion.id
        )
        XCTAssertEqual(retargeted.id, "jf-4K",
                       "Stale-sources race must NOT downgrade play to the primary item id")
        XCTAssertNil(retargeted.selectedVersionID)
    }

    /// BUG A race reproducer: the user reported intermittent wrong-file plays
    /// in the window between picker render and async sibling discovery. The
    /// contract this asserts: routing called against the LATEST sources +
    /// the picker's currently-highlighted version id must always target the
    /// version's backing item, regardless of the source-set's pre-discovery
    /// shape. The view-side fix is to re-resolve sources/versionID from the
    /// view model at FIRE time (not body-eval time) so a tap that races a
    /// discovery update can't run a stale closure.
    func testPlayRoutingTracksFreshestSourcesAcrossAsyncDiscoveryExpansion() {
        let primary = sameServerDuplicate(id: "jf-720p", width: 1280, height: 720)
        let sibling = sameServerDuplicate(id: "jf-4K", width: 3840, height: 2160, videoRange: "HDR10")

        // BEFORE discovery: only the primary source is known. Play with no
        // version override must target the primary file.
        let preDiscoverySources = [MediaSourceRef(accountID: jellyAccount, itemID: "jf-720p",
                                                  providerKind: .jellyfin,
                                                  versions: [MediaVersion.synthesized(from: primary)])]
        let preResult = MediaItem.retargetedForPlayback(
            item: primary, sources: preDiscoverySources,
            activeAccountID: jellyAccount, versionID: nil
        )
        XCTAssertEqual(preResult.id, "jf-720p")

        // AFTER discovery: sibling joins. With the picker now showing both,
        // the highlighted version (4K, by qualityScore) must route to jf-4K.
        let merged = MediaItemMerger.merge([primary, sibling], serverInfo: info)[0]
        let postVersions = merged.sources.flatMap(\.versions).sortedForPicker()
        let highlightedID = postVersions.first!.id // == synth:jf-4K
        let postResult = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: jellyAccount, versionID: highlightedID
        )
        XCTAssertEqual(postResult.id, "jf-4K",
                       "After discovery, Play must follow the highlighted version's backing item")
    }

    // MARK: Stable picker ordering

    func testSortedForPickerOrdersByQualityRegardlessOfInsertionOrder() {
        // Simulate the real bug: the 1080p sibling is discovered AFTER the 4K
        // primary, so the raw list is [4K, 1080p]; on second open another
        // arrival path produces [1080p, 4K]. Either way the picker must show
        // 4K first because it has the higher qualityScore.
        let v4k = MediaVersion.synthesized(from: sameServerDuplicate(
            id: "jf-A", width: 3840, height: 2160, videoRange: "HDR10",
            sizeBytes: 60_000_000_000))
        let v1080 = MediaVersion.synthesized(from: sameServerDuplicate(
            id: "jf-B", width: 1920, height: 1080, videoRange: "SDR",
            sizeBytes: 8_000_000_000))

        let firstOpen = [v4k, v1080].sortedForPicker()
        let afterRefresh = [v1080, v4k].sortedForPicker()
        XCTAssertEqual(firstOpen.map(\.id), afterRefresh.map(\.id),
                       "Picker order must not depend on arrival/insertion order")
        XCTAssertEqual(firstOpen.map(\.sourceItemID), ["jf-A", "jf-B"],
                       "Higher qualityScore (4K HDR) must sort first")
    }

    func testSortedForPickerTiebreaksOnSizeThenStableID() {
        // Two versions with identical resolution/HDR/bitrate must still get a
        // deterministic order — fall back to size, then the stable
        // sourceItemID/id key. The same input in either input order produces
        // the same output.
        let a = MediaVersion(id: "jf-A", width: 1920, height: 1080,
                             sizeBytes: 10_000_000_000,
                             sourceItemID: "jf-A", sourceAccountID: jellyAccount)
        let b = MediaVersion(id: "jf-B", width: 1920, height: 1080,
                             sizeBytes: 20_000_000_000,
                             sourceItemID: "jf-B", sourceAccountID: jellyAccount)
        XCTAssertEqual([a, b].sortedForPicker().map(\.id), ["jf-B", "jf-A"],
                       "Larger file wins the size tiebreak")
        XCTAssertEqual([b, a].sortedForPicker().map(\.id), ["jf-B", "jf-A"])

        // Identical size: stable id tiebreak (jf-A < jf-B).
        let c = MediaVersion(id: "jf-A", width: 1920, height: 1080,
                             sizeBytes: 10_000_000_000,
                             sourceItemID: "jf-A", sourceAccountID: jellyAccount)
        let d = MediaVersion(id: "jf-B", width: 1920, height: 1080,
                             sizeBytes: 10_000_000_000,
                             sourceItemID: "jf-B", sourceAccountID: jellyAccount)
        XCTAssertEqual([c, d].sortedForPicker().map(\.id), ["jf-A", "jf-B"])
        XCTAssertEqual([d, c].sortedForPicker().map(\.id), ["jf-A", "jf-B"])
    }
}
