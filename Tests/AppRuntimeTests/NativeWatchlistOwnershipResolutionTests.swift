import CoreModels
import XCTest
@testable import AppRuntime

final class NativeWatchlistOwnershipResolutionTests: XCTestCase {
    func testResolutionIsBoundedAndPreservesEntryOrder() async throws {
        let probe = OwnershipResolutionProbe()
        let destinationID = try XCTUnwrap(
            WatchlistDestinationID(rawValue: "plex.account")
        )
        let entries = try (0..<24).map { index in
            let externalID = try XCTUnwrap(
                WatchlistExternalID(
                    namespace: .imdb,
                    value: "tt\(index)"
                )
            )
            let binding = try XCTUnwrap(
                WatchlistDestinationBinding(
                    destinationID: destinationID,
                    opaqueValue: "\(index)"
                )
            )
            let entry = try XCTUnwrap(
                WatchlistDestinationEntry(
                    kind: .movie,
                    externalIDs: [externalID],
                    binding: binding
                )
            )
            return (MediaAliasID(), entry)
        }

        let resolved = await NativeWatchlistOwnershipResolution.resolve(
            entries,
            known: [:],
            maximumConcurrentLookups: 4
        ) { entry in
            await probe.resolve(entry)
        }

        let peakConcurrency = await probe.peakConcurrency
        XCTAssertEqual(peakConcurrency, 4)
        XCTAssertEqual(
            resolved.compactMap(\.self).map(\.source.itemID),
            entries.map { $0.1.binding.opaqueValue }
        )
    }
}

private actor OwnershipResolutionProbe {
    private var active = 0
    private(set) var peakConcurrency = 0

    func resolve(
        _ entry: WatchlistDestinationEntry
    ) async -> WatchlistLibraryCopy {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        try? await Task.sleep(for: .milliseconds(10))
        active -= 1
        return WatchlistLibraryCopy(
            source: MediaSourceRef(
                accountID: "plex",
                itemID: entry.binding.opaqueValue,
                kind: entry.kind,
                providerKind: .plex
            )
        )
    }
}
