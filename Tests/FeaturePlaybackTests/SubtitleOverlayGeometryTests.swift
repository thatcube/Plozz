import CoreGraphics
import XCTest
@testable import FeaturePlayback

final class SubtitleOverlayGeometryTests: XCTestCase {
    func testAspectFitVideoRectUsesFullPortraitWidth() throws {
        let rect = try XCTUnwrap(
            SubtitleOverlayGeometry.aspectFitRect(
                in: CGRect(x: 0, y: 0, width: 390, height: 844),
                aspectRatio: 16.0 / 9.0
            )
        )

        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 390, accuracy: 0.001)
        XCTAssertEqual(rect.height, 219.375, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 422, accuracy: 0.001)
    }

    func testBitmapCueMapsAgainstLetterboxedVideoRect() throws {
        let videoRect = try XCTUnwrap(
            SubtitleOverlayGeometry.aspectFitRect(
                in: CGRect(x: 0, y: 0, width: 390, height: 844),
                aspectRatio: 16.0 / 9.0
            )
        )
        let rect = SubtitleOverlayGeometry.bitmapRect(
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1),
            canvasSize: .zero,
            videoRect: videoRect
        )

        XCTAssertEqual(rect.minX, 39, accuracy: 0.001)
        XCTAssertEqual(rect.width, 312, accuracy: 0.001)
        XCTAssertEqual(rect.height, 21.9375, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, videoRect.minY + videoRect.height * 0.9, accuracy: 0.001)
    }

    func testSubtitleCanvasStaysWidthAlignedAndCenterAnchored() {
        let videoRect = CGRect(x: 0, y: 100, width: 400, height: 160)
        let rect = SubtitleOverlayGeometry.bitmapRect(
            normalizedRect: CGRect(x: 0, y: 0.8, width: 1, height: 0.1),
            canvasSize: CGSize(width: 1920, height: 1080),
            videoRect: videoRect
        )

        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 247.5, accuracy: 0.001)
        XCTAssertEqual(rect.height, 22.5, accuracy: 0.001)
    }
}
