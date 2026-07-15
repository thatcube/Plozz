import XCTest
import CoreModels
@testable import SearchIndexKit

final class SearchIndexCoordinatorTests: XCTestCase {
    private struct OnePageProvider: SearchCatalogProviding {
        let items: [MediaItem]

        func searchCatalogPage(
            _ request: SearchCatalogPageRequest
        ) async throws -> SearchCatalogPage {
            SearchCatalogPage(
                records: items.map(SearchCatalogRecord.init(item:)),
                nextCursor: nil,
                totalCount: items.count
            )
        }
    }

    private struct FakeEmbedding: SentenceEmbeddingProviding {
        let descriptor = EmbeddingModelDescriptor(
            language: .english,
            revision: 1,
            dimension: 3
        )
        func descriptor(for language: EmbeddingLanguage) async
            -> EmbeddingModelDescriptor? {
            language == .english ? descriptor : nil
        }
        func vector(
            for text: String,
            using descriptor: EmbeddingModelDescriptor
        ) async -> [Float]? {
            text.contains("restaurant") ? [1, 0, 0] : [0, 1, 0]
        }
    }

    private actor BlockingFirstEmbedding: SentenceEmbeddingProviding {
        private let model = EmbeddingModelDescriptor(
            language: .english,
            revision: 1,
            dimension: 3
        )
        private var shouldBlockFirstDescriptor = true
        private var descriptorStartedWaiters: [CheckedContinuation<Void, Never>] = []
        private var descriptorRelease: CheckedContinuation<Void, Never>?

        func descriptor(for language: EmbeddingLanguage) async
            -> EmbeddingModelDescriptor? {
            guard language == .english else { return nil }
            if shouldBlockFirstDescriptor {
                shouldBlockFirstDescriptor = false
                descriptorStartedWaiters.forEach { $0.resume() }
                descriptorStartedWaiters.removeAll()
                await withCheckedContinuation { descriptorRelease = $0 }
            }
            return model
        }

        func vector(
            for text: String,
            using descriptor: EmbeddingModelDescriptor
        ) async -> [Float]? {
            text.contains("restaurant") ? [1, 0, 0] : [0, 1, 0]
        }

        func waitUntilFirstDescriptorStarts() async {
            guard shouldBlockFirstDescriptor else { return }
            await withCheckedContinuation {
                descriptorStartedWaiters.append($0)
            }
        }

        func releaseFirstDescriptor() {
            descriptorRelease?.resume()
            descriptorRelease = nil
        }
    }

    private actor BlockingPageProvider: SearchCatalogProviding {
        private let item: MediaItem
        private var requestStarted = false
        private var requestStartedWaiters: [CheckedContinuation<Void, Never>] = []
        private var requestRelease: CheckedContinuation<Void, Never>?

        init(item: MediaItem) {
            self.item = item
        }

        func searchCatalogPage(
            _ request: SearchCatalogPageRequest
        ) async throws -> SearchCatalogPage {
            requestStarted = true
            requestStartedWaiters.forEach { $0.resume() }
            requestStartedWaiters.removeAll()
            await withCheckedContinuation { requestRelease = $0 }
            return SearchCatalogPage(
                records: [SearchCatalogRecord(item: item)],
                nextCursor: nil,
                totalCount: 1
            )
        }

        func waitUntilRequestStarts() async {
            guard !requestStarted else { return }
            await withCheckedContinuation {
                requestStartedWaiters.append($0)
            }
        }

        func releaseRequest() {
            requestRelease?.resume()
            requestRelease = nil
        }
    }

