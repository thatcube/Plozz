import XCTest
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenProbePublicationGateTests: XCTestCase {
    func testNewLoadInvalidatesPriorGeneration() {
        var gate = PlozzigenProbePublicationGate()
        let first = gate.beginLoad()
        let second = gate.beginLoad()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
        XCTAssertNil(gate.currentRange)
    }

    func testStopInvalidatesActiveGeneration() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(active))
        XCTAssertFalse(gate.accepts(gate.currentGeneration))
        XCTAssertNil(gate.currentRange)
    }

    func testLateActiveUpdateReplacesPublishedRange() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()

        XCTAssertTrue(gate.record(.hdr10, generation: active))
        XCTAssertEqual(gate.currentRange, .hdr10)
        XCTAssertTrue(gate.record(.hdr10Plus, generation: active))
        XCTAssertEqual(gate.currentRange, .hdr10Plus)
    }

    func testReloadCanRepublishWithoutChangingGeneration() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()
        XCTAssertTrue(gate.record(.dolbyVision, generation: active))

        let reloadGeneration = gate.currentGeneration

        XCTAssertEqual(reloadGeneration, active)
        XCTAssertTrue(gate.record(.dolbyVision, generation: reloadGeneration))
        XCTAssertEqual(gate.currentRange, .dolbyVision)
    }

    func testLoadCompletionPublicationDoesNotDependOnTransientAdapterStatus() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()

        XCTAssertTrue(
            gate.acceptsLoadCompletion(active, engineHasError: false)
        )
        XCTAssertFalse(
            gate.acceptsLoadCompletion(active, engineHasError: true)
        )

        gate.invalidate()
        XCTAssertFalse(
            gate.acceptsLoadCompletion(active, engineHasError: false)
        )
    }

    func testStaleLoadCannotReplaceCurrentRange() {
        var gate = PlozzigenProbePublicationGate()
        let stale = gate.beginLoad()
        let active = gate.beginLoad()
        XCTAssertTrue(gate.record(.hlg, generation: active))

        XCTAssertFalse(gate.record(.dolbyVision, generation: stale))
        XCTAssertEqual(gate.currentRange, .hlg)
    }
}
