import XCTest
@testable import CoreModels

/// Tests for the shared cross-server identity / merge core that Home, aggregated
/// Library browse and Search all rely on: identity safety rules, the union-find
/// merge (and the per-server `sources` it builds), the most-recent-wins unified
/// watch-state, the cross-source best-option default, and the `MediaItem`
/// retargeting helpers that make a merged card play from any server.
final class MediaItemIdentityTests: XCTestCase {
    private func movie(_ id: String, title: String, year: Int? = nil, ids: [String: String] = [:]) -> MediaItem {
        MediaItem(id: id, title: title, kind: .movie, productionYear: year, providerIDs: ids)
    }

    func testExternalIDSuppressesTitleKey() {
        // An item with a strong external id must NOT also emit a title key, so a
        // bad-year live-action remake can't bridge to an anime by title+year.
        let item = movie("m", title: "Dune", year: 2021, ids: ["Tmdb": "438631"])
        let identities = MediaItemIdentity.identities(for: item)
        XCTAssertEqual(identities, [.external(source: "tmdb", value: "438631")])
    }

    func testTitleIdentityIsMoviesOnly() {
        let film = movie("m", title: "Dune", year: 2021)
        XCTAssertEqual(
            MediaItemIdentity.identities(for: film),
            [.title(normalizedTitle: "dune", year: 2021, kind: .movie)]
        )

        let series = MediaItem(id: "s", title: "Dune", kind: .series, productionYear: 2021)
        XCTAssertTrue(MediaItemIdentity.identities(for: series).isEmpty,
                      "Series must never get a title identity (reboot vs original safety)")
    }

    func testTitleIdentityRequiresYear() {
        let noYear = movie("m", title: "Akira")
        XCTAssertTrue(MediaItemIdentity.identities(for: noYear).isEmpty)
    }

    func testNormalizedTitleFoldsPunctuationAccentsAndCase() {
        XCTAssertEqual(MediaItemIdentity.normalizedTitle("Spider-Man"), "spider man")
        XCTAssertEqual(MediaItemIdentity.normalizedTitle("spider man"), "spider man")
        XCTAssertEqual(MediaItemIdentity.normalizedTitle("Amélie"), "amelie")
        XCTAssertEqual(MediaItemIdentity.normalizedTitle("  WALL·E  "), "wall e")
    }

    func testMultipleExternalIDsEmittedInPriorityOrder() {
        let item = movie("m", title: "Dune", year: 2021, ids: ["Tvdb": "x", "Imdb": "tt1", "Tmdb": "42"])
        let identities = MediaItemIdentity.identities(for: item)
        XCTAssertEqual(identities, [
            .external(source: "imdb", value: "tt1"),
            .external(source: "tmdb", value: "42"),
            .external(source: "tvdb", value: "x")
        ])
    }
}

