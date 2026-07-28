import CoreGraphics
import XCTest
@testable import CoreUI

/// Coverage for `HeroLogoFit`, which sizes a hero wordmark by **area** so a show's
/// presence on screen doesn't come down to the shape of its logo.
///
/// The shapes here are measured from real logos in a live library: a very wide
/// wordmark ("The Old Man"), ordinary wide ones ("Reacher", "Avatar"), a squarish
/// one ("17 Again"), and a tall poster-style one ("Sleepy Princess in the Demon
/// Castle"). Under a plain width-and-height cap these spanned a 3.4× range in area.
final class HeroLogoFitTests: XCTestCase {

    private let slot = CGSize(width: 496, height: 160)

    private func fit(aspect: CGFloat) -> CGSize {
        HeroLogoFit.fittedSize(
            for: CGSize(width: 1000, height: 1000 * aspect),
            maxWidth: slot.width,
            maxHeight: slot.height
        )
    }

    private func area(_ size: CGSize) -> CGFloat { size.width * size.height }

    /// Aspects (height ÷ width) measured from the real logos.
    private let veryWide: CGFloat = 0.11   // The Old Man
    private let wide: CGFloat = 0.25       // Avatar
    private let squarish: CGFloat = 0.85   // 17 Again
    private let tall: CGFloat = 1.40       // Sleepy Princess

    // MARK: The point of the whole type

    func testEveryShapeLandsWithinHalfAStopOfTheSame() {
        let areas = [veryWide, 0.22, wide, squarish, tall].map { area(fit(aspect: $0)) }
        let spread = areas.max()! / areas.min()!
        XCTAssertLessThan(spread, 1.6, "was 3.4x under a plain height cap")
    }

    func testATallLogoIsNoLongerShrunkForBeingTall() {
        // The worst case: a height cap collapsed this to 114x160 (18k), less than a
        // third of a wide wordmark's area.
        let size = fit(aspect: tall)
        XCTAssertGreaterThan(area(size), 40_000)
        XCTAssertGreaterThan(size.width, 160)
    }

    func testAVeryWideLogoIsNoLongerAThinStrip() {
        // Filling the width left this 55pt tall — legible, but weightless.
        let size = fit(aspect: veryWide)
        XCTAssertGreaterThan(area(size), 40_000)
        XCTAssertGreaterThan(size.height, 60)
    }

    // MARK: Preserving what already looked right

    func testAnOrdinaryWideWordmarkIsUnchanged() {
        // The shape that reads correctly today must not move, or the fix trades one
        // complaint for another.
        let size = fit(aspect: wide)
        XCTAssertEqual(size.width, 496, accuracy: 1)
        XCTAssertEqual(size.height, 124, accuracy: 1)
    }

    // MARK: Bounds

    func testNeitherDimensionEscapesItsFlexCeiling() {
        for aspect in [0.05, 0.11, 0.25, 0.85, 1.4, 3.0] {
            let size = fit(aspect: CGFloat(aspect))
            XCTAssertLessThanOrEqual(size.width, slot.width * HeroLogoFit.widthFlex + 0.5)
            XCTAssertLessThanOrEqual(size.height, slot.height * HeroLogoFit.heightFlex + 0.5)
        }
    }

    func testTheDrawnAspectRatioIsNeverDistorted() {
        for aspect in [0.05, 0.11, 0.25, 0.85, 1.4, 3.0] {
            let size = fit(aspect: CGFloat(aspect))
            XCTAssertEqual(size.height / size.width, CGFloat(aspect), accuracy: 0.001)
        }
    }

    func testASmallSourceIsScaledUpRatherThanLeftTiny() {
        // Logo art arrives from several providers at different resolutions; sizing by
        // the source's own pixels made one show bold and another tiny for reasons
        // unrelated to how either logo looks.
        let tiny = HeroLogoFit.fittedSize(
            for: CGSize(width: 100, height: 25),
            maxWidth: slot.width,
            maxHeight: slot.height
        )
        let large = HeroLogoFit.fittedSize(
            for: CGSize(width: 2000, height: 500),
            maxWidth: slot.width,
            maxHeight: slot.height
        )
        XCTAssertEqual(tiny.width, large.width, accuracy: 0.5)
        XCTAssertEqual(tiny.height, large.height, accuracy: 0.5)
    }

    func testADegenerateSizeFallsBackToTheSlot() {
        let zero = HeroLogoFit.fittedSize(
            for: .zero,
            maxWidth: slot.width,
            maxHeight: slot.height
        )
        XCTAssertEqual(zero, slot)
    }
}
