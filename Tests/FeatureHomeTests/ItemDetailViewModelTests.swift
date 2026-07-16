import XCTest
import CoreModels
import MetadataKit
@testable import FeatureHome

@MainActor
final class ItemDetailViewModelTests: XCTestCase {
    private func series(_ id: String) -> MediaItem {
        MediaItem(id: id, title: "Avatar", kind: .series)
    }

    private func season(_ id: String, _ title: String) -> MediaItem {
        MediaItem(id: id, title: title, kind: .season, parentTitle: "Avatar")
    }

    private func episode(_ id: String, number: Int, resume: TimeInterval? = nil) -> MediaItem {
        MediaItem(id: id, title: "Episode \(number)", kind: .episode, episodeNumber: number, resumePosition: resume)
    }

    func testLoadFetchesSeasonsAsChildren() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water"), season("s2", "Book Two: Earth")]
        ]
        provider.allItems = [series("show")]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, "show")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["s1", "s2"])
    }

    func testAtmosProbeUpdatesBadgeAfterFirstPaint() async {
        let item = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                sourceRevision: "rev-1",
                audio: .init(codec: "eac3", channels: 6, channelLayout: "5.1")
            )
        )
        let provider = FakeMediaProvider(allItems: [item])
        let probeGate = AsyncGate()
        provider.supplementalFactsGate = { await probeGate.wait() }
        provider.supplementalFactsByItem["movie"] = ProbedStreamFacts(
            audioCodec: "eac3",
            audioChannels: 6,
            audioIsAtmos: true
        )
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "movie",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()
        XCTAssertEqual(vm.state.value?.item.mediaInfo?.audio?.profile, nil)

        probeGate.open()
        await waitUntil {
            vm.state.value?.item.mediaInfo?.audio?.profile == "Dolby Atmos"
        }

        XCTAssertEqual(provider.supplementalProbeCount, 1)
        XCTAssertEqual(
            vm.state.value?.item.technicalBadges.map(\.label),
            ["Dolby Atmos"]
        )
    }

    func testShareProbeCreatesAtmosMetadataWithoutServerStreamFacts() async {
        let item = MediaItem(
            id: "share-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "share",
            versions: [
                MediaVersion(
                    id: "Movies/Movie.mkv",
                    container: "mkv",
                    sourceItemID: "share-movie",
                    sourceAccountID: "share"
                )
            ]
        )
        let provider = FakeMediaProvider(allItems: [item], kind: .mediaShare)
        provider.supplementalFactsByItem[item.id] = ProbedStreamFacts(
            videoWidth: 3840,
            videoHeight: 2160,
            videoRangeType: "DOVI",
            videoCodec: "hevc",
            audioTrackID: 1,
            audioCodec: "eac3",
            audioChannels: 6,
            audioIsAtmos: true
        )
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: item.id,
            sourceAccountID: "share",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()
        await waitUntil {
            vm.state.value?.item.mediaInfo?.audio?.profile == "Dolby Atmos"
        }

        XCTAssertEqual(vm.state.value?.item.mediaInfo?.video?.videoRangeType, "DOVI")
        XCTAssertEqual(vm.state.value?.item.versions.first?.audioProfile, "Dolby Atmos")
        XCTAssertEqual(
            vm.state.value?.item.versions.first?.technicalBadges.map { $0.label },
            ["4K", "Dolby Vision", "Dolby Atmos"]
        )
    }

    func testAtmosProbeDoesNotRunWhenServerAlreadyReportsAtmos() async {
        let item = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                sourceRevision: "rev-1",
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6)
            )
        )
        let provider = FakeMediaProvider(allItems: [item])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "movie",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(provider.supplementalProbeCount, 0)
        XCTAssertEqual(vm.state.value?.item.mediaInfo?.audio?.profile, "Dolby Atmos")
    }

    func testConfirmedAtmosSurvivesRefreshForSameSourceRevision() async {
        let fresh = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                sourceRevision: "rev-1",
                audio: .init(codec: "eac3", channels: 6)
            )
        )
        var cached = fresh
        cached.mediaInfo?.audio?.profile = "Dolby Atmos"
        let provider = FakeMediaProvider(allItems: [fresh])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "movie",
            initialItem: cached,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(vm.state.value?.item.mediaInfo?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(provider.supplementalProbeCount, 0)
    }

    func testConfirmedAtmosIsDroppedWhenSourceRevisionChanges() async {
        let fresh = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                sourceRevision: "rev-2",
                audio: .init(codec: "eac3", channels: 6)
            )
        )
        var cached = fresh
        cached.mediaInfo?.sourceRevision = "rev-1"
        cached.mediaInfo?.audio?.profile = "Dolby Atmos"
        let provider = FakeMediaProvider(allItems: [fresh])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "movie",
            initialItem: cached,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()
        await waitUntil { provider.supplementalProbeCount == 1 }

        XCTAssertNil(vm.state.value?.item.mediaInfo?.audio?.profile)
    }

    func testSwitchingFromPlexToEmbyStartsEmbyAtmosProbe() async {
        let plexItem = MediaItem(
            id: "plex-movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                sourceRevision: "plex-rev",
                audio: .init(codec: "truehd", profile: "Dolby Atmos", channels: 8)
            ),
            sourceAccountID: "plex"
        )
        let embyItem = MediaItem(
            id: "emby-movie",
            title: "Movie",
            kind: .movie,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                sourceRevision: "emby-rev",
                audio: .init(codec: "eac3", channels: 6)
            ),
            sourceAccountID: "emby"
        )
        let plex = FakeMediaProvider(allItems: [plexItem], kind: .plex)
        let emby = FakeMediaProvider(allItems: [embyItem], kind: .emby)
        emby.supplementalFactsByItem["emby-movie"] = ProbedStreamFacts(
            audioCodec: "eac3",
            audioChannels: 6,
            audioIsAtmos: true
        )
        let vm = ItemDetailViewModel(
            provider: plex,
            itemID: "plex-movie",
            sourceAccountID: "plex",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(),
            initialSources: [
                MediaSourceRef(accountID: "plex", itemID: "plex-movie"),
                MediaSourceRef(accountID: "emby", itemID: "emby-movie")
            ],
            alternateProviderResolver: { $0 == "emby" ? emby : nil }
        )

        await vm.load()
        await vm.switchToSource(accountID: "emby")
        await waitUntil {
            vm.state.value?.item.mediaInfo?.audio?.profile == "Dolby Atmos"
        }

        XCTAssertEqual(vm.state.value?.item.id, "emby-movie")
        XCTAssertEqual(emby.supplementalProbeCount, 1)
        XCTAssertEqual(plex.supplementalProbeCount, 0)
        XCTAssertEqual(
            vm.sources.first { $0.accountID == "emby" }?.versions.first?.audioProfile,
            "Dolby Atmos"
        )
    }

    func testEnrichesAlternateSourcesAndUnifiesWatchState() async {
        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021,
                                sourceAccountID: "plex",
                                versions: [MediaVersion(id: "pv", height: 1080)])
        let alt = MediaItem(id: "j1", title: "Dune", kind: .movie, productionYear: 2021,
                            resumePosition: 300,
                            sourceAccountID: "jelly",
                            versions: [MediaVersion(id: "jv", height: 2160)],
                            lastPlayedAt: Date(timeIntervalSince1970: 1000))
        let provider = FakeMediaProvider(allItems: [primary, alt])
        let sources = [
            MediaSourceRef(accountID: "plex", itemID: "p1"),
            MediaSourceRef(accountID: "jelly", itemID: "j1")
        ]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "plex",
            initialSources: sources,
            alternateProviderResolver: { _ in provider }
        )

        await vm.load()
        await waitUntil {
            vm.sources.first { $0.accountID == "jelly" }?.versions.map(\.id) == ["jv"]
        }

        XCTAssertEqual(vm.sources.count, 2)
        XCTAssertEqual(vm.sources.first { $0.accountID == "plex" }?.versions.map(\.id), ["pv"],
                       "Primary source seeded with the loaded detail's own versions")
        let jelly = vm.sources.first { $0.accountID == "jelly" }
        XCTAssertEqual(jelly?.versions.map(\.id), ["jv"], "Alternate server's versions fetched off the critical path")
        XCTAssertEqual(jelly?.resumePosition, 300)
        XCTAssertEqual(vm.state.value?.item.resumePosition, 300,
                       "Detail hero reflects unified (newest-wins) progress from the alternate server")
    }

    func testLoadDoesNotWaitForAlternateSourceEnrichment() async {
        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021,
                                sourceAccountID: "plex",
                                versions: [MediaVersion(id: "pv", height: 1080)])
        let alt = MediaItem(id: "j1", title: "Dune", kind: .movie, productionYear: 2021,
                            resumePosition: 300,
                            sourceAccountID: "jelly",
                            versions: [MediaVersion(id: "jv", height: 2160)],
                            lastPlayedAt: Date(timeIntervalSince1970: 1000))
        let primaryProvider = FakeMediaProvider(allItems: [primary])
        let alternateProvider = FakeMediaProvider(allItems: [alt])
        let gate = AsyncGate()
        alternateProvider.itemGate = ["j1": { await gate.wait() }]
        let vm = ItemDetailViewModel(
            provider: primaryProvider,
            itemID: "p1",
            sourceAccountID: "plex",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(),
            initialSources: [
                MediaSourceRef(accountID: "plex", itemID: "p1"),
                MediaSourceRef(accountID: "jelly", itemID: "j1")
            ],
            alternateProviderResolver: { accountID in
                accountID == "jelly" ? alternateProvider : nil
            }
        )

        await vm.load()

        XCTAssertEqual(vm.sources.first { $0.accountID == "plex" }?.versions.map(\.id), ["pv"])
        XCTAssertEqual(
            vm.sources.first { $0.accountID == "jelly" }?.versions,
            [],
            "Alternate metadata should enrich off the critical path"
        )

        gate.open()
        await waitUntil {
            vm.sources.first { $0.accountID == "jelly" }?.versions.map(\.id) == ["jv"]
        }
        XCTAssertEqual(vm.state.value?.item.resumePosition, 300)
    }

    func testSingleSourceItemHasNoSourcePicker() async {
        let movie = MediaItem(id: "m1", title: "Arrival", kind: .movie, productionYear: 2016,
                              sourceAccountID: "plex")
        let provider = FakeMediaProvider(allItems: [movie])
        let vm = ItemDetailViewModel(provider: provider, itemID: "m1", sourceAccountID: "plex",
                                     initialSources: [MediaSourceRef(accountID: "plex", itemID: "m1")])
        await vm.load()
        XCTAssertTrue(vm.sources.isEmpty, "A single-server title carries no sources (no server picker)")
    }

    func testSeedSourcesPrunesInactiveAccountFromPicker() async {
        // A merged card built while three servers were enabled, but "gone" has
        // since signed out / been excluded from the active profile (its resolver
        // returns nil). The picker must seed only the two reachable servers.
        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021, sourceAccountID: "plex")
        let provider = FakeMediaProvider(allItems: [primary])
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "plex",
            initialSources: [
                MediaSourceRef(accountID: "plex", itemID: "p1"),
                MediaSourceRef(accountID: "jelly", itemID: "j1"),
                MediaSourceRef(accountID: "gone", itemID: "g1")
            ],
            alternateProviderResolver: { accountID in
                accountID == "jelly" ? provider : nil
            }
        )

        await vm.load()

        XCTAssertFalse(
            vm.sources.contains { $0.accountID == "gone" },
            "A source whose account is no longer active must be pruned from the picker"
        )
        XCTAssertTrue(vm.sources.contains { $0.accountID == "plex" }, "Active primary source retained")
        XCTAssertTrue(vm.sources.contains { $0.accountID == "jelly" }, "Other active source retained")
    }

    func testSeedSourcesDropsPickerWhenPruningLeavesOneServer() async {
        // Same card, but now only the primary survives pruning — the second server
        // is dead. That collapses to a single-server title: no picker.
        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021, sourceAccountID: "plex")
        let provider = FakeMediaProvider(allItems: [primary])
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "plex",
            initialSources: [
                MediaSourceRef(accountID: "plex", itemID: "p1"),
                MediaSourceRef(accountID: "gone", itemID: "g1")
            ],
            alternateProviderResolver: { _ in nil }
        )

        await vm.load()

        XCTAssertTrue(
            vm.sources.isEmpty,
            "Pruning to a single reachable server yields no picker (single-server contract)"
        )
    }

    func testOriginSourceAccountIDDefaultsNilForHomeAndSearchFlows() {
        let provider = FakeMediaProvider(allItems: [])
        let vm = ItemDetailViewModel(provider: provider, itemID: "m1", sourceAccountID: "plex")
        XCTAssertNil(vm.originSourceAccountID,
                     "Home/Search details carry no origin, so the picker defaults to the smart best version")
        XCTAssertFalse(vm.isLibraryOriginPinned)
    }

    func testOriginSourceAccountIDIsThreadedForLibraryOpenedItems() {
        // Items opened from a library tile carry the library's owning account as
        // the origin, so the cross-server picker defaults to that server.
        let provider = FakeMediaProvider(allItems: [])
        let vm = ItemDetailViewModel(provider: provider, itemID: "m1",
                                     sourceAccountID: "jelly", originSourceAccountID: "jelly")
        XCTAssertEqual(vm.originSourceAccountID, "jelly")
        XCTAssertTrue(vm.isLibraryOriginPinned,
                      "Playback from a source-specific library must remain on that source")
    }

    // MARK: - Initial locality preference (series server picking)

    func testMergedOpenLoadsFromLocalCopyWhenPrimaryIsRemote() async {
        // A merged series whose merge-primary is the REMOTE (sister's Tailscale)
        // server, with a same-LAN copy on another account. Opened from Home
        // (originSourceAccountID nil), the page must load from the LOCAL copy so
        // every episode streams locally — not from the remote merge-primary.
        let remoteShow = MediaItem(id: "r-show", title: "Avatar", kind: .series, sourceAccountID: "remote")
        let localShow = MediaItem(id: "l-show", title: "Avatar", kind: .series, sourceAccountID: "local")
        let remote = FakeMediaProvider(allItems: [remoteShow])
        remote.localityOverride = .remote
        let local = FakeMediaProvider(allItems: [localShow])
        local.localityOverride = .local

        let vm = ItemDetailViewModel(
            provider: remote, itemID: "r-show", sourceAccountID: "remote",
            initialSources: [
                MediaSourceRef(accountID: "remote", itemID: "r-show"),
                MediaSourceRef(accountID: "local", itemID: "l-show")
            ],
            alternateProviderResolver: { accountID in
                accountID == "local" ? local : (accountID == "remote" ? remote : nil)
            }
        )

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, "l-show",
                       "Merged open retargets onto the local copy before fetching")
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "local")
    }

    func testLibraryOpenKeepsItsServerEvenWhenRemote() async {
        // A deliberate library-tile browse (originSourceAccountID set) must stay on
        // that library's server even if another copy is more local — the user
        // chose that library.
        let remoteShow = MediaItem(id: "r-show", title: "Avatar", kind: .series, sourceAccountID: "remote")
        let localShow = MediaItem(id: "l-show", title: "Avatar", kind: .series, sourceAccountID: "local")
        let remote = FakeMediaProvider(allItems: [remoteShow])
        remote.localityOverride = .remote
        let local = FakeMediaProvider(allItems: [localShow])
        local.localityOverride = .local

        let vm = ItemDetailViewModel(
            provider: remote, itemID: "r-show", sourceAccountID: "remote",
            originSourceAccountID: "remote",
            initialSources: [
                MediaSourceRef(accountID: "remote", itemID: "r-show"),
                MediaSourceRef(accountID: "local", itemID: "l-show")
            ],
            alternateProviderResolver: { accountID in
                accountID == "local" ? local : (accountID == "remote" ? remote : nil)
            }
        )

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, "r-show",
                       "A library-tile open keeps its own server, locality notwithstanding")
    }

    func testLibraryOriginRetargetsMergedPrimaryToLibraryCopy() async {
        let jellyfinMovie = MediaItem(
            id: "jellyfin-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "jellyfin"
        )
        let plexMovie = MediaItem(
            id: "plex-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "plex"
        )
        let jellyfin = FakeMediaProvider(allItems: [jellyfinMovie])
        let plex = FakeMediaProvider(allItems: [plexMovie])
        let vm = ItemDetailViewModel(
            provider: jellyfin,
            itemID: jellyfinMovie.id,
            initialItem: jellyfinMovie,
            sourceAccountID: "jellyfin",
            originSourceAccountID: "plex",
            initialSources: [
                MediaSourceRef(accountID: "jellyfin", itemID: jellyfinMovie.id),
                MediaSourceRef(accountID: "plex", itemID: plexMovie.id)
            ],
            alternateProviderResolver: { accountID in
                accountID == "plex" ? plex : jellyfin
            }
        )

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, plexMovie.id)
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "plex")
        XCTAssertTrue(vm.isLibraryOriginPinned)
    }

    func testLibraryOriginWinsOverMoreLocalDetailSource() {
        let jellyfin = MediaSourceRef(
            accountID: "jellyfin",
            itemID: "jellyfin-movie",
            locality: .local
        )
        let plex = MediaSourceRef(
            accountID: "plex",
            itemID: "plex-movie",
            locality: .remote
        )

        let selected = preferredDetailSource(
            sourceOverride: nil,
            libraryOrigin: "plex",
            itemSourceAccountID: "plex",
            sources: [jellyfin, plex],
            serverChoices: [jellyfin, plex],
            capabilities: .detected()
        )

        XCTAssertEqual(
            selected?.accountID,
            "plex",
            "A source-specific library is authoritative even when another copy ranks as more local"
        )
    }

    func testSeriesWatchMutationCascadesToLoadedEpisodes() async {
        let series = MediaItem(id: "series", title: "Series", kind: .series)
        let season = MediaItem(id: "season", title: "Season 1", kind: .season)
        let episodes = [
            MediaItem(id: "episode-1", title: "One", kind: .episode),
            MediaItem(id: "episode-2", title: "Two", kind: .episode)
        ]
        let provider = FakeMediaProvider(allItems: [series, season] + episodes)
        provider.childrenByParent = [
            series.id: [season],
            season.id: episodes
        ]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: series.id,
            sourceAccountID: "jellyfin"
        )
        await vm.load()
        await vm.loadEpisodes(for: season.id)

        vm.applyWatchedState(
            MediaItemMutation(
                itemIDs: [series.id],
                scopedItemIDs: ["jellyfin:\(series.id)"],
                played: true
            )
        )

        XCTAssertTrue(vm.state.value?.item.isPlayed ?? false)
        XCTAssertTrue(vm.episodes(for: season.id)?.allSatisfy(\.isPlayed) ?? false)
    }

    func testSwitchToSourceIsNotOverriddenByInitialLocalityPreference() async {
        // After a user explicitly switches servers, a later load() must NOT re-apply
        // the automatic local-first preference and drag them back.
        let remoteShow = MediaItem(id: "r-show", title: "Avatar", kind: .series, sourceAccountID: "remote")
        let localShow = MediaItem(id: "l-show", title: "Avatar", kind: .series, sourceAccountID: "local")
        let remote = FakeMediaProvider(allItems: [remoteShow])
        remote.localityOverride = .remote
        let local = FakeMediaProvider(allItems: [localShow])
        local.localityOverride = .local

        let vm = ItemDetailViewModel(
            provider: local, itemID: "l-show", sourceAccountID: "local",
            initialSources: [
                MediaSourceRef(accountID: "local", itemID: "l-show"),
                MediaSourceRef(accountID: "remote", itemID: "r-show")
            ],
            alternateProviderResolver: { accountID in
                accountID == "local" ? local : (accountID == "remote" ? remote : nil)
            }
        )

        await vm.load()
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "local")

        await vm.switchToSource(accountID: "remote")
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "remote", "User switch takes effect")

        await vm.load()
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "remote",
                       "A subsequent load() must not re-apply the local-first preference over the user's pick")
    }

    func testMovieRetargetsToPreferredSourceAfterAsyncDiscovery() async {
        let remoteMovie = MediaItem(
            id: "remote-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "remote"
        )
        let localMovie = MediaItem(
            id: "local-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "local"
        )
        let remote = FakeMediaProvider(allItems: [remoteMovie])
        remote.localityOverride = .remote
        let local = FakeMediaProvider(allItems: [localMovie])
        local.localityOverride = .local
        let discovered = [
            MediaSourceRef(
                accountID: "remote",
                itemID: "remote-movie",
                locality: .remote
            ),
            MediaSourceRef(
                accountID: "local",
                itemID: "local-movie",
                locality: .local
            )
        ]
        let vm = ItemDetailViewModel(
            provider: remote,
            itemID: "remote-movie",
            sourceAccountID: "remote",
            initialSources: [discovered[0]],
            alternateProviderResolver: { accountID in
                accountID == "local" ? local : (accountID == "remote" ? remote : nil)
            },
            crossServerSourceResolver: { _ in discovered }
        )

        await vm.load()
        await waitUntil {
            vm.state.value?.item.id == "local-movie"
        }

        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "local")
    }

    func testLoadEpisodesFetchesAndCachesPerSeason() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water")],
            "s1": [episode("e1", number: 1), episode("e2", number: 2)]
        ]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        XCTAssertNil(vm.episodes(for: "s1"))

        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["e1", "e2"])
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)

        // Re-requesting a cached season does not hit the provider again.
        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)
    }

    func testConcurrentLoadEpisodesCoalescesAndAllCallersAwaitResult() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water")],
            "s1": [episode("e1", number: 1)]
        ]
        let gate = AsyncGate()
        provider.childrenGate = ["s1": { _ in await gate.wait() }]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        let first = Task { @MainActor in
            await vm.loadEpisodes(for: "s1")
        }
        await waitUntil { provider.childrenCallCount["s1"] == 1 }

        let secondStarted = LockedFlag()
        let secondReturned = LockedFlag()
        let second = Task { @MainActor in
            secondStarted.set()
            await vm.loadEpisodes(for: "s1")
            secondReturned.set()
        }
        await waitUntil { secondStarted.value }

        XCTAssertFalse(secondReturned.value, "A foreground caller must await the prewarm already in flight")
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)

        gate.open()
        await first.value
        await second.value

        XCTAssertTrue(secondReturned.value)
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["e1"])
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)
    }

    func testReloadRestartsInFlightSeasonAndItsWaitersReceiveReplacement() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = ["show": [season("s1", "Book One: Water")]]
        provider.childrenResponsesByParent = [
            "s1": [
                [episode("stale", number: 1)],
                [episode("fresh", number: 1)]
            ]
        ]
        let staleRequestGate = AsyncGate()
        let freshRequestGate = AsyncGate()
        provider.childrenGate = ["s1": { callNumber in
            switch callNumber {
            case 1:
                await staleRequestGate.wait()
            case 2:
                await freshRequestGate.wait()
            default:
                break
            }
        }]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        let originalReturned = LockedFlag()
        let originalLoad = Task { @MainActor in
            await vm.loadEpisodes(for: "s1")
            originalReturned.set()
        }
        await waitUntil { provider.childrenCallCount["s1"] == 1 }

        let reload = Task { @MainActor in
            await vm.reload()
        }
        await waitUntil { provider.childrenCallCount["s1"] == 2 }

        XCTAssertFalse(originalReturned.value, "The invalidated caller must await the replacement")
        XCTAssertNil(vm.episodes(for: "s1"))

        freshRequestGate.open()
        await waitUntil {
            originalReturned.value
                && vm.episodes(for: "s1")?.map(\.id) == ["fresh"]
        }
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["fresh"])

        staleRequestGate.open()
        await originalLoad.value
        await reload.value
        await Task.yield()

        XCTAssertEqual(provider.childrenCallCount["s1"], 2)
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["fresh"])
    }

    func testSuspendPreventsReloadInvalidatedWaiterFromRestartingLater() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = ["show": [season("s1", "Book One: Water")]]
        provider.childrenResponsesByParent = [
            "s1": [
                [episode("stale", number: 1)],
                [episode("replacement", number: 1)]
            ]
        ]
        let staleRequestGate = AsyncGate()
        let replacementRequestGate = AsyncGate()
        provider.childrenGate = ["s1": { callNumber in
            switch callNumber {
            case 1:
                await staleRequestGate.wait()
            case 2:
                await replacementRequestGate.wait()
            default:
                break
            }
        }]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        let originalReturned = LockedFlag()
        let originalLoad = Task { @MainActor in
            await vm.loadEpisodes(for: "s1")
            originalReturned.set()
        }
        await waitUntil { provider.childrenCallCount["s1"] == 1 }

        let reload = Task { @MainActor in
            await vm.reload()
        }
        await waitUntil { provider.childrenCallCount["s1"] == 2 }

        vm.suspendEnrichment()
        await waitUntil { originalReturned.value }
        XCTAssertNil(vm.episodes(for: "s1"))

        replacementRequestGate.open()
        staleRequestGate.open()
        await originalLoad.value
        await reload.value
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(provider.childrenCallCount["s1"], 2)
        XCTAssertNil(vm.episodes(for: "s1"))
    }

    func testLoadEpisodesTagsChildrenWithSourceAccount() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water")],
            "s1": [episode("e1", number: 1)]
        ]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show", sourceAccountID: "acct-7")
        await vm.load()
        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(vm.episodes(for: "s1")?.first?.sourceAccountID, "acct-7")
    }

    func testLoadEpisodesCachesEmptyOnFailure() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = ["show": [season("s1", "Book One: Water")]]
        // "s1" intentionally absent from childrenByParent → resolves to [].
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(vm.episodes(for: "s1"), [])
    }

    func testLoadFetchesTrailersTaggedWithSource() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem(id: "t1", title: "Trailer", kind: .video)]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            sourceAccountID: "acct-9",
            onlineTrailerResolver: { _ in [MediaItem.youTubeTrailer(videoID: "yt1", title: "online")] },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        // Local trailer is preferred over the online fallback, and stays tagged.
        XCTAssertEqual(vm.trailers.map(\.id), ["t1"])
        XCTAssertEqual(vm.trailers.first?.sourceAccountID, "acct-9")
        XCTAssertFalse(vm.trailers.first?.isYouTubeTrailer ?? true)
    }

    func testFallsBackToOnlineTrailerWhenNoLocal() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        // No local trailers configured → online fallback is used.
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            sourceAccountID: "acct-9",
            onlineTrailerResolver: { item in
                [MediaItem.youTubeTrailer(videoID: "yt1", title: "\(item.title) — Trailer")]
            },
            playableVideoIDResolver: { $0.first },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.map(\.youTubeTrailerVideoID), ["yt1"])
        // Online trailers are not tagged to an account — they route to YouTube.
        XCTAssertNil(vm.trailers.first?.sourceAccountID)
    }

    func testServerYouTubeTrailerIsStampedWithParentTitleAndYear() async {
        let provider = FakeMediaProvider(
            allItems: [MediaItem(id: "m1", title: "Mary Poppins Returns", kind: .movie, productionYear: 2018)]
        )
        // A server RemoteTrailers entry: a YouTube trailer with a generic name and
        // no parent title/year of its own — and which verifies as playable.
        provider.trailersByItem = ["m1": [
            MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")
        ]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { $0.first },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        // Stamped so a later replacement search has a clean title and year.
        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "serverID")
        XCTAssertEqual(vm.trailers.first?.parentTitle, "Mary Poppins Returns")
        XCTAssertEqual(vm.trailers.first?.productionYear, 2018)
        let subject = vm.trailers.first?.alternativeTrailerSearchSubject
        XCTAssertEqual(subject?.title, "Mary Poppins Returns")
        XCTAssertEqual(subject?.productionYear, 2018)
    }

    func testDeadServerTrailerFallsBackToVerifiedSearchResult() async {
        let provider = FakeMediaProvider(
            allItems: [MediaItem(id: "m1", title: "Mary Poppins Returns", kind: .movie, productionYear: 2018)]
        )
        // Server points at a now-private video that fails verification.
        provider.trailersByItem = ["m1": [
            MediaItem.youTubeTrailer(videoID: "deadID", title: "Trailer")
        ]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in
                [MediaItem.youTubeTrailer(videoID: "freshID", title: "Mary Poppins Returns — Trailer")]
            },
            // Dead server id doesn't verify; the searched replacement does.
            playableVideoIDResolver: { ids in ids.contains("deadID") ? nil : ids.first },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.map(\.youTubeTrailerVideoID), ["freshID"])
    }

    func testNoButtonWhenNothingVerifies() async {
        let provider = FakeMediaProvider(
            allItems: [MediaItem(id: "m1", title: "Mary Poppins Returns", kind: .movie, productionYear: 2018)]
        )
        provider.trailersByItem = ["m1": [
            MediaItem.youTubeTrailer(videoID: "deadID", title: "Trailer")
        ]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            // A replacement is found but it also fails to verify → no button.
            onlineTrailerResolver: { _ in
                [MediaItem.youTubeTrailer(videoID: "alsoDead", title: "Mary Poppins Returns — Trailer")]
            },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
    }

    func testLocalTrailerSkipsVerificationAndSearch() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem(id: "t1", title: "Trailer", kind: .video)]]
        let searchCalled = LockedFlag()
        let verifyCalled = LockedFlag()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in searchCalled.set(); return [] },
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.map(\.id), ["t1"])
        XCTAssertFalse(searchCalled.value, "Local trailer should not trigger an online search")
        XCTAssertFalse(verifyCalled.value, "Local trailer should not be verification-extracted")
    }

    func testLoadLeavesTrailersEmptyWhenNoLocalOrOnline() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
    }

    // MARK: - Fast button: optimistic surfacing + caching

    func testServerTrailerShowsButtonOptimisticallyBeforeVerification() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let gate = AsyncGate()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            // Verification blocks until released — modelling a slow network so the
            // button must appear before it finishes.
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { ids in await gate.wait(); return ids.first },
            trailerCache: TrailerResolutionCache()
        )

        let loadTask = Task { await vm.load() }
        // The button appears optimistically from the server id while the gated
        // verification is still suspended.
        await waitUntil { !vm.trailers.isEmpty }
        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "serverID")

        gate.open()
        await loadTask.value
        // The verified id (here the same) remains after the pass completes.
        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "serverID")
    }

    func testCachedWorkingOutcomeShowsButtonWithoutReResolving() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        cache.record(.working("cachedID"), for: "m1")
        let searchCalled = LockedFlag()
        let verifyCalled = LockedFlag()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in searchCalled.set(); return [] },
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "cachedID")
        XCTAssertFalse(verifyCalled.value, "A cached outcome should not re-verify")
        XCTAssertFalse(searchCalled.value, "A cached outcome should not re-search")
    }

    func testCachedNoneHidesButtonWithoutWork() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        cache.record(.none, for: "m1")
        let verifyCalled = LockedFlag()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
        XCTAssertFalse(verifyCalled.value, "A cached 'none' should not re-verify")
    }

    func testVerifiedOutcomeIsCachedForNextVisit() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { $0.first },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertEqual(cache.outcome(for: "m1"), .working("serverID"))
    }

    func testNoPlayableTrailerIsCachedAsNone() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "deadID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: cache
        )

        await vm.load()

        // NB: `.none` here must be the Outcome case, not Optional.none. Written as
        // a bare `.none`, Swift binds it to `Optional<Outcome>.none` (nil) and the
        // test silently checks the opposite of its intent. `.some(.none)` pins it to
        // a cached `Outcome.none`, which is the documented behavior: a verified
        // "no playable trailer" is memoized so a revisit hides the button instantly.
        XCTAssertEqual(cache.outcome(for: "m1"), .some(.none))
        XCTAssertTrue(vm.trailers.isEmpty)
    }

    /// BUG B reproducer: on a return visit the snapshot restore briefly
    /// populated the multi-source picker (primary + sibling), then the live
    /// `seedSources` clobbered it back to a single entry because
    /// `initialSources.count <= 1`. After the fix `seedSources` must NOT
    /// downgrade a richer set already on the model; it should re-stamp the
    /// primary entry and leave the sibling alone.
    func testSeedSourcesDoesNotClobberSnapshotRestoredSiblings() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-bugb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = DetailSnapshotCache(directory: tempDir)

        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021,
                                providerIDs: ["Tmdb": "438631"],
                                sourceAccountID: "jelly")
        let siblingRef = MediaSourceRef(accountID: "jelly", itemID: "p2",
                                        providerKind: .jellyfin,
                                        versions: [MediaVersion(id: "synth:p2", height: 2160,
                                                                sourceItemID: "p2",
                                                                sourceAccountID: "jelly")])
        let primaryRef = MediaSourceRef(accountID: "jelly", itemID: "p1",
                                        providerKind: .jellyfin,
                                        versions: [MediaVersion(id: "synth:p1", height: 720,
                                                                sourceItemID: "p1",
                                                                sourceAccountID: "jelly")])
        let snapshot = DetailSnapshotCache.Snapshot(
            item: primary, children: [], seasonEpisodes: [:],
            sources: [primaryRef, siblingRef]
        )
        await cache.store(snapshot, for: "jelly|p1")

        let provider = FakeMediaProvider(allItems: [primary])
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "jelly",
            initialSources: [primaryRef], // only one — same as a typical revisit
            snapshotCache: cache
        )
        await vm.load()
        // Allow the snapshot restore task to land if it hasn't already.
        await waitUntil { vm.sources.count == 2 }

        XCTAssertEqual(vm.sources.count, 2,
                       "Snapshot-restored siblings must NOT be clobbered by seedSources")
        XCTAssertEqual(Set(vm.sources.map(\.itemID)), ["p1", "p2"])
    }

    func testUnchangedDiscoveryRetargetsSnapshotRestoredMovieSource() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-atmos-source-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = DetailSnapshotCache(directory: tempDir)
        let remoteMovie = MediaItem(
            id: "remote-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "remote"
        )
        let localMovie = MediaItem(
            id: "local-movie",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "local"
        )
        let restoredSources = [
            MediaSourceRef(
                accountID: "remote",
                itemID: "remote-movie",
                locality: .remote
            ),
            MediaSourceRef(
                accountID: "local",
                itemID: "local-movie",
                locality: .local
            )
        ]
        await cache.store(
            DetailSnapshotCache.Snapshot(
                item: remoteMovie,
                children: [],
                seasonEpisodes: [:],
                sources: restoredSources
            ),
            for: "remote|remote-movie"
        )
        let remote = FakeMediaProvider(allItems: [remoteMovie])
        remote.localityOverride = .remote
        let local = FakeMediaProvider(allItems: [localMovie])
        local.localityOverride = .local
        let discoveryGate = AsyncGate()
        let vm = ItemDetailViewModel(
            provider: remote,
            itemID: "remote-movie",
            sourceAccountID: "remote",
            initialSources: [restoredSources[0]],
            alternateProviderResolver: { accountID in
                accountID == "local" ? local : (accountID == "remote" ? remote : nil)
            },
            crossServerSourceResolver: { _ in
                await discoveryGate.wait()
                return restoredSources
            },
            snapshotCache: cache
        )

        await vm.load()
        await waitUntil { vm.sources.count == 2 }
        discoveryGate.open()
        await waitUntil { vm.state.value?.item.id == "local-movie" }

        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "local")
    }

    /// Disabling a server (its account is excluded from the active profile, so
    /// `alternateProviderResolver` returns nil for it) must drop that server from
    /// the picker even when it lingers in an on-disk snapshot persisted while the
    /// server was still enabled. The same-account sibling is always kept, so once
    /// the restore lands the picker settles to exactly the live entries.
    func testSnapshotRestoreDropsDisabledServerSources() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-disabled-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = DetailSnapshotCache(directory: tempDir)

        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021,
                                providerIDs: ["Tmdb": "438631"],
                                sourceAccountID: "jelly")
        let primaryRef = MediaSourceRef(accountID: "jelly", itemID: "p1", providerKind: .jellyfin)
        let sameAccountSibling = MediaSourceRef(accountID: "jelly", itemID: "p2", providerKind: .jellyfin)
        let disabledServerSibling = MediaSourceRef(accountID: "plex", itemID: "p3", providerKind: .plex)
        let snapshot = DetailSnapshotCache.Snapshot(
            item: primary, children: [], seasonEpisodes: [:],
            sources: [primaryRef, sameAccountSibling, disabledServerSibling]
        )
        await cache.store(snapshot, for: "jelly|p1")

        let provider = FakeMediaProvider(allItems: [primary])
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "jelly",
            initialSources: [primaryRef], // typical revisit: only the primary
            // "plex" has been disabled in the active profile → no provider.
            alternateProviderResolver: { $0 == "plex" ? nil : provider },
            snapshotCache: cache
        )
        await vm.load()
        // The same-account sibling survives, so the picker settles to exactly 2.
        await waitUntil { vm.sources.count == 2 }

        XCTAssertEqual(Set(vm.sources.map(\.itemID)), ["p1", "p2"],
                       "Disabled server's source must be pruned from the restored picker")
        XCTAssertFalse(vm.sources.contains { $0.accountID == "plex" },
                       "No source from the disabled (plex) account should remain")
    }

    /// Control for the above: while the server is still enabled (its account
    /// resolves a provider) the cross-server sibling stays in the restored picker,
    /// proving the prune targets only disabled accounts and never over-prunes.
    func testSnapshotRestoreKeepsEnabledCrossServerSources() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-enabled-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = DetailSnapshotCache(directory: tempDir)

        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, sourceAccountID: "jelly")
        let primaryRef = MediaSourceRef(accountID: "jelly", itemID: "p1", providerKind: .jellyfin)
        let crossServerSibling = MediaSourceRef(accountID: "plex", itemID: "p3", providerKind: .plex)
        let snapshot = DetailSnapshotCache.Snapshot(
            item: primary, children: [], seasonEpisodes: [:],
            sources: [primaryRef, crossServerSibling]
        )
        await cache.store(snapshot, for: "jelly|p1")

        let provider = FakeMediaProvider(allItems: [primary])
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "jelly",
            initialSources: [primaryRef],
            alternateProviderResolver: { _ in provider }, // all accounts enabled
            snapshotCache: cache
        )
        await vm.load()
        await waitUntil { vm.sources.count == 2 }

        XCTAssertEqual(Set(vm.sources.map(\.accountID)), ["jelly", "plex"],
                       "Enabled cross-server source must remain in the restored picker")
    }

    func testSnapshotRestoredEpisodesRefreshLiveWatchStateOnSeasonOpen() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-watch-refresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = DetailSnapshotCache(directory: tempDir)

        let show = series("show")
        let seasonItem = season("season-2", "Season 2")
        var staleEpisode = episode("episode-1", number: 1)
        staleEpisode.isPlayed = false
        var liveEpisode = staleEpisode
        liveEpisode.isPlayed = true
        let snapshot = DetailSnapshotCache.Snapshot(
            item: show.taggingSource("share"),
            children: [seasonItem.taggingSource("share")],
            seasonEpisodes: [
                seasonItem.id: [staleEpisode.taggingSource("share")]
            ]
        )
        await cache.store(snapshot, for: "share|show")

        let provider = FakeMediaProvider(allItems: [show, seasonItem, liveEpisode])
        provider.childrenByParent = [
            show.id: [seasonItem],
            seasonItem.id: [liveEpisode]
        ]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: show.id,
            sourceAccountID: "share",
            snapshotCache: cache
        )
        await vm.load()
        await waitUntil { vm.episodes(for: seasonItem.id) != nil }
        XCTAssertEqual(vm.episodes(for: seasonItem.id)?.first?.isPlayed, false)

        await vm.loadEpisodes(for: seasonItem.id)

        XCTAssertEqual(vm.episodes(for: seasonItem.id)?.first?.isPlayed, true)
        XCTAssertGreaterThanOrEqual(
            provider.childrenCallCount[seasonItem.id, default: 0],
            1,
            "A cached episode rail must still refresh live watch state"
        )
    }

    /// The Plex episode-badge bug: a season's `/children` listing can return a
    /// trimmed, SDR-looking episode (no per-stream DoVi/HDR, no Media-level Atmos
    /// hint), while the full per-item fetch carries the real 4K Dolby Vision /
    /// HDR10 / Atmos facts. The focused-episode hero must enrich from the full
    /// fetch and update the cached rail entry in place.
    func testFocusedEpisodeBadgesEnrichFromFullItemFetch() async {
        let sparse = MediaItem(
            id: "e1", title: "The End", kind: .episode, episodeNumber: 1,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "SDR"),
                audio: .init(codec: "eac3", profile: "Dolby Digital+", channels: 6, channelLayout: "5.1")
            )
        )
        let rich = MediaItem(
            id: "e1", title: "The End", kind: .episode, episodeNumber: 1,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6, channelLayout: "5.1")
            )
        )
        let provider = FakeMediaProvider(allItems: [series("show"), rich])
        provider.childrenByParent = ["show": [season("s1", "Season 1")], "s1": [sparse]]

        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()
        await vm.loadEpisodes(for: "s1")

        // Pre-enrichment the rail entry badges from the sparse listing: SDR, no DoVi/Atmos.
        let before = vm.seasonEpisodes["s1"]?.first?.technicalBadges.map(\.label) ?? []
        XCTAssertFalse(before.contains("Dolby Vision"))
        XCTAssertFalse(before.contains("Dolby Atmos"))

        let enriched = await vm.enrichEpisodeBadgesIfNeeded(sparse)
        XCTAssertEqual(enriched?.technicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Atmos", "HDR10"],
                       "Focused episode must badge from the full fetch's real metadata")
        // The cached rail entry is updated in place so the rail re-renders too.
        XCTAssertEqual(vm.seasonEpisodes["s1"]?.first?.technicalBadges.map(\.label),
                       ["4K", "Dolby Vision", "Dolby Atmos", "HDR10"])
    }

    /// Enrichment is idempotent: a second focus of the same episode returns the
    /// already-rich cached copy without a second provider fetch.
    func testEpisodeBadgeEnrichmentIsCachedPerEpisode() async {
        let rich = MediaItem(
            id: "e1", title: "The End", kind: .episode, episodeNumber: 1,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6)
            )
        )
        let sparse = MediaItem(id: "e1", title: "The End", kind: .episode, episodeNumber: 1)
        let provider = FakeMediaProvider(allItems: [series("show"), rich])
        provider.childrenByParent = ["show": [season("s1", "Season 1")], "s1": [sparse]]

        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()
        await vm.loadEpisodes(for: "s1")

        _ = await vm.enrichEpisodeBadgesIfNeeded(sparse)
        let firstCount = provider.itemCallCount(for: "e1")
        let second = await vm.enrichEpisodeBadgesIfNeeded(sparse)
        XCTAssertEqual(provider.itemCallCount(for: "e1"), firstCount,
                       "A re-focus must not trigger a second item fetch")
        XCTAssertTrue(second?.technicalBadges.map(\.label).contains("Dolby Vision") ?? false)
    }

    func testResolvedArtworkMergePreservesConcurrentBadgeEnrichment() async {
        let sparse = MediaItem(id: "e1", title: "The End", kind: .episode, episodeNumber: 1)
        let rich = MediaItem(
            id: "e1", title: "The End", kind: .episode, episodeNumber: 1,
            mediaInfo: MediaSourceMetadata(
                container: "mkv",
                video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6)
            )
        )
        let provider = FakeMediaProvider(allItems: [series("show"), rich])
        provider.childrenByParent = ["show": [season("s1", "Season 1")], "s1": [sparse]]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()
        await vm.loadEpisodes(for: "s1")
        _ = await vm.enrichEpisodeBadgesIfNeeded(sparse)

        let posterURL = URL(string: "https://example.com/e1.jpg")!
        vm.mergeResolvedEpisodePosterURLs(["e1": posterURL], for: "s1")

        let cached = vm.episodes(for: "s1")?.first
        XCTAssertEqual(cached?.posterURL, posterURL)
        XCTAssertTrue(cached?.technicalBadges.map(\.label).contains("Dolby Vision") ?? false)
        XCTAssertTrue(cached?.technicalBadges.map(\.label).contains("Dolby Atmos") ?? false)
    }

    // MARK: - In-place cross-server switch (Problem 4)

    /// Switching a series to another server's copy in place re-points the page to
    /// that server's item, reloads its seasons, keeps the cross-server picker
    /// intact, and tags the hero with the new active account — all without any
    /// navigation, so the back stack never grows.
    func testSwitchToSourceRepointsSeriesInPlace() async {
        let provider = FakeMediaProvider(allItems: [series("showA"), series("showB")])
        provider.childrenByParent = [
            "showA": [season("a-s1", "Season 1")],
            "showB": [season("b-s1", "Season 1")],
            "a-s1": [episode("a-e1", number: 1)],
            "b-s1": [episode("b-e1", number: 1)],
        ]
        let sources = [
            MediaSourceRef(accountID: "jelly", itemID: "showA"),
            MediaSourceRef(accountID: "plex", itemID: "showB"),
        ]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "showA", sourceAccountID: "jelly",
            initialSources: sources,
            alternateProviderResolver: { _ in provider }
        )

        await vm.load()
        XCTAssertEqual(vm.state.value?.item.id, "showA")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["a-s1"])

        await vm.switchToSource(accountID: "plex")

        XCTAssertEqual(vm.state.value?.item.id, "showB", "Page re-points to the other server's series")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["b-s1"], "Reloads the new server's seasons")
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "plex", "Hero tagged with the new active account")
        XCTAssertEqual(Set(vm.sources.map(\.accountID)), ["jelly", "plex"], "Cross-server picker stays intact")

        await vm.loadEpisodes(for: "a-s1")
        XCTAssertNil(provider.childrenCallCount["a-s1"], "An obsolete season id must not reach the replacement source")

        await vm.loadEpisodes(for: "b-s1")
        XCTAssertEqual(vm.episodes(for: "b-s1")?.map(\.id), ["b-e1"], "Episodes come from the new server")
    }

    func testInitialLoadCannotOverwriteAnExplicitSourceSwitch() async {
        let primary = FakeMediaProvider(allItems: [series("showA")])
        primary.childrenByParent = ["showA": [season("a-s1", "Season A")]]
        let primaryChildrenGate = AsyncGate()
        primary.childrenGate = ["showA": { _ in await primaryChildrenGate.wait() }]

        let alternate = FakeMediaProvider(allItems: [series("showB")])
        alternate.childrenByParent = ["showB": [season("b-s1", "Season B")]]
        let vm = ItemDetailViewModel(
            provider: primary,
            itemID: "showA",
            sourceAccountID: "jelly",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            initialSources: [
                MediaSourceRef(accountID: "jelly", itemID: "showA"),
                MediaSourceRef(accountID: "plex", itemID: "showB")
            ],
            alternateProviderResolver: { accountID in
                accountID == "plex" ? alternate : primary
            }
        )

        let initialLoad = Task { @MainActor in
            await vm.load()
        }
        await waitUntil { primary.childrenCallCount["showA"] == 1 }

        await vm.switchToSource(accountID: "plex")
        XCTAssertEqual(vm.state.value?.item.id, "showB")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["b-s1"])

        primaryChildrenGate.open()
        await initialLoad.value

        XCTAssertEqual(vm.state.value?.item.id, "showB")
        XCTAssertEqual(vm.state.value?.item.sourceAccountID, "plex")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["b-s1"])
    }

    func testResumeDuringSourceSwitchCannotLoadAnOldSeasonFromNewProvider() async {
        let primary = FakeMediaProvider(allItems: [series("showA")])
        primary.childrenByParent = ["showA": [season("a-s1", "Season A")]]
        let alternate = FakeMediaProvider(allItems: [series("showB")])
        alternate.childrenByParent = [
            "showB": [season("b-s1", "Season B")],
            "b-s1": [episode("b-e1", number: 1)]
        ]
        let alternateItemGate = AsyncGate()
        alternate.itemGate = ["showB": { await alternateItemGate.wait() }]
        let vm = ItemDetailViewModel(
            provider: primary,
            itemID: "showA",
            sourceAccountID: "jelly",
            originSourceAccountID: "jelly",
            initialSources: [
                MediaSourceRef(accountID: "jelly", itemID: "showA"),
                MediaSourceRef(accountID: "plex", itemID: "showB")
            ],
            alternateProviderResolver: { accountID in
                accountID == "plex" ? alternate : primary
            }
        )
        await vm.load()

        let sourceSwitch = Task { @MainActor in
            await vm.switchToSource(accountID: "plex")
        }
        await waitUntil { alternate.itemCallCount(for: "showB") >= 2 }

        vm.resumeEnrichmentIfNeeded()
        await vm.loadEpisodes(for: "a-s1")
        XCTAssertNil(alternate.childrenCallCount["a-s1"])

        alternateItemGate.open()
        await sourceSwitch.value
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["b-s1"])
    }

    /// Switching to the already-active server, an unknown account, or one with no
    /// alternate provider is a no-op (so re-picking the current server can't
    /// reload or disturb the page).
    func testSwitchToSourceNoOps() async {
        let provider = FakeMediaProvider(allItems: [series("showA"), series("showB")])
        provider.childrenByParent = ["showA": [season("a-s1", "Season 1")], "showB": []]
        let sources = [
            MediaSourceRef(accountID: "jelly", itemID: "showA"),
            MediaSourceRef(accountID: "plex", itemID: "showB"),
        ]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "showA", sourceAccountID: "jelly",
            initialSources: sources,
            alternateProviderResolver: { $0 == "plex" ? provider : nil }
        )
        await vm.load()

        await vm.switchToSource(accountID: "jelly")
        XCTAssertEqual(vm.state.value?.item.id, "showA", "Re-picking the active server is a no-op")

        await vm.switchToSource(accountID: "unknown")
        XCTAssertEqual(vm.state.value?.item.id, "showA", "Unknown account is a no-op")

        XCTAssertTrue(vm.canSwitchToSource(accountID: "plex"))
        XCTAssertFalse(vm.canSwitchToSource(accountID: "jelly"))
        XCTAssertFalse(vm.canSwitchToSource(accountID: "unknown"))
    }


    /// of yields elapse), so a test can observe an optimistic state set before a
    /// later `await` resumes.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met before timeout")
    }

    // MARK: - Hero-first paint (TTFP: don't gate the hero on children/trailers)

    func testHeroPaintsImmediatelyForLeafKinds() async {
        // For movies/episodes there are no children, so the loaded state should
        // appear the moment `item` is fetched.
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, "m1")
        XCTAssertEqual(vm.state.value?.children, [])
    }

    func testSeriesPublishesHeroThenFillsChildren() async {
        // Current detail loading intentionally paints the full series hero before
        // a potentially slow remote children request. SeriesDetailView observes the
        // season-id list and re-latches selection/Play when children arrive.
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = [
            "show": [season("s1", "Book One"), season("s2", "Book Two")]
        ]
        let gate = AsyncGate()
        provider.childrenGate = ["show": { _ in await gate.wait() }]

        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "show",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        let loadTask = Task { await vm.load() }

        await waitUntil { vm.state.value?.item.id == "show" }
        XCTAssertEqual(vm.state.value?.item.id, "show")
        XCTAssertTrue(vm.state.value?.children.isEmpty ?? false)
        XCTAssertEqual(vm.state.value?.childrenLoaded, false)

        // Release the gate; the same page fills its season list in place.
        gate.open()
        await loadTask.value
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["s1", "s2"])
        XCTAssertFalse(vm.state.value?.children.isEmpty ?? true)
    }

    // MARK: - initialItem seeding (instant first paint from the tapped list item)

    func testInitialItemSeedsLoadedStateBeforeLoad() async {
        // Constructing the VM with the tapped list item must paint a hero
        // *immediately* — before `load()` and before any network call returns.
        let listItem = MediaItem(id: "m1", title: "Dune", kind: .movie)
        let provider = FakeMediaProvider(allItems: [
            MediaItem(id: "m1", title: "Dune: Part Two", kind: .movie)
        ])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            initialItem: listItem,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        // Seeded synchronously in init.
        XCTAssertEqual(vm.state.value?.item.id, "m1")
        XCTAssertEqual(vm.state.value?.item.title, "Dune")

        await vm.load()

        // After load() the fully-detailed item replaces the seeded one in place.
        XCTAssertEqual(vm.state.value?.item.id, "m1")
        XCTAssertEqual(vm.state.value?.item.title, "Dune: Part Two")
    }

    func testSeededHeroIsNeverReplacedByLoadingState() async {
        // A seeded hero must not flash back to a full-screen loading/skeleton
        // state while the detail re-fetch is in flight: load() observes a gated
        // children fetch but the seeded hero stays loaded throughout.
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = ["show": [season("s1", "Book One")]]
        let gate = AsyncGate()
        provider.childrenGate = ["show": { _ in await gate.wait() }]

        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "show",
            initialItem: series("show"),
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        let loadTask = Task { await vm.load() }
        // Throughout the gated load the state is continuously `.loaded` — never
        // `.loading`/`.idle`/`.failed`.
        for _ in 0..<50 {
            XCTAssertNotNil(vm.state.value, "Seeded hero must stay loaded during re-fetch")
            await Task.yield()
        }
        gate.open()
        await loadTask.value
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["s1"])
    }

    func testSeededHeroSurvivesDetailFetchFailure() async {
        // If the detail re-fetch fails, a seeded hero must remain usable rather
        // than being buried under a full-screen error.
        let provider = FakeMediaProvider(allItems: []) // item(id:) throws .notFound
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            initialItem: MediaItem(id: "m1", title: "Dune", kind: .movie),
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, "m1")
        if case .failed = vm.state {
            XCTFail("Seeded hero must not be replaced by a full-screen error")
        }
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` is called (or returns
/// immediately if already open). Lets a test hold an injected async closure at a
/// known suspension point to observe intermediate view-model state.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A tiny thread-safe boolean flag for asserting whether an injected async
/// closure was invoked.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
final class ThemeMusicSourceResolutionTests: XCTestCase {
    func testAuthenticatedThemeResolvesAtPlaybackBoundary() async throws {
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .plex,
            accountID: "account",
            credentialRevision: CredentialRevision(rawValue: UUID()),
            itemID: "movie",
            deliveryMode: .directFile,
            purpose: .themeMusic,
            resource: try AuthenticatedHTTPResource(
                pathBase: .serverRoot,
                path: "/library/metadata/movie/theme/1"
            )
        )
        let theme = ThemeMusic(
            itemID: "movie",
            playbackSource: .authenticatedHTTP(locator)
        )
        let expected = URL(
            string: "https://plex.example/library/metadata/movie/theme/1?X-Plex-Token=secret"
        )!
        let resolver = ThemeMusicResolverStub(url: expected)

        let result = try await resolveThemeMusicURL(
            theme,
            authenticatedHTTPResolver: resolver
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(resolver.locator, locator)
    }

    func testPublicThemeDoesNotRequireAuthenticatedResolver() async throws {
        let expected = URL(string: "https://themes.example/movie.mp3")!
        let theme = ThemeMusic(
            itemID: "movie",
            playbackSource: .publicURL(
                try SecretFreeURLSource(url: expected)
            )
        )

        let result = try await resolveThemeMusicURL(
            theme,
            authenticatedHTTPResolver: nil
        )

        XCTAssertEqual(result, expected)
    }
}

@MainActor
private final class ThemeMusicResolverStub:
    AuthenticatedHTTPResourceResolving
{
    let url: URL
    private(set) var locator: AuthenticatedHTTPPlaybackLocator?

    init(url: URL) {
        self.url = url
    }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        self.locator = locator
        return url
    }
}
