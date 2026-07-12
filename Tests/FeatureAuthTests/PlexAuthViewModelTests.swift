import XCTest
import CoreModels
@testable import FeatureAuth

final class PlexAuthViewModelTests: XCTestCase {
    func testDualPinRaceReturnsFirstLinkedChallenge() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins", jsons: [
            #"{"id":1,"code":"MANU","authToken":null}"#,
            #"{"id":2,"code":"HOST","authToken":null}"#
        ])
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/1",
            json: #"{"id":1,"code":"MANU","authToken":null}"#
        )
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/2",
            json: #"{"id":2,"code":"HOST","authToken":"HOST_TOKEN"}"#
        )
        let service = makeService(stub: stub, pollInterval: 0.02)
        let manualPin = try await service.begin()
        let hostedPin = try await service.begin(strong: true)

        let outcome = try await PlexAuthViewModel.awaitLinkOrExpiry(
            service: service,
            pins: [manualPin, hostedPin],
            expiresAt: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(outcome, .linked("HOST_TOKEN"))
    }

    func testDualPinRaceExpiresAndCancelsPolls() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins", jsons: [
            #"{"id":1,"code":"MANU","authToken":null}"#,
            #"{"id":2,"code":"HOST","authToken":null}"#
        ])
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/1",
            json: #"{"id":1,"code":"MANU","authToken":null}"#
        )
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/2",
            json: #"{"id":2,"code":"HOST","authToken":null}"#
        )
        let service = makeService(stub: stub, pollInterval: 1)
        let manualPin = try await service.begin()
        let hostedPin = try await service.begin(strong: true)

        let outcome = try await PlexAuthViewModel.awaitLinkOrExpiry(
            service: service,
            pins: [manualPin, hostedPin],
            expiresAt: Date().addingTimeInterval(0.02)
        )

        XCTAssertEqual(outcome, .expired)
    }

    func testCancellingDualPinRaceCancelsAllWork() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/api/v2/pins", jsons: [
            #"{"id":1,"code":"MANU","authToken":null}"#,
            #"{"id":2,"code":"HOST","authToken":null}"#
        ])
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/1",
            json: #"{"id":1,"code":"MANU","authToken":null}"#
        )
        stub.stubFixed(
            pathSuffix: "/api/v2/pins/2",
            json: #"{"id":2,"code":"HOST","authToken":null}"#
        )
        let service = makeService(stub: stub, pollInterval: 1)
        let manualPin = try await service.begin()
        let hostedPin = try await service.begin(strong: true)
        let race = Task {
            try await PlexAuthViewModel.awaitLinkOrExpiry(
                service: service,
                pins: [manualPin, hostedPin],
                expiresAt: Date().addingTimeInterval(5)
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        race.cancel()

        do {
            _ = try await race.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeService(
        stub: StubHTTPClient,
        pollInterval: TimeInterval
    ) -> PlexAuthService {
        PlexAuthService(
            deviceID: "dev1",
            http: stub,
            config: .init(pollInterval: pollInterval, timeout: 5)
        )
    }
}
