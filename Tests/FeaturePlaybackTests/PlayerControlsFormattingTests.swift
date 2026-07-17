import XCTest
import CoreModels
@testable import FeaturePlayback

/// Tests the pure subtitle-style label formatters extracted from
/// `PlayerControls`. These pin the human-readable readouts (named anchors,
/// signed offsets, preset color names, edge summary) that the style rows show.
final class PlayerControlsFormattingTests: XCTestCase {
    func testPositionLabelNamesExtremes() {
        XCTAssertEqual(PlayerControlsFormatting.positionLabel(0), "Bottom")
        XCTAssertEqual(PlayerControlsFormatting.positionLabel(90), "Top")
        XCTAssertEqual(PlayerControlsFormatting.positionLabel(45), "45%")
    }

    func testHorizontalOffsetLabelWordsDirection() {
        XCTAssertEqual(PlayerControlsFormatting.hOffsetLabel(0), "Centre")
        XCTAssertEqual(PlayerControlsFormatting.hOffsetLabel(20), "Right 20%")
        XCTAssertEqual(PlayerControlsFormatting.hOffsetLabel(-15), "Left 15%")
    }

    func testCornerLabelSentinelReadsFull() {
        XCTAssertEqual(PlayerControlsFormatting.cornerLabel(12), "12")
        XCTAssertEqual(PlayerControlsFormatting.cornerLabel(PlayerControlsFormatting.cornerFull), "Full")
    }

    func testNearestIndexSnapsToClosestOption() {
        let options = [0, 10, 20, 30]
        XCTAssertEqual(PlayerControlsFormatting.nearestIndex(options, 13), 1)
        XCTAssertEqual(PlayerControlsFormatting.nearestIndex(options, 16), 2)
        XCTAssertEqual(PlayerControlsFormatting.nearestIndex([], 5), 0)
    }

    func testEdgeSummaryCollapsesCombinations() {
        var s = SubtitleStyle.default
        s.edge.style = .none
        s.border.isEnabled = false
        XCTAssertEqual(PlayerControlsFormatting.edgeSummary(s), "Off")

        s.border.isEnabled = true
        XCTAssertEqual(PlayerControlsFormatting.edgeSummary(s), "Outline")

        s.edge.style = .dropShadow
        s.border.isEnabled = false
        XCTAssertEqual(PlayerControlsFormatting.edgeSummary(s), "Shadow")

        s.border.isEnabled = true
        XCTAssertEqual(PlayerControlsFormatting.edgeSummary(s), "On")
    }

    func testBoxColorLabelNamesPresets() {
        XCTAssertEqual(PlayerControlsFormatting.boxColorLabel(SubtitleColor(red: 0, green: 0, blue: 0, alpha: 1)), "Black")
        XCTAssertEqual(PlayerControlsFormatting.boxColorLabel(SubtitleColor(red: 1, green: 1, blue: 1, alpha: 1)), "White")
        XCTAssertEqual(PlayerControlsFormatting.boxColorLabel(SubtitleColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)), "Charcoal")
        XCTAssertEqual(PlayerControlsFormatting.boxColorLabel(SubtitleColor(red: 0.5, green: 0.2, blue: 0.1, alpha: 1)), "Custom")
    }
}
