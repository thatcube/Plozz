#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import TopShelfKit

/// The Top Shelf's progress bar is burned into a PNG by Core Graphics, so it
/// cannot reference the SwiftUI colours the in-app bar uses — TopShelfKit is
/// built into the extension and deliberately does not depend on CoreUI. The two
/// therefore carry the same greys as separate literals, and drifted once already
/// (the shelf kept the old brand blue after the app moved to white).
///
/// These tests are the thing that stops that happening again.
final class PlozzMediaChromeParityTests: XCTestCase {
    private func white(of color: Color) -> CGFloat {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getWhite(&white, alpha: &alpha))
        return white
    }

    private func alpha(of color: Color) -> CGFloat {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getWhite(&white, alpha: &alpha))
        return alpha
    }

    func testShelfBarFillMatchesTheRestingInAppForeground() {
        // Resting, not focused: a burned-in image can't respond to focus, and a
        // shelf reads as a wall of cards rather than one highlighted card.
        XCTAssertEqual(
            TopShelfPosterComposer.Bar.fillWhite,
            white(of: PlozzMediaChrome.foreground(isFocused: false)),
            accuracy: 0.01,
            "Top Shelf progress fill drifted from the in-app bar"
        )
    }

    func testShelfBarTrackMatchesTheRestingInAppTrack() {
        XCTAssertEqual(
            TopShelfPosterComposer.Bar.trackAlpha,
            alpha(of: PlozzMediaChrome.track(isFocused: false)),
            accuracy: 0.01,
            "Top Shelf progress track drifted from the in-app bar"
        )
    }

    func testShelfBarFillIsNotTheBrandBlue() {
        // Colour is reserved for specific moments; progress is not one of them.
        XCTAssertTrue(
            TopShelfPosterComposer.Bar.fillWhite > 0.5,
            "The fill must be a white-grey, not a hue"
        )
    }
}
#endif