    private struct EnglishDetector: SearchLanguageDetecting {
        func hypotheses(for text: String, maximumCount: Int) async
            -> [EmbeddingLanguage] {
            maximumCount > 0 ? [.english] : []
        }
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testReconcileBuildsAndSearchesActiveProfile() async {
        let directory = tempDirectory()
        let coordinator = SearchIndexCoordinator(
            indexFactory: {
                LocalSearchIndex(scopeKey: $0, directory: directory)
            },
            embeddingProvider: FakeEmbedding(),
            languageDetector: EnglishDetector()
        )
        let episode = MediaItem(
            id: "episode",
            title: "Dinner",
            kind: .episode,
            overview: "Friends wait at a Chinese restaurant.",
            parentTitle: "Example Show",
            seasonNumber: 1,
            episodeNumber: 2,
            libraryID: "shows"
        )
        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [
            SearchIndexSource(
                accountID: "account",
                providerUserKey: "user",
                provider: OnePageProvider(items: [episode]),
                libraries: [
                    SearchIndexLibrarySource(
                        libraryID: "shows",
                        kinds: [.episode]
                    )
                ]
            )
            ],
            retainingAccountIDs: ["account"],
            providerUserKeysByAccount: ["account": "user"]
        )
        await coordinator.waitForIdle()

        let results = await coordinator.semanticSearch(
            query: "the episode where friends wait at a restaurant",
            excludedLibraryKeys: []
        )
        XCTAssertEqual(results.map(\.id), ["episode"])
        XCTAssertEqual(results.first?.sourceAccountID, "account")
        let status = await coordinator.status()
        XCTAssertEqual(status.documentCount, 1)
        XCTAssertFalse(status.isBuilding)
    }

    func testProfileActivationUsesSeparateDatabase() async {
        let directory = tempDirectory()
        let coordinator = SearchIndexCoordinator(
            indexFactory: {
                LocalSearchIndex(scopeKey: $0, directory: directory)
            },
            embeddingProvider: FakeEmbedding(),
            languageDetector: EnglishDetector()
        )
        await coordinator.activate(profileNamespace: "profile-b")
        let status = await coordinator.status()
        XCTAssertEqual(status.documentCount, 0)
    }

