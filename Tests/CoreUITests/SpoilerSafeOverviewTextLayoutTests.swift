#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
import CoreModels
@testable import CoreUI

@MainActor
final class SpoilerSafeOverviewTextLayoutTests: XCTestCase {
    func testOverviewStatesKeepIdenticalThreeLineHeight() {
        let missingHeight = height(overview: nil, hidesSpoilers: false, mode: .blur)
        let shortHeight = height(overview: "Short overview.", hidesSpoilers: false, mode: .blur)
        let longHeight = height(
            overview: String(repeating: "A longer episode overview that wraps across the card. ", count: 8),
            hidesSpoilers: false,
            mode: .blur
        )
        let blurredHeight = height(
            overview: "A hidden episode overview.",
            hidesSpoilers: true,
            mode: .blur
        )
        let placeholderHeight = height(
            overview: nil,
            hidesSpoilers: true,
            mode: .placeholder
        )

        for candidate in [shortHeight, longHeight, blurredHeight, placeholderHeight] {
            XCTAssertEqual(candidate, missingHeight, accuracy: 0.5)
        }
    }

    private func height(
        overview: String?,
        hidesSpoilers: Bool,
        mode: SpoilerSettings.Mode
    ) -> CGFloat {
        let view = SpoilerSafeOverviewText(
            overview: overview,
            hidesSpoilers: hidesSpoilers,
            mode: mode,
            lineCount: 3,
            fontSize: 20,
            maxWidth: 480
        )
        .frame(width: 480, alignment: .topLeading)

        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 480, height: 1_000))
            .height
    }
}
#endif