final class MediaItemMergerTests: XCTestCase {
    private func movie(
        _ id: String,
        title: String = "Dune",
        year: Int? = 2021,
        account: String,
        ids: [String: String] = [:],
        versions: [MediaVersion] = [],
        resume: TimeInterval? = nil,
        played: Bool = false,
        favorite: Bool = false,
        lastPlayed: Date? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .movie,
            productionYear: year,
            resumePosition: resume,
            isPlayed: played,
            providerIDs: ids,
            sourceAccountID: account,
            versions: versions,
            isFavorite: favorite,
            lastPlayedAt: lastPlayed
        )
    }

    func testMergesSameExternalIDAcrossServersIntoOneCard() {
        let plex = movie("p1", account: "plex", ids: ["Tmdb": "42"])
        let jelly = movie("j1", account: "jelly", ids: ["Tmdb": "42"])

        let merged = MediaItemMerger.merge([plex, jelly])

        XCTAssertEqual(merged.count, 1)
        let card = merged[0]
        XCTAssertEqual(card.id, "p1", "First occurrence stays primary")
        XCTAssertEqual(card.sources.map(\.accountID), ["plex", "jelly"])
        XCTAssertEqual(card.sources.map(\.itemID), ["p1", "j1"])
        XCTAssertEqual(card.allSourceAccountIDs, ["plex", "jelly"])
        XCTAssertEqual(card.additionalSourceAccountIDs, ["jelly"])
    }

    func testMergesMovieByTitleAndYearWithoutExternalIDs() {
        let a = movie("a", account: "plex")
        let b = movie("b", account: "jelly")
        XCTAssertEqual(MediaItemMerger.merge([a, b]).count, 1)
    }

    func testDoesNotMergeDifferentYears() {
        let original = movie("a", year: 1984, account: "plex")
        let remake = movie("b", year: 2021, account: "jelly")
        XCTAssertEqual(MediaItemMerger.merge([original, remake]).map(\.id), ["a", "b"])
    }

    func testDoesNotMergeSeriesByTitle() {
        let anime = MediaItem(id: "anime", title: "One Piece", kind: .series, productionYear: 1999, sourceAccountID: "jelly")
        let live = MediaItem(id: "live", title: "One Piece", kind: .series, productionYear: 1999, sourceAccountID: "plex")
        XCTAssertEqual(MediaItemMerger.merge([anime, live]).map(\.id), ["anime", "live"])
    }

    func testSingletonsAreReturnedUnchangedWithoutSourceBloat() {
        let a = movie("a", title: "Dune", account: "plex")
        let b = movie("b", title: "Arrival", year: 2016, account: "plex")
        let merged = MediaItemMerger.merge([a, b])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertTrue(merged.allSatisfy { $0.sources.isEmpty }, "Un-merged items carry no sources (no row bloat)")
    }

    func testUnionsProviderIDsAcrossSources() {
        let plex = movie("p", account: "plex", ids: ["Tmdb": "42"])
        let jelly = movie("j", account: "jelly", ids: ["Tmdb": "42", "Imdb": "tt9"])
        let card = MediaItemMerger.merge([plex, jelly])[0]
        XCTAssertEqual(card.providerIDs["Tmdb"], "42")
        XCTAssertEqual(card.providerIDs["Imdb"], "tt9")
    }

    func testServerInfoLabelsSources() {
        let plex = movie("p", account: "plex", ids: ["Tmdb": "42"])
        let jelly = movie("j", account: "jelly", ids: ["Tmdb": "42"])
        let info: [String: SourceServerInfo] = [
            "plex": SourceServerInfo(providerKind: .plex, serverName: "Living Room"),
            "jelly": SourceServerInfo(providerKind: .jellyfin, serverName: "Den")
        ]
        let card = MediaItemMerger.merge([plex, jelly]) { info[$0] }
        XCTAssertEqual(card[0].sources[0].providerKind, .plex)
        XCTAssertEqual(card[0].sources[0].displayName, "Living Room")
        XCTAssertEqual(card[0].sources[1].displayName, "Den")
    }

    func testMergeIsIdempotent() {
        let plex = movie("p", account: "plex", ids: ["Tmdb": "42"])
        let jelly = movie("j", account: "jelly", ids: ["Tmdb": "42"])
        let once = MediaItemMerger.merge([plex, jelly])
        let twice = MediaItemMerger.merge(once)
        XCTAssertEqual(twice.count, 1)
        XCTAssertEqual(twice[0].sources.map(\.id), once[0].sources.map(\.id))
    }

    func testTransitiveMergeViaSharedID() {
        // a~b via Tmdb, b~c via Imdb → all three collapse into one card.
        let a = movie("a", account: "s1", ids: ["Tmdb": "42"])
        let b = movie("b", account: "s2", ids: ["Tmdb": "42", "Imdb": "tt7"])
        let c = movie("c", account: "s3", ids: ["Imdb": "tt7"])
        let merged = MediaItemMerger.merge([a, b, c])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sources.map(\.accountID), ["s1", "s2", "s3"])
    }

    // MARK: Unified watch-state

    private func source(
        _ account: String,
        resume: TimeInterval? = nil,
        played: Bool = false,
        favorite: Bool = false,
        lastPlayed: Date? = nil
    ) -> MediaSourceRef {
        MediaSourceRef(
            accountID: account,
            itemID: "\(account)-item",
            resumePosition: resume,
            isPlayed: played,
            isFavorite: favorite,
            lastPlayedAt: lastPlayed
        )
    }

    func testUnifiedStateMostRecentWins() {
        let old = source("a", resume: 60, lastPlayed: Date(timeIntervalSince1970: 100))
        let new = source("b", resume: 240, lastPlayed: Date(timeIntervalSince1970: 200))
        let unified = MediaItemMerger.unifiedWatchState(from: [old, new])
        XCTAssertEqual(unified.resumePosition, 240, "Newest server's resume wins")
        XCTAssertEqual(unified.lastPlayedAt, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(unified.isPlayed)
    }

    func testUnifiedStateNewestPlayedClearsResume() {
        let resumed = source("a", resume: 120, lastPlayed: Date(timeIntervalSince1970: 100))
        let finished = source("b", played: true, lastPlayed: Date(timeIntervalSince1970: 200))
        let unified = MediaItemMerger.unifiedWatchState(from: [resumed, finished])
        XCTAssertTrue(unified.isPlayed)
        XCTAssertNil(unified.resumePosition, "A finished newest server has no resume")
    }

    func testUnifiedStateNewestUnwatchedBeatsOlderPlayed() {
        // Watched on A long ago, then re-opened & un-watched on B more recently.
        let played = source("a", played: true, lastPlayed: Date(timeIntervalSince1970: 100))
        let unwatched = source("b", resume: 30, lastPlayed: Date(timeIntervalSince1970: 300))
        let unified = MediaItemMerger.unifiedWatchState(from: [played, unwatched])
        XCTAssertFalse(unified.isPlayed, "Most-recent (un-watch) wins over older played")
        XCTAssertEqual(unified.resumePosition, 30)
    }

    func testUnifiedStateFallbackWatchedAnywhereWhenNoTimestamps() {
        let a = source("a", resume: 90)
        let b = source("b", played: true)
        let unified = MediaItemMerger.unifiedWatchState(from: [a, b])
        XCTAssertTrue(unified.isPlayed, "With no timestamps, watched-anywhere wins")
        XCTAssertNil(unified.resumePosition)
    }

    func testUnifiedStateFallbackMostProgressedWhenNoTimestamps() {
        let a = source("a", resume: 90)
        let b = source("b", resume: 600)
        let unified = MediaItemMerger.unifiedWatchState(from: [a, b])
        XCTAssertFalse(unified.isPlayed)
        XCTAssertEqual(unified.resumePosition, 600, "Furthest resume wins when nothing is played")
    }

    func testMergeFoldsFavoriteAcrossServers() {
        let plex = movie("p", account: "plex", ids: ["Tmdb": "42"], favorite: false)
        let jelly = movie("j", account: "jelly", ids: ["Tmdb": "42"], favorite: true)
        let card = MediaItemMerger.merge([plex, jelly])[0]
        XCTAssertTrue(card.isFavorite, "Watchlisted on any server → merged card is watchlisted")
    }

    func testMergeSurfacesProgressFromAlternateServer() {
        // Primary (plex) is untouched; the alternate (jelly) has fresh progress.
        let plex = movie("p", account: "plex", ids: ["Tmdb": "42"])
        let jelly = movie("j", account: "jelly", ids: ["Tmdb": "42"],
                          resume: 240, lastPlayed: Date(timeIntervalSince1970: 500))
        let card = MediaItemMerger.merge([plex, jelly])[0]
        XCTAssertEqual(card.id, "p", "Primary stays plex")
        XCTAssertEqual(card.resumePosition, 240, "But unified progress reflects the jelly play")
    }
}

