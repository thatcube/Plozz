#if canImport(UIKit)
import XCTest
import UIKit
@testable import FeatureHome

@MainActor
final class HomeHeroBackdropTests: XCTestCase {
    func testRapidWipesRemainStackedUntilEachRevealFinishes() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftOut: 320
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)

        let first = image(.red)
        let second = image(.green)
        let third = image(.blue)
        container.setInitialImage(first)

        let secondWipe = container.prepareWipe(incomingImage: second, forward: true)
        let thirdWipe = container.prepareWipe(incomingImage: third, forward: true)

        XCTAssertEqual(container.pageCount, 3)
        XCTAssertEqual(container.activeWipeCount, 2)
        XCTAssertTrue(container.frontImage === third)

        container.finishWipe(secondWipe.incoming)

        XCTAssertEqual(container.pageCount, 2)
        XCTAssertEqual(container.activeWipeCount, 1)
        XCTAssertTrue(container.frontImage === third)

        container.finishWipe(thirdWipe.incoming)

        XCTAssertEqual(container.pageCount, 1)
        XCTAssertEqual(container.activeWipeCount, 0)
        XCTAssertTrue(container.frontImage === third)
    }

    func testOppositeDirectionWipesAlsoStack() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftOut: 320
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)
        container.setInitialImage(image(.red))

        let forward = container.prepareWipe(incomingImage: image(.green), forward: true)
        let backward = container.prepareWipe(incomingImage: image(.blue), forward: false)

        container.animateIncoming(forward.incoming)
        if let outgoing = forward.outgoing {
            container.animateOutgoing(outgoing, forward: true)
        }
        container.animateIncoming(backward.incoming)
        if let outgoing = backward.outgoing {
            container.animateOutgoing(outgoing, forward: false)
        }

        XCTAssertEqual(container.pageCount, 3)
        XCTAssertEqual(container.activeWipeCount, 2)
    }

    func testClearingArtworkRemovesEveryStackedPage() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftOut: 320
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)
        container.setInitialImage(image(.red))
        _ = container.prepareWipe(incomingImage: image(.green), forward: true)
        _ = container.prepareWipe(incomingImage: image(.blue), forward: false)

        container.clear()

        XCTAssertEqual(container.pageCount, 0)
        XCTAssertEqual(container.activeWipeCount, 0)
        XCTAssertNil(container.frontImage)
    }

    func testProgressiveImageUpgradeKeepsWipeInFlight() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftOut: 320
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)
        container.setInitialImage(image(.red))
        let preview = image(.green)
        let fullResolution = image(.blue)

        let wipe = container.prepareWipe(incomingImage: preview, forward: true)
        container.animateIncoming(wipe.incoming)
        container.frontImage = fullResolution

        XCTAssertEqual(container.pageCount, 2)
        XCTAssertEqual(container.activeWipeCount, 1)
        XCTAssertTrue(container.frontImage === fullResolution)

        container.finishWipe(wipe.incoming)
        XCTAssertEqual(container.pageCount, 1)
        XCTAssertEqual(container.activeWipeCount, 0)
        XCTAssertTrue(container.frontImage === fullResolution)
    }

    func testHeroBackdropPolicyRejectsUltraWideProviderJunk() {
        let usable = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let ultraWide = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 10)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
        }

        XCTAssertTrue(HeroBackdropArtworkPolicy.isUsable(usable))
        XCTAssertFalse(HeroBackdropArtworkPolicy.isUsable(ultraWide))
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
    }
}
#endif