    func testPlexHomeUserReconcileRemovesPreviousUsersExclusiveItems() async {
        let directory = tempDirectory()
        let coordinator = SearchIndexCoordinator(
            indexFactory: {
                LocalSearchIndex(scopeKey: $0, directory: directory)
            },
            embeddingProvider: FakeEmbedding(),
            languageDetector: EnglishDetector()
        )
        func source(user: String, items: [MediaItem]) -> SearchIndexSource {
            SearchIndexSource(
                accountID: "plex",
                providerUserKey: user,
                provider: OnePageProvider(items: items),
                libraries: [
                    SearchIndexLibrarySource(
                        libraryID: "shows",
                        kinds: [.episode]
                    )
                ]
            )
        }
        let shared = MediaItem(
            id: "shared",
            title: "Shared",
            kind: .episode,
            overview: "A restaurant story.",
            libraryID: "shows"
        )
        let restricted = MediaItem(
            id: "restricted",
            title: "Restricted",
            kind: .episode,
            overview: "A private restaurant story.",
            libraryID: "shows"
        )
        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [source(user: "adult", items: [shared, restricted])],
            retainingAccountIDs: ["plex"],
            providerUserKeysByAccount: ["plex": "adult"]
        )
        await coordinator.waitForIdle()
        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [source(user: "kid", items: [shared])],
            retainingAccountIDs: ["plex"],
            providerUserKeysByAccount: ["plex": "kid"]
        )
        await coordinator.waitForIdle()

        let results = await coordinator.semanticSearch(
            query: "restaurant story",
            excludedLibraryKeys: [],
            minimumScore: -.infinity
        )
        XCTAssertEqual(results.map(\.id), ["shared"])
    }

    func testCancelledReconcileCannotInvalidateReplacementWriteToken() async throws {
        let directory = tempDirectory()
        let embedding = BlockingFirstEmbedding()
        let coordinator = SearchIndexCoordinator(
            indexFactory: {
                LocalSearchIndex(scopeKey: $0, directory: directory)
            },
            embeddingProvider: embedding,
            languageDetector: EnglishDetector(),
            policy: SearchCatalogIndexingPolicy(fullRefreshInterval: 0)
        )
        let replacement = MediaItem(
            id: "replacement",
            title: "Replacement",
            kind: .episode,
            overview: "A replacement restaurant story.",
            libraryID: "shows"
        )
        let replacementProvider = BlockingPageProvider(item: replacement)
        func source(
            user: String,
            provider: any SearchCatalogProviding
        ) -> SearchIndexSource {
            SearchIndexSource(
                accountID: "plex",
                providerUserKey: user,
                provider: provider,
                libraries: [
                    SearchIndexLibrarySource(
                        libraryID: "shows",
                        kinds: [.episode]
                    )
                ]
            )
        }

        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [
                source(
                    user: "adult",
                    provider: OnePageProvider(items: [])
                )
            ],
            retainingAccountIDs: ["plex"],
            providerUserKeysByAccount: ["plex": "adult"]
        )
        await embedding.waitUntilFirstDescriptorStarts()

        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [
                source(user: "kid", provider: replacementProvider)
            ],
            retainingAccountIDs: ["plex"],
            providerUserKeysByAccount: ["plex": "kid"]
        )
        await replacementProvider.waitUntilRequestStarts()
        await embedding.releaseFirstDescriptor()
        try await Task.sleep(for: .milliseconds(20))
        await replacementProvider.releaseRequest()
        await coordinator.waitForIdle()

        let results = await coordinator.semanticSearch(
            query: "restaurant story",
            excludedLibraryKeys: [],
            minimumScore: -.infinity
        )
        XCTAssertEqual(results.map(\.id), ["replacement"])
    }

    func testFailedAccountEnumerationCanBeRetainedWithoutPurging() async {
        let directory = tempDirectory()
        let coordinator = SearchIndexCoordinator(
            indexFactory: {
                LocalSearchIndex(scopeKey: $0, directory: directory)
            },
            embeddingProvider: FakeEmbedding(),
            languageDetector: EnglishDetector()
        )
        let item = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            overview: "A restaurant story.",
            libraryID: "shows"
        )
        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [
                SearchIndexSource(
                    accountID: "account",
                    providerUserKey: "user",
                    provider: OnePageProvider(items: [item]),
                    libraries: [
                        SearchIndexLibrarySource(
                            libraryID: "shows",
                            kinds: [.episode]
                        )
                    ]
                )
            ],
            retainingAccountIDs: ["account"],
            providerUserKeysByAccount: ["account": "user"]
        )
        await coordinator.waitForIdle()
        await coordinator.reconcile(
            profileNamespace: nil,
            sources: [],
            retainingAccountIDs: ["account"],
            providerUserKeysByAccount: ["account": "user"]
        )
        await coordinator.waitForIdle()
        let status = await coordinator.status()
        XCTAssertEqual(status.documentCount, 1)
    }

    func testBackgroundAdmissionBlocksUntilForeground() async throws {
        let admission = SearchIndexAdmissionController()
        await admission.setForeground(false)
        let task = Task {
            try await admission.waitForSearchIndexing()
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(task.isCancelled)
        await admission.setForeground(true)
        let completed = try await task.value
        XCTAssertTrue(completed)
    }

    func testRemovingActiveProfileDeletesItsDatabase() async {
        let directory = tempDirectory()
        let coordinator = SearchIndexCoordinator(
            indexFactory: {
                LocalSearchIndex(scopeKey: $0, directory: directory)
            },
            embeddingProvider: FakeEmbedding(),
            languageDetector: EnglishDetector()
        )
        await coordinator.activate(profileNamespace: "profile-a")
        let file = directory.appendingPathComponent(
            "search-index-profile-a.sqlite"
        )
        _ = await coordinator.status()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        await coordinator.removeProfile(profileNamespace: "profile-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
