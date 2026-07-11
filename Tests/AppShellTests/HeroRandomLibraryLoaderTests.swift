import XCTest
import CoreModels
@testable import AppShell

final class HeroRandomLibraryLoaderTests: XCTestCase {
    private actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var maximum = 0
        private(set) var requested: [HeroRandomLibrary] = []

        func begin(_ library: HeroRandomLibrary) {
            active += 1
            maximum = max(maximum, active)
            requested.append(library)
        }

        func end() {
            active -= 1
        }
    }

    func testEligibleLibrariesFetchConcurrentlyWithinBound() async {
        let libraries = (0..<6).map {
            HeroRandomLibrary(
                accountID: "account",
                libraryID: "library-\($0)",
                kind: $0.isMultiple(of: 2) ? .movie : .series
            )
        }
        let probe = ConcurrencyProbe()

        let result = await HeroRandomLibraryLoader.load(
            libraries: libraries,
            limit: 6
        ) { library, _ in
            await probe.begin(library)
            try? await Task.sleep(nanoseconds: 40_000_000)
            await probe.end()
            return [MediaItem(id: library.libraryID, title: library.libraryID, kind: .movie)]
        }
        let maximum = await probe.maximum
        let requested = await probe.requested

        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertEqual(Set(requested), Set(libraries))
        XCTAssertEqual(Set(result.map(\.id)), Set(libraries.map(\.libraryID)))
    }

    func testSkipsUnsupportedAndDuplicateLibraries() async {
        let movies = HeroRandomLibrary(
            accountID: "account",
            libraryID: "movies",
            kind: .movie
        )
        let music = HeroRandomLibrary(
            accountID: "account",
            libraryID: "music",
            kind: .folder
        )
        let probe = ConcurrencyProbe()

        _ = await HeroRandomLibraryLoader.load(
            libraries: [movies, movies, music],
            limit: 8
        ) { library, _ in
            await probe.begin(library)
            await probe.end()
            return []
        }
        let requested = await probe.requested

        XCTAssertEqual(requested, [movies])
    }

    func testRequestLimitDistributesOversamplingAcrossLibraries() {
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 20, libraryCount: 1),
            20
        )
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 20, libraryCount: 2),
            15
        )
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 20, libraryCount: 4),
            8
        )
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 8, libraryCount: 4),
            3
        )
    }

    func testCancellationDoesNotQueueAdditionalLibraries() async {
        let libraries = (0..<8).map {
            HeroRandomLibrary(
                accountID: "account",
                libraryID: "library-\($0)",
                kind: .movie
            )
        }
        let probe = ConcurrencyProbe()
        let task = Task {
            await HeroRandomLibraryLoader.load(libraries: libraries, limit: 8) { library, _ in
                await probe.begin(library)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await probe.end()
                return [MediaItem(id: library.libraryID, title: library.libraryID, kind: .movie)]
            }
        }

        for _ in 0..<1_000 {
            if await probe.active == 4 { break }
            await Task.yield()
        }
        let activeBeforeCancellation = await probe.active
        XCTAssertEqual(activeBeforeCancellation, 4)

        task.cancel()
        let result = await task.value
        let requested = await probe.requested

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(requested.count, 4)
    }
}