final class CrossSourceSelectorTests: XCTestCase {
    private func source(_ account: String, versions: [MediaVersion], locality: SourceLocality? = nil) -> MediaSourceRef {
        MediaSourceRef(accountID: account, itemID: "\(account)-i", locality: locality, versions: versions)
    }

    private let h264 = MediaVersion(id: "v", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
    private func uhdTranscode() -> MediaVersion {
        // 4K HEVC Dolby Vision — transcodes on a default (non-DoVi) device.
        MediaVersion(id: "uhd", height: 2160, videoCodec: "hevc", videoRange: "DOVI", audioCodec: "aac")
    }

    func testDirectPlayBeatsHigherQualityTranscode() {
        let directPlay1080 = source("a", versions: [h264])
        let transcode4K = source("b", versions: [uhdTranscode()])
        let pick = CrossSourceSelector.bestSelection(from: [transcode4K, directPlay1080], capabilities: .default)
        XCTAssertEqual(pick?.source.accountID, "a", "A 1080p Direct Play beats a 4K transcode")
        XCTAssertEqual(pick?.version?.id, "v")
    }

    func testKnownVersionsBeatUnknown() {
        let known = source("a", versions: [h264])
        let unknown = source("b", versions: [])
        let pick = CrossSourceSelector.bestSelection(from: [unknown, known], capabilities: .default)
        XCTAssertEqual(pick?.source.accountID, "a")
    }

    func testHigherQualityWinsAmongDirectPlay() {
        let lo = MediaVersion(id: "lo", height: 720, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let hi = MediaVersion(id: "hi", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let pick = CrossSourceSelector.bestSelection(
            from: [source("a", versions: [lo]), source("b", versions: [hi])],
            capabilities: .default
        )
        XCTAssertEqual(pick?.source.accountID, "b")
        XCTAssertEqual(pick?.version?.id, "hi")
    }

    func testMirroredFilePrefersPrimaryDeterministically() {
        // Identical file on two servers → primary (first) wins the tie.
        let pick = CrossSourceSelector.bestSelection(
            from: [source("primary", versions: [h264]), source("mirror", versions: [h264])],
            capabilities: .default
        )
        XCTAssertEqual(pick?.source.accountID, "primary")
    }

    func testEmptySourcesIsNil() {
        XCTAssertNil(CrossSourceSelector.bestSelection(from: [], capabilities: .default))
    }

    // MARK: - Origin-aware selection (soft tie-break)

    func testOriginPreferenceDoesNotOverrideQuality() {
        // The origin (library tile) server holds only a 720p file; another server
        // (equal locality) holds a 1080p Direct Play. Origin preference is a SOFT
        // tie-break — it must NOT drag playback down to the worse copy. The
        // higher-quality copy wins.
        let lo = MediaVersion(id: "lo", height: 720, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let hi = MediaVersion(id: "hi", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let origin = source("origin", versions: [lo])
        let other = source("other", versions: [hi])

        let pick = CrossSourceSelector.bestSelection(
            from: [other, origin],
            capabilities: .default,
            preferring: "origin"
        )
        XCTAssertEqual(pick?.source.accountID, "other", "Origin affinity must not override a higher-quality copy")
        XCTAssertEqual(pick?.version?.id, "hi")
    }

    func testOriginPreferenceDoesNotOverrideLocality() {
        // Origin is remote (sister's Tailscale server); another server is local.
        // Locality is the top rank key, so the local copy wins even though the
        // remote one is the browsed library.
        let remoteOrigin = source("origin", versions: [h264], locality: .remote)
        let localOther = source("other", versions: [h264], locality: .local)

        let pick = CrossSourceSelector.bestSelection(
            from: [remoteOrigin, localOther],
            capabilities: .default,
            preferring: "origin"
        )
        XCTAssertEqual(pick?.source.accountID, "other", "A local copy must beat a remote origin")
    }

    func testOriginPreferenceBreaksExactTie() {
        // Two identical copies (same locality, same quality). Origin affinity is
        // the last tie-break, so the browsed library's copy wins even though it is
        // not the primary (first) source.
        let pick = CrossSourceSelector.bestSelection(
            from: [source("primary", versions: [h264]), source("origin", versions: [h264])],
            capabilities: .default,
            preferring: "origin"
        )
        XCTAssertEqual(pick?.source.accountID, "origin", "On an exact tie the browsed library's copy wins")
    }

    func testNilPreferenceFallsBackToBestSelection() {
        let lo = MediaVersion(id: "lo", height: 720, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let hi = MediaVersion(id: "hi", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let pick = CrossSourceSelector.bestSelection(
            from: [source("a", versions: [lo]), source("b", versions: [hi])],
            capabilities: .default,
            preferring: nil
        )
        XCTAssertEqual(pick?.source.accountID, "b", "Home/Search (no origin) keeps the smart best default")
        XCTAssertEqual(pick?.version?.id, "hi")
    }

    func testAbsentPreferenceFallsBackToBestSelection() {
        // The preferred account isn't among the sources (e.g. that server signed
        // out) → behaves exactly like no preference.
        let lo = MediaVersion(id: "lo", height: 720, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let hi = MediaVersion(id: "hi", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac")
        let pick = CrossSourceSelector.bestSelection(
            from: [source("a", versions: [lo]), source("b", versions: [hi])],
            capabilities: .default,
            preferring: "ghost"
        )
        XCTAssertEqual(pick?.source.accountID, "b")
    }

    func testOriginPreferenceEmptySourcesIsNil() {
        XCTAssertNil(CrossSourceSelector.bestSelection(from: [], capabilities: .default, preferring: "x"))
    }
}

final class MediaItemSourceHelpersTests: XCTestCase {
    private func ref(_ account: String, item: String, versions: [MediaVersion] = []) -> MediaSourceRef {
        MediaSourceRef(accountID: account, itemID: item, versions: versions)
    }

    func testSelectingSourceRetargetsIDAccountVersionsAndState() {
        let v = MediaVersion(id: "altv", height: 2160)
        let alt = MediaSourceRef(accountID: "jelly", itemID: "j99", versions: [v],
                                 resumePosition: 42, isPlayed: false, isFavorite: true,
                                 lastPlayedAt: Date(timeIntervalSince1970: 9))
        let base = MediaItem(id: "p1", title: "Dune", kind: .movie, sourceAccountID: "plex",
                             versions: [MediaVersion(id: "pv")],
                             sources: [ref("plex", item: "p1"), alt])

        let retargeted = base.selectingSource(alt, versionID: "altv")
        XCTAssertEqual(retargeted.id, "j99")
        XCTAssertEqual(retargeted.sourceAccountID, "jelly")
        XCTAssertEqual(retargeted.selectedSourceAccountID, "jelly")
        XCTAssertEqual(retargeted.versions.map(\.id), ["altv"])
        XCTAssertEqual(retargeted.selectedVersionID, "altv")
        XCTAssertEqual(retargeted.resumePosition, 42)
        XCTAssertTrue(retargeted.isFavorite)
        XCTAssertFalse(retargeted.sources.isEmpty, "Identity/sources preserved for further switching")
    }

    func testSelectingSourceDropsVersionNotOnTargetServer() {
        let alt = ref("jelly", item: "j99", versions: [MediaVersion(id: "only")])
        let base = MediaItem(id: "p1", title: "X", kind: .movie, sources: [alt])
        let retargeted = base.selectingSource(alt, versionID: "does-not-exist")
        XCTAssertNil(retargeted.selectedVersionID, "An invalid version id falls back to the server default")
    }

    // MARK: - explicitSourceSelection flag (locality re-selection gate)

    func testSelectingSourceDefaultsToNonExplicit() {
        // An auto default (no `explicit:`) leaves the flag false so the play
        // router (`bestSourcePlayItem`) may re-select a more-local copy.
        let alt = ref("jelly", item: "j99", versions: [MediaVersion(id: "v")])
        let base = MediaItem(id: "p1", title: "X", kind: .movie, sources: [alt])
        XCTAssertFalse(base.selectingSource(alt).explicitSourceSelection)
    }

    func testSelectingSourceExplicitSetsFlag() {
        // A deliberate user pick sets the flag so the router honors it as-is.
        let alt = ref("jelly", item: "j99", versions: [MediaVersion(id: "v")])
        let base = MediaItem(id: "p1", title: "X", kind: .movie, sources: [alt])
        XCTAssertTrue(base.selectingSource(alt, explicit: true).explicitSourceSelection)
    }

    func testRetargetedForPlaybackThreadsExplicitFlag() {
        let alt = ref("jelly", item: "j99", versions: [MediaVersion(id: "v")])
        let base = MediaItem(id: "p1", title: "X", kind: .movie, sourceAccountID: "plex",
                             sources: [ref("plex", item: "p1"), alt])
        let auto = MediaItem.retargetedForPlayback(item: base, sources: base.sources,
                                                   activeAccountID: "jelly", versionID: nil)
        XCTAssertFalse(auto.explicitSourceSelection, "Auto retarget stays re-selectable")
        let picked = MediaItem.retargetedForPlayback(item: base, sources: base.sources,
                                                     activeAccountID: "jelly", versionID: nil, explicit: true)
        XCTAssertTrue(picked.explicitSourceSelection, "An explicit pick is honored downstream")
    }

    func testExplicitFlagIsTransientAcrossCoding() throws {
        // The flag is per-play UI state, never persisted — a decoded item is
        // always non-explicit so a cached pick can't wrongly pin a remote server.
        let alt = ref("jelly", item: "j99", versions: [MediaVersion(id: "v")])
        let base = MediaItem(id: "p1", title: "X", kind: .movie, sources: [alt])
            .selectingSource(alt, explicit: true)
        XCTAssertTrue(base.explicitSourceSelection)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(base))
        XCTAssertFalse(decoded.explicitSourceSelection, "explicitSourceSelection must not survive encode/decode")
    }

    func testAllSourceAccountIDsDerivesFromSourcesPrimaryFirst() {
        let item = MediaItem(id: "p1", title: "X", kind: .movie, sourceAccountID: "plex",
                             sources: [ref("plex", item: "p1"), ref("jelly", item: "j1")])
        XCTAssertEqual(item.allSourceAccountIDs, ["plex", "jelly"])
    }

    func testAllSourceAccountIDsFallsBackToLegacyFieldsWhenNoSources() {
        let item = MediaItem(id: "p1", title: "X", kind: .movie, sourceAccountID: "plex",
                             additionalSourceAccountIDs: ["jelly"])
        XCTAssertEqual(item.allSourceAccountIDs, ["plex", "jelly"])
    }

    func testHasMultipleSourcesTrueOnlyAcrossDistinctAccounts() {
        let single = MediaItem(id: "p", title: "X", kind: .movie,
                               sources: [ref("plex", item: "p"), ref("plex", item: "p")])
        XCTAssertFalse(single.hasMultipleSources)
        let multi = MediaItem(id: "p", title: "X", kind: .movie,
                              sources: [ref("plex", item: "p"), ref("jelly", item: "j")])
        XCTAssertTrue(multi.hasMultipleSources)
    }
}

final class EditionParserTests: XCTestCase {
    func testParsesEditionsFromReleaseNames() {
        XCTAssertEqual(EditionParser.edition(from: "Movie (2009) Extended Bluray-2160p"), "Extended")
        XCTAssertEqual(EditionParser.edition(from: "Blade.Runner.Final.Cut.1080p"), "Final Cut")
        XCTAssertEqual(EditionParser.edition(from: "Aliens Director's Cut"), "Director's Cut")
        XCTAssertEqual(EditionParser.edition(from: "Superman.II.The.Donner.Cut"), "Donner Cut")
        XCTAssertNil(EditionParser.edition(from: "Just A Plain Title 2160p"))
    }

    func testParsesSourceQuality() {
        XCTAssertEqual(EditionParser.sourceQuality(from: "Movie 2160p BluRay Remux"), "Remux")
        XCTAssertEqual(EditionParser.sourceQuality(from: "Movie.1080p.WEB-DL.DDP5.1"), "WEB-DL")
        XCTAssertEqual(EditionParser.sourceQuality(from: "Movie 720p HDTV"), "HDTV")
        XCTAssertNil(EditionParser.sourceQuality(from: "Movie 1080p"))
    }

    func testEditionLeadsDisplayLabelSoSameQualityFilesDiffer() {
        let extended = MediaVersion(id: "1", name: "Avatar (2009) Extended BluRay-2160p", height: 2160)
        let theatrical = MediaVersion(id: "2", name: "Avatar (2009) Theatrical BluRay-2160p", height: 2160)
        XCTAssertTrue(extended.displayLabel.hasPrefix("Extended"))
        XCTAssertTrue(theatrical.displayLabel.hasPrefix("Theatrical"))
        XCTAssertNotEqual(extended.displayLabel, theatrical.displayLabel,
                          "Two 4K BluRay files must be distinguishable by edition")
    }

    func testExplicitEditionWinsOverParsedName() {
        let v = MediaVersion(id: "1", name: "Movie Theatrical", edition: "Director's Cut", height: 2160)
        XCTAssertEqual(v.editionLabel, "Director's Cut")
        XCTAssertTrue(v.displayLabel.hasPrefix("Director's Cut"))
    }
}
