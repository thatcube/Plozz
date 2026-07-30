import XCTest

@testable import FeaturePlayback

final class ControlsAutoHidePolicyTests: XCTestCase {

    // MARK: hideDate — max(load+1s, input+4s)

    func testLongLoadHidesOneSecondAfterLoadFinishes() {
        // Load took much longer than the 4s input floor: the input floor is
        // already in the past, so hide is gated by loadDone + 1s.
        let inputAt = Date()
        let loadDoneAt = inputAt.addingTimeInterval(10) // 10s load
        let hideAt = ControlsAutoHidePolicy.hideDate(loadDoneAt: loadDoneAt, inputAt: inputAt)
        XCTAssertEqual(hideAt.timeIntervalSince(loadDoneAt), 1.0, accuracy: 0.0001,
                       "a long load hides 1s after the picture is up")
        XCTAssertEqual(hideAt.timeIntervalSince(inputAt), 11.0, accuracy: 0.0001)
    }

    func testShortLoadHonorsFourSecondInputFloor() {
        // Load finished almost immediately: the 4s-since-input floor dominates so
        // the controls the viewer summoned stay for the full 4s.
        let inputAt = Date()
        let loadDoneAt = inputAt.addingTimeInterval(0.2) // near-instant load
        let hideAt = ControlsAutoHidePolicy.hideDate(loadDoneAt: loadDoneAt, inputAt: inputAt)
        XCTAssertEqual(hideAt.timeIntervalSince(inputAt), 4.0, accuracy: 0.0001,
                       "a short load still holds the full 4s after the last input")
    }

    func testFloorsExactlyAtCrossover() {
        // load+1 == input+4 when the load took exactly 3s.
        let inputAt = Date()
        let loadDoneAt = inputAt.addingTimeInterval(3.0)
        let hideAt = ControlsAutoHidePolicy.hideDate(loadDoneAt: loadDoneAt, inputAt: inputAt)
        XCTAssertEqual(hideAt.timeIntervalSince(inputAt), 4.0, accuracy: 0.0001)
    }

    func testInfoCardHoldsALongerInputFloor() {
        // The Info card is read, not operated, so the floor is longer than the 4s
        // that suits a row of buttons.
        let inputAt = Date()
        let loadDoneAt = inputAt.addingTimeInterval(0.2) // near-instant load
        let hideAt = ControlsAutoHidePolicy.hideDate(
            loadDoneAt: loadDoneAt, inputAt: inputAt, infoCardOpen: true
        )
        XCTAssertEqual(hideAt.timeIntervalSince(inputAt),
                       ControlsAutoHidePolicy.minSinceInputWithInfoCard, accuracy: 0.0001,
                       "the card gets its own, longer floor")
        XCTAssertGreaterThan(ControlsAutoHidePolicy.minSinceInputWithInfoCard,
                             ControlsAutoHidePolicy.minSinceInput)
    }

    func testInfoCardFloorStillLosesToASlowLoad() {
        // The card extends the INPUT floor only; a load that finishes even later
        // still governs, exactly as for the transport.
        let inputAt = Date()
        let loadDoneAt = inputAt.addingTimeInterval(20)
        let hideAt = ControlsAutoHidePolicy.hideDate(
            loadDoneAt: loadDoneAt, inputAt: inputAt, infoCardOpen: true
        )
        XCTAssertEqual(hideAt.timeIntervalSince(loadDoneAt),
                       ControlsAutoHidePolicy.postLoadGrace, accuracy: 0.0001)
    }

    func testDefaultFloorIsUnchangedWithoutTheInfoCard() {
        // Regression guard: adding the card's floor must not move the normal one.
        let inputAt = Date()
        let loadDoneAt = inputAt.addingTimeInterval(0.2)
        XCTAssertEqual(
            ControlsAutoHidePolicy.hideDate(loadDoneAt: loadDoneAt, inputAt: inputAt),
            ControlsAutoHidePolicy.hideDate(loadDoneAt: loadDoneAt, inputAt: inputAt, infoCardOpen: false)
        )
    }

    // MARK: outcome — interaction pins beat focus routing

    func testScrubbingStaysVisibleRegardlessOfFocus() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .surface, isScrubbing: true, isPaused: false, isPanelOpen: false),
            .stayVisible)
    }

    func testPausedStaysVisible() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .surface, isScrubbing: false, isPaused: true, isPanelOpen: false),
            .stayVisible)
    }

    func testOpenPanelStaysVisibleEvenInControlBar() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .controlBar, isScrubbing: false, isPaused: false, isPanelOpen: true),
            .stayVisible)
    }

    func testIdleOnSurfaceHides() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .surface, isScrubbing: false, isPaused: false, isPanelOpen: false),
            .hide)
    }

    func testIdleInControlBarReturnsFocusThenHides() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .controlBar, isScrubbing: false, isPaused: false, isPanelOpen: false),
            .returnFocusThenHide)
    }

    func testFocusedSkipButtonKeepsTransport() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .skipButton, isScrubbing: false, isPaused: false, isPanelOpen: false),
            .keepForAffordance)
    }

    func testFocusedUpNextKeepsTransport() {
        XCTAssertEqual(
            ControlsAutoHidePolicy.outcome(focus: .upNext, isScrubbing: false, isPaused: false, isPanelOpen: false),
            .keepForAffordance)
    }
}
