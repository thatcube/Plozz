import Foundation
import XCTest
@testable import CoreModels

final class MediaAliasRecordTests: XCTestCase {
    func testRepairsLegacyArcaneAnimeSearchContamination() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .series,
            strongEvidence: [
                strong(.series, .imdb, "tt11126994"),
                strong(.series, .tmdb, "94605"),
                strong(.series, .tvdb, "371028"),
                strong(.series, .aniDB, "12811"),
                strong(.series, .aniList, "104490"),
                strong(.series, .myAnimeList, "22385")
            ],
            weakEvidence: [
                weak(.series, "Arcane", 2021),
                weak(.series, "Arcane: League of Legends", 2002)
            ],
            presentation: MediaAliasPresentation(
                title: "Arcane: League of Legends",
                year: 2002,
                artworkURL: "https://anime.example/wrong-poster.jpg",
                backdropURL: "https://anime.example/wrong-backdrop.jpg"
            )
        ))

        XCTAssertEqual(
            Set(record.strongEvidence.map(\.namespace)),
            [.imdb, .tmdb, .tvdb]
        )
        XCTAssertEqual(record.weakEvidence.map(\.year), [2021])
        XCTAssertEqual(record.presentation?.year, 2021)
        XCTAssertNil(record.presentation?.artworkURL)
        XCTAssertNil(record.presentation?.backdropURL)
    }

    func testRepairsLegacyAndorAnimeSearchContamination() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .series,
            strongEvidence: [
                strong(.series, .imdb, "tt9253284"),
                strong(.series, .tmdb, "83867"),
                strong(.series, .tvdb, "393189"),
                strong(.series, .aniDB, "1482"),
                strong(.series, .aniList, "102451")
            ],
            weakEvidence: [weak(.series, "Andor", 2022)],
            presentation: MediaAliasPresentation(title: "Andor", year: 2022)
        ))

        XCTAssertEqual(
            Set(record.strongEvidence.map(\.namespace)),
            [.imdb, .tmdb, .tvdb]
        )
        XCTAssertEqual(record.presentation?.year, 2022)
    }

    func testRepairsDocumentedHouseOfTheDragonContamination() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .series,
            strongEvidence: [
                strong(.series, .imdb, "tt11198330"),
                strong(.series, .tmdb, "94997"),
                strong(.series, .tvdb, "371572"),
                strong(.series, .aniList, "112376")
            ],
            weakEvidence: [
                weak(.series, "House of the Dragon", 2022),
                weak(.series, "Dragon Goes House-Hunting", 2021)
            ],
            presentation: MediaAliasPresentation(
                title: "House of the Dragon",
                year: 2022
            )
        ))

        XCTAssertEqual(
            Set(record.strongEvidence.map(\.namespace)),
            [.imdb, .tmdb, .tvdb]
        )
        XCTAssertEqual(record.weakEvidence.map(\.year), [2022])
    }

    /// Every mainstream anchor is required. Two ids are not permission to strip
    /// anime evidence from a record that may genuinely be an anime adaptation.
    func testLegacyRepairRequiresAllThreeMainstreamAnchors() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .series,
            strongEvidence: [
                strong(.series, .imdb, "tt11126994"),
                strong(.series, .tmdb, "94605"),
                strong(.series, .aniList, "104490")
            ],
            weakEvidence: [weak(.series, "Arcane", 2021)],
            presentation: MediaAliasPresentation(title: "Arcane", year: 2021)
        ))

        XCTAssertTrue(
            record.strongEvidence.contains {
                $0.namespace == .aniList && $0.value == "104490"
            }
        )
    }

    func testMediaItemSnapshotRepairsIdentityWithoutDiscardingValidArtwork() throws {
        let poisoned = MediaItem(
            id: "4407",
            title: "Arcane: League of Legends",
            kind: .series,
            productionYear: 2002,
            posterURL: URL(
                string: "https://plex.example/library/metadata/4407/thumb/1"
            ),
            seriesPosterURL: URL(
                string: "https://plex.example/library/metadata/4407/thumb/1"
            ),
            backdropURL: URL(
                string: "https://plex.example/library/metadata/4407/art/1"
            ),
            heroBackdropURL: URL(
                string: "https://plex.example/library/metadata/4407/art/1"
            ),
            fallbackArtworkURL: URL(
                string: "https://plex.example/library/metadata/4407/art/1"
            ),
            logoURL: URL(
                string: "https://plex.example/library/metadata/4407/logo/1"
            ),
            ratings: [
                ExternalRating(
                    source: .anilist,
                    value: 70,
                    scale: .outOfHundred
                ),
                ExternalRating(
                    source: .imdb,
                    value: 8.5,
                    scale: .outOfTen
                )
            ],
            providerIDs: [
                "Imdb": "tt11126994",
                "Tmdb": "94605",
                "Tvdb": "371028",
                "AniList": "104490",
                "Mal": "22385",
                "AniDB": "12811"
            ],
            metadataProvenance: MetadataProvenance([
                .ratings: MetadataAttribution(source: .anilist)
            ]),
            artworkSelections: [
                ArtworkSelection(
                    placement: .homeHero,
                    references: [
                        .remote(
                            URL(
                                string:
                                    "https://plex.example"
                                    + "/library/metadata/4407/art/2"
                            )!
                        )
                    ]
                )
            ]
        )
        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONEncoder().encode(poisoned)
        )

        XCTAssertEqual(decoded.productionYear, 2021)
        XCTAssertNil(decoded.providerID(.aniList))
        XCTAssertNil(decoded.providerID(.myAnimeList))
        XCTAssertNil(decoded.providerID(.aniDB))
        XCTAssertEqual(decoded.providerID(.tmdb), "94605")
        XCTAssertEqual(decoded.posterURL, poisoned.posterURL)
        XCTAssertEqual(decoded.seriesPosterURL, poisoned.seriesPosterURL)
        XCTAssertEqual(decoded.backdropURL, poisoned.backdropURL)
        XCTAssertEqual(decoded.heroBackdropURL, poisoned.heroBackdropURL)
        XCTAssertEqual(
            decoded.fallbackArtworkURL,
            poisoned.fallbackArtworkURL
        )
        XCTAssertEqual(decoded.logoURL, poisoned.logoURL)
        XCTAssertEqual(decoded.artworkSelections, poisoned.artworkSelections)
        XCTAssertEqual(decoded.ratings.map(\.source), [.imdb])
        XCTAssertNil(decoded.metadataProvenance[.ratings])
    }

    func testMediaItemRepairDoesNotChangeAChildProductionYear() throws {
        let poisoned = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            productionYear: 2024,
            providerIDs: [
                "SeriesImdb": "tt11126994",
                "SeriesTmdb": "94605",
                "SeriesTvdb": "371028",
                "SeriesAniList": "104490"
            ]
        )
        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONEncoder().encode(poisoned)
        )

        XCTAssertEqual(decoded.productionYear, 2024)
        XCTAssertNil(decoded.providerID(.seriesAniList))
        XCTAssertEqual(decoded.providerID(.seriesTmdb), "94605")
    }

    func testLegacyRepairKeepsBaseAndSeriesIdentityScopesIndependent() {
        let mixedOnly = [
            "Imdb": "tt11126994",
            "SeriesTmdb": "94605",
            "SeriesTvdb": "371028"
        ]
        XCTAssertNil(
            LegacyAnimeIdentityRepair.expectedYear(
                providerIDs: mixedOnly,
                kind: .episode
            )
        )

        let bothScopes = [
            "Imdb": "tt9253284",
            "Tmdb": "83867",
            "Tvdb": "393189",
            "SeriesImdb": "tt11126994",
            "SeriesTmdb": "94605",
            "SeriesTvdb": "371028"
        ]
        XCTAssertEqual(
            LegacyAnimeIdentityRepair.expectedYear(
                providerIDs: bothScopes,
                kind: .episode
            ),
            2021
        )
        XCTAssertEqual(
            LegacyAnimeIdentityRepair.expectedYear(
                providerIDs: bothScopes,
                kind: .series
            ),
            2022
        )
    }

    func testMediaItemRepairDoesNotUseAPartialMixedScope() throws {
        let poisoned = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            productionYear: 2024,
            providerIDs: [
                "Imdb": "tt11126994",
                "SeriesTmdb": "94605",
                "SeriesTvdb": "371028",
                "SeriesAniList": "104490"
            ]
        )
        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONEncoder().encode(poisoned)
        )

        XCTAssertEqual(decoded.productionYear, 2024)
        XCTAssertEqual(decoded.providerID(.seriesAniList), "104490")
    }

    /// The bad ids are legitimate on the works they actually identify. The repair
    /// is anchored to all three mainstream IDs, never a global blacklist.
    func testDoesNotRemoveAnimeIDsFromTheirOwnWork() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .series,
            strongEvidence: [
                strong(.series, .aniDB, "12811"),
                strong(.series, .aniList, "104490"),
                strong(.series, .myAnimeList, "22385")
            ],
            weakEvidence: [weak(.series, "a_caFe", 2002)],
            presentation: MediaAliasPresentation(title: "a_caFe", year: 2002)
        ))

        XCTAssertEqual(record.strongEvidence.count, 3)
        XCTAssertEqual(record.presentation?.year, 2002)
    }

    func testIDSurvivesPresentationMutationAndCanonicalRoundTrip() throws {
        let id = MediaAliasID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        var record = try XCTUnwrap(MediaAliasRecord(
            id: id,
            kind: .movie,
            createdAt: Date(timeIntervalSince1970: 10),
            strongEvidence: [strong(.movie, .tmdb, " 278 ")],
            weakEvidence: [weak(.movie, "The Shawshank Redemption", 1994)],
            presentation: MediaAliasPresentation(
                title: "The Shawshank Redemption",
                year: 1994,
                artworkURL: "https://media.example/poster?api_key=secret"
            )
        ))

        record.presentation = MediaAliasPresentation(
            title: "Shawshank",
            year: 1995,
            artworkURL: "https://cdn.example/new.jpg"
        )
        record.updatedAt = Date(timeIntervalSince1970: 20)
        let bytes = try XCTUnwrap(record.canonicalData())
        let decoded = try JSONDecoder().decode(MediaAliasRecord.self, from: bytes)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.presentation?.title, "Shawshank")
        XCTAssertEqual(decoded.presentation?.year, 1995)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret"))
        XCTAssertEqual(bytes, decoded.canonicalData())
    }

    func testStrongEvidenceIsKindScoped() {
        let movie = strong(.movie, .tmdb, "123")
        let series = strong(.series, .tmdb, "123")

        XCTAssertNotEqual(movie, series)
        // The ledger scopes by kind through the `kind` field, exactly as the identity
        // index scopes its graph externally — one ruleset. There used to be a second,
        // unused `mediaIdentity` accessor here that baked the kind INTO the source
        // string (`"tmdb:movie"`), which would never have matched an index identity
        // (`"tmdb"`); it was deleted rather than harmonised, since nothing consumed it.
        XCTAssertEqual(movie.namespace, series.namespace)
        XCTAssertEqual(movie.value, series.value)
    }

    func testUnsupportedKindsCannotCreateAliasEvidenceOrRecord() {
        XCTAssertNil(MediaAliasStrongEvidence(kind: .episode, namespace: .tmdb, value: "1"))
        XCTAssertNil(MediaAliasWeakEvidence(kind: .season, title: "One", year: 2020))
        XCTAssertNil(MediaAliasEvidence(kind: .episode))
        XCTAssertNil(MediaAliasRecord(kind: .video))
    }

    func testMediaStateRecordKeyParsesDefaultColonProfileAndRejectsMalformed() {
        let id = MediaAliasID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let defaultKey = MediaStateRecordKey(
            profileID: "com.plozz.profile.default",
            aliasID: id
        )
        let colonKey = MediaStateRecordKey(
            profileID: "household:profile:two",
            aliasID: id
        )

        XCTAssertEqual(MediaStateRecordKey.parse(defaultKey.recordName), defaultKey)
        XCTAssertEqual(MediaStateRecordKey.parse(colonKey.recordName), colonKey)
        XCTAssertNil(MediaStateRecordKey.parse("profile:x:\(id)"))
        XCTAssertNil(MediaStateRecordKey.parse("alias::\(id)"))
        XCTAssertNil(MediaStateRecordKey.parse("alias:p:not-a-uuid"))
        XCTAssertNil(MediaStateRecordKey.parse("alias:p"))
        XCTAssertNil(SyncRecordKind(rawValue: "alias"))
    }

    func testAliasDTOCanonicalApplyRecaptureIsExactAndLocalValidationDoesNotSync() throws {
        let binding = try XCTUnwrap(MediaAliasProviderBindingKey(
            providerKind: .jellyfin,
            accountDescriptorID: "00000000-0000-0000-0000-000000000010",
            providerItemID: "item-7"
        ))
        let hint = MediaAliasProviderBindingHint(
            binding: binding,
            globalEvidence: [.external(source: "plexguid", value: "plex://movie/abc")],
            sourceValidation: .assertedBySource,
            observedAt: Date(timeIntervalSince1970: 30)
        )
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            createdAt: Date(timeIntervalSince1970: 10),
            strongEvidence: [strong(.movie, .imdb, "tt0111161")],
            presentation: MediaAliasPresentation(
                title: "Title",
                year: 1994,
                artworkURL: "https://user:password@192.168.1.2/poster?X-Plex-Token=TOKEN"
            ),
            bindingHints: [hint],
            locallyValidatedBindings: [binding]
        ))
        let dto = MediaAliasSyncDTO(record: record)
        let bytes = try XCTUnwrap(CanonicalJSON.encode(dto))
        let json = String(decoding: bytes, as: UTF8.self)

        XCTAssertFalse(json.contains("locallyValidated"))
        XCTAssertFalse(json.contains("TOKEN"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("serverName"))
        XCTAssertFalse(json.contains("userName"))
        XCTAssertFalse(json.contains("192.168.1.2"))

        let decoded = try XCTUnwrap(
            CanonicalJSON.decode(MediaAliasSyncDTO.self, from: bytes)
        )
        let applied = try XCTUnwrap(decoded.applying(to: record))
        XCTAssertEqual(applied.locallyValidatedBindings, [binding])
        XCTAssertEqual(
            CanonicalJSON.encode(MediaAliasSyncDTO(record: applied)),
            bytes
        )

        let fresh = try XCTUnwrap(decoded.applying(to: nil))
        XCTAssertTrue(fresh.locallyValidatedBindings.isEmpty)
    }

    func testAliasDTOOmitsNetworkBindingIdentifiersAndIdentityNames() throws {
        let unsafe = try XCTUnwrap(MediaAliasProviderBindingKey(
            providerKind: .mediaShare,
            accountDescriptorID: "share:smb://user@nas.local/Movies",
            providerItemID: "smb://nas.local/Movies/Film.mkv"
        ))
        let record = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            bindingHints: [MediaAliasProviderBindingHint(binding: unsafe)],
            locallyValidatedBindings: [unsafe]
        ))
        let json = String(
            decoding: CanonicalJSON.encode(MediaAliasSyncDTO(record: record))!,
            as: UTF8.self
        )

        XCTAssertFalse(json.contains("nas.local"))
        XCTAssertFalse(json.contains("user@"))
        XCTAssertFalse(json.contains("smb://"))
        XCTAssertFalse(json.contains("serverName"))
        XCTAssertFalse(json.contains("userName"))
    }

    func testRemoteProjectionPreservesReceiverLocalUnsafeBinding() throws {
        let localBinding = try XCTUnwrap(MediaAliasProviderBindingKey(
            providerKind: .mediaShare,
            accountDescriptorID: "share:smb://user@nas.local/Movies",
            providerItemID: "smb://nas.local/Movies/Film.mkv"
        ))
        let local = try XCTUnwrap(MediaAliasRecord(
            kind: .movie,
            strongEvidence: [strong(.movie, .tmdb, "1")],
            bindingHints: [MediaAliasProviderBindingHint(binding: localBinding)],
            locallyValidatedBindings: [localBinding]
        ))
        let remote = MediaAliasSyncDTO(record: try XCTUnwrap(MediaAliasRecord(
            id: local.id,
            kind: .movie,
            strongEvidence: [strong(.movie, .tmdb, "1")]
        )))

        let applied = try XCTUnwrap(remote.applying(to: local))

        XCTAssertEqual(applied.bindingHints.map(\.binding), [localBinding])
        XCTAssertEqual(applied.locallyValidatedBindings, [localBinding])
        XCTAssertFalse(
            String(
                decoding: CanonicalJSON.encode(MediaAliasSyncDTO(record: applied))!,
                as: UTF8.self
            ).contains("nas.local")
        )
    }

    func testProviderNamespaceCodablePreservesExistingCanonicalKey() throws {
        for namespace in ProviderIDNamespace.allCases {
            let data = try JSONEncoder().encode(namespace)
            XCTAssertEqual(try JSONDecoder().decode(ProviderIDNamespace.self, from: data), namespace)
            XCTAssertFalse(namespace.canonicalKey.isEmpty)
        }
    }

    func testAliasRecordSchemaContainsIdentityDataOnly() throws {
        let record = try XCTUnwrap(MediaAliasRecord(
            id: MediaAliasID(
                UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
            ),
            kind: .movie,
            strongEvidence: [strong(.movie, .tmdb, "1")],
            weakEvidence: [weak(.movie, "Title", 2020)],
            presentation: MediaAliasPresentation(title: "Title", year: 2020),
            redirectTarget: MediaAliasID(
                UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
            )
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: record.canonicalData()!)
                as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "bindingHints",
            "conflicts",
            "createdAt",
            "id",
            "kind",
            "locallyValidatedBindings",
            "presentation",
            "redirectTarget",
            "strongEvidence",
            "updatedAt",
            "weakEvidence",
        ])
        XCTAssertFalse(object.keys.contains("watchlist"))
        XCTAssertFalse(object.keys.contains("rating"))
        XCTAssertFalse(object.keys.contains("notes"))
    }

    private func strong(
        _ kind: MediaItemKind,
        _ namespace: ProviderIDNamespace,
        _ value: String
    ) -> MediaAliasStrongEvidence {
        MediaAliasStrongEvidence(kind: kind, namespace: namespace, value: value)!
    }

    private func weak(
        _ kind: MediaItemKind,
        _ title: String,
        _ year: Int
    ) -> MediaAliasWeakEvidence {
        MediaAliasWeakEvidence(kind: kind, title: title, year: year)!
    }
}
