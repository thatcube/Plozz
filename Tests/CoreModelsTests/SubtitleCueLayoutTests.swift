import XCTest
import CoreGraphics
@testable import CoreModels

final class SubtitleCueLayoutTests: XCTestCase {

    func testBareAlignmentInitWrapsIntoSourcePositionedLayout() {
        let t = SubtitleText("sign", alignment: .topCenter)
        XCTAssertEqual(t.alignment, .topCenter, "alignment passthrough still works")
        XCTAssertNotNil(t.layout)
        XCTAssertEqual(t.layout?.alignment, .topCenter)
        XCTAssertTrue(t.layout?.isSourcePositioned == true)
        XCTAssertNil(t.layout?.anchor)
        XCTAssertEqual(t.layout?.margins, .zero)
    }

    func testNilAlignmentMeansDefaultDialogueLane() {
        let t = SubtitleText("dialogue")
        XCTAssertNil(t.alignment)
        XCTAssertNil(t.layout, "no layout == default dialogue lane")
    }

    func testRichLayoutInitPreservesAnchorAndMargins() {
        let layout = SubtitleCueLayout(
            alignment: .topLeft,
            anchor: CGPoint(x: 0.25, y: 0.1),
            margins: SubtitleEdgeInsets(top: 0.02, leading: 0.05),
            isSourcePositioned: true
        )
        let t = SubtitleText("positioned", layout: layout)
        XCTAssertEqual(t.alignment, .topLeft)
        XCTAssertEqual(t.layout?.anchor, CGPoint(x: 0.25, y: 0.1))
        XCTAssertEqual(t.layout?.margins.leading, 0.05)
        XCTAssertEqual(t.layout?.margins.top, 0.02)
    }

    func testEdgeInsetsZero() {
        XCTAssertTrue(SubtitleEdgeInsets.zero.isZero)
        XCTAssertFalse(SubtitleEdgeInsets(bottom: 0.1).isZero)
    }

    func testAlignmentPlaneDecomposition() {
        XCTAssertEqual(SubtitleAlignment.topLeft.vertical, .top)
        XCTAssertEqual(SubtitleAlignment.topLeft.horizontal, .leading)
        XCTAssertEqual(SubtitleAlignment.bottomRight.vertical, .bottom)
        XCTAssertEqual(SubtitleAlignment.middleCenter.horizontal, .center)
    }

    func testStreamFormatClassification() {
        XCTAssertTrue(SubtitleFormat.ass.isASSFamily)
        XCTAssertTrue(SubtitleFormat.ssa.isASSFamily)
        XCTAssertFalse(SubtitleFormat.webVTT.isASSFamily)
        XCTAssertTrue(SubtitleFormat.pgs.isImageBased)
        XCTAssertFalse(SubtitleFormat.srt.isImageBased)
    }
}
