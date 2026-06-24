import XCTest
@testable import CoreUI

/// Deterministic coverage of the loading-message threshold + cycling logic.
final class LoadingMessageSequencerTests: XCTestCase {
    private func makeMessages(_ count: Int) -> [LoadingMessage] {
        (0..<count).map { LoadingMessage(id: "m\($0)", text: "Message \($0)") }
    }

    func testSpinnerOnlyBeforeThreshold() {
        let seq = LoadingMessageSequencer(messages: makeMessages(3), initialDelay: 3.5, cycleInterval: 3.0)
        XCTAssertEqual(seq.phase(atElapsed: 0), .spinnerOnly)
        XCTAssertEqual(seq.phase(atElapsed: 1.0), .spinnerOnly)
        XCTAssertEqual(seq.phase(atElapsed: 3.49), .spinnerOnly)
    }

    func testFirstMessageAtThreshold() {
        let messages = makeMessages(3)
        let seq = LoadingMessageSequencer(messages: messages, initialDelay: 3.5, cycleInterval: 3.0)
        XCTAssertEqual(seq.phase(atElapsed: 3.5), .message(messages[0], index: 0))
        XCTAssertEqual(seq.phase(atElapsed: 4.0), .message(messages[0], index: 0))
    }

    func testCyclesThroughMessagesInOrder() {
        let messages = makeMessages(3)
        let seq = LoadingMessageSequencer(messages: messages, initialDelay: 3.5, cycleInterval: 3.0)
        XCTAssertEqual(seq.phase(atElapsed: 3.5), .message(messages[0], index: 0))
        XCTAssertEqual(seq.phase(atElapsed: 6.5), .message(messages[1], index: 1))
        XCTAssertEqual(seq.phase(atElapsed: 9.5), .message(messages[2], index: 2))
    }

    func testWrapsAroundAfterLastMessage() {
        let messages = makeMessages(3)
        let seq = LoadingMessageSequencer(messages: messages, initialDelay: 3.5, cycleInterval: 3.0)
        // step 3 -> index 0 again
        XCTAssertEqual(seq.phase(atElapsed: 12.5), .message(messages[0], index: 0))
        // step 4 -> index 1
        XCTAssertEqual(seq.phase(atElapsed: 15.5), .message(messages[1], index: 1))
    }

    func testBoundaryIsDeterministic() {
        let messages = makeMessages(2)
        let seq = LoadingMessageSequencer(messages: messages, initialDelay: 2.0, cycleInterval: 2.0)
        // exactly on a cycle boundary should advance (not stick on the prior one)
        XCTAssertEqual(seq.phase(atElapsed: 2.0), .message(messages[0], index: 0))
        XCTAssertEqual(seq.phase(atElapsed: 4.0), .message(messages[1], index: 1))
        XCTAssertEqual(seq.phase(atElapsed: 6.0), .message(messages[0], index: 0))
    }

    func testEmptyMessagesStaySpinnerOnly() {
        let seq = LoadingMessageSequencer(messages: [], initialDelay: 1.0, cycleInterval: 1.0)
        XCTAssertEqual(seq.phase(atElapsed: 0), .spinnerOnly)
        XCTAssertEqual(seq.phase(atElapsed: 100), .spinnerOnly)
    }

    func testZeroCycleIntervalHoldsFirstMessage() {
        let messages = makeMessages(3)
        let seq = LoadingMessageSequencer(messages: messages, initialDelay: 1.0, cycleInterval: 0)
        XCTAssertEqual(seq.phase(atElapsed: 1.0), .message(messages[0], index: 0))
        XCTAssertEqual(seq.phase(atElapsed: 50.0), .message(messages[0], index: 0))
    }

    func testDefaultMessagesAreNonEmptyAndUniqueIDs() {
        let ids = LoadingMessage.playfulDefaults.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(Set(ids).count, ids.count, "playful default message IDs must be unique")
    }

    func testSpokenTextFallsBackToVisibleText() {
        let plain = LoadingMessage(id: "a", text: "Hello")
        XCTAssertEqual(plain.spokenText, "Hello")
        let spoken = LoadingMessage(id: "b", text: "Hi…", accessibilityText: "Hi, please wait")
        XCTAssertEqual(spoken.spokenText, "Hi, please wait")
    }
}
