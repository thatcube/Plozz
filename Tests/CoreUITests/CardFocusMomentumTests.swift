import XCTest
@testable import CoreUI

#if canImport(SwiftUI)
import SwiftUI

/// The arrival lean is only worth having if it follows the direction focus
/// actually travelled — a lean that plays the same way every time is a canned
/// flourish. These pin the direction down.
@MainActor
final class CardFocusMomentumTests: XCTestCase {
    private func card(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 300, height: 450)
    }

    func testFirstArrivalHasNoDirection() {
        let momentum = CardFocusMomentum()
        XCTAssertNil(momentum.arrive(at: card(x: 0, y: 0)))
    }

    func testMovingRightLeansAlongTheHorizontal() throws {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 340, y: 0)))
        XCTAssertEqual(travel.dx, 1)
        XCTAssertEqual(travel.dy, 0)
    }

    func testMovingLeftReversesIt() throws {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 340, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 0, y: 0)))
        XCTAssertEqual(travel.dx, -1)
    }

    func testMovingDownLeansAlongTheVertical() throws {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 0, y: 500)))
        XCTAssertEqual(travel.dx, 0)
        XCTAssertEqual(travel.dy, 1)
    }

    /// A diagonal move leans as hard as a straight one: the direction is what's
    /// being expressed, not how far focus happened to jump.
    func testDiagonalNormalisesTheDominantAxis() throws {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 400, y: 200)))
        XCTAssertEqual(travel.dx, 1)
        XCTAssertEqual(travel.dy, 0.5)
    }

    /// Re-focusing the same card, or a layout nudge, is not a move.
    func testNegligibleMoveHasNoDirection() {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        XCTAssertNil(momentum.arrive(at: card(x: 4, y: 0)))
    }

    /// A jump between screens isn't travel — you didn't move there, focus was
    /// placed there — so it gets no lean.
    func testImplausibleJumpHasNoDirection() {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        XCTAssertNil(momentum.arrive(at: card(x: 5000, y: 0)))
    }

    /// …but it still becomes the new reference point, so the *next* move is
    /// measured from where focus actually is.
    func testAJumpStillBecomesTheNewReferencePoint() throws {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        _ = momentum.arrive(at: card(x: 5000, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 5340, y: 0)))
        XCTAssertEqual(travel.dx, 1)
    }

    func testAnUnmeasuredCardHasNoDirection() {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        XCTAssertNil(momentum.arrive(at: .zero))
    }

    func testResetStartsFresh() {
        let momentum = CardFocusMomentum()
        _ = momentum.arrive(at: card(x: 0, y: 0))
        momentum.reset()
        XCTAssertNil(momentum.arrive(at: card(x: 340, y: 0)))
    }
}
#endif
