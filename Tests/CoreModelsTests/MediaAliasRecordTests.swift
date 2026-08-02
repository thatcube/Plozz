import Foundation
import XCTest
@testable import CoreModels

final class MediaAliasRecordTests: XCTestCase {
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
        XCTAssertNotEqual(movie.mediaIdentity, series.mediaIdentity)
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
