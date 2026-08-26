import XCTest
@testable import CoreUI

#if canImport(SwiftUI)
import SwiftUI

/// The arrival lean is only worth having if it follows the direction focus
/// actually travelled — a lean that plays the same way every time is a canned
/// flourish. These pin the direction down.
///
/// Note the shape of every test: a card `depart`s, then the next one `arrive`s.
/// That order is the point. Rails scroll to bring the focused card toward the
/// middle, so a card's position when it *takes* focus is not where it sits a
/// moment later — measuring from where the last card actually *was* when it let
/// focus go is what makes the second step in a direction lean like the first.
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
        momentum.depart(from: card(x: 0, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 340, y: 0)))
        XCTAssertEqual(travel.dx, 1)
        XCTAssertEqual(travel.dy, 0)
    }

    func testMovingLeftReversesIt() throws {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 340, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 0, y: 0)))
        XCTAssertEqual(travel.dx, -1)
    }

    func testMovingDownLeansAlongTheVertical() throws {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 0, y: 500)))
        XCTAssertEqual(travel.dx, 0)
        XCTAssertEqual(travel.dy, 1)
    }

    /// A diagonal move leans as hard as a straight one: the direction is what's
    /// being expressed, not how far focus happened to jump.
    func testDiagonalNormalisesTheDominantAxis() throws {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 400, y: 200)))
        XCTAssertEqual(travel.dx, 1)
        XCTAssertEqual(travel.dy, 0.5)
    }

    /// Re-focusing the same card, or a layout nudge, is not a move.
    func testNegligibleMoveHasNoDirection() {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        XCTAssertNil(momentum.arrive(at: card(x: 4, y: 0)))
    }

    /// A jump between screens isn't travel — you didn't move there, focus was
    /// placed there — so it gets no lean.
    func testImplausibleJumpHasNoDirection() {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        XCTAssertNil(momentum.arrive(at: card(x: 5000, y: 0)))
    }

    /// …and the card focus jumped to still reports where it was when it leaves,
    /// so the move after that is measured from where focus actually is.
    func testAJumpStillBecomesTheNewReferencePoint() throws {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        momentum.depart(from: card(x: 5000, y: 0))
        let travel = try XCTUnwrap(momentum.arrive(at: card(x: 5340, y: 0)))
        XCTAssertEqual(travel.dx, 1)
    }

    /// The regression this split exists for.
    ///
    /// A rail scrolls to bring the focused card toward the middle, so a card is
    /// out at the edge when it takes focus and settled in the middle a moment
    /// later. Measuring arrivals against a stale *arrival* position compared two
    /// edge positions and found no movement — focus visibly travelling right, and
    /// a card that didn't lean. Departure positions are the ones that move.
    func testSecondStepInARailLeansLikeTheFirst() throws {
        let momentum = CardFocusMomentum()
        let centre: CGFloat = 660     // where the rail parks the focused card
        let incoming: CGFloat = 960   // where its neighbour sits before the scroll

        // Step one: focus leaves the centred card for the one to its right.
        momentum.depart(from: card(x: centre, y: 0))
        let first = try XCTUnwrap(momentum.arrive(at: card(x: incoming, y: 0)))
        XCTAssertEqual(first.dx, 1)

        // The rail scrolls that card to the centre. Step two is the same press.
        momentum.depart(from: card(x: centre, y: 0))
        let second = try XCTUnwrap(momentum.arrive(at: card(x: incoming, y: 0)))
        XCTAssertEqual(second.dx, 1, "the second step in a direction must lean like the first")
    }

    func testAnUnmeasuredCardHasNoDirection() {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        XCTAssertNil(momentum.arrive(at: .zero))
    }

    func testResetStartsFresh() {
        let momentum = CardFocusMomentum()
        momentum.depart(from: card(x: 0, y: 0))
        momentum.reset()
        XCTAssertNil(momentum.arrive(at: card(x: 340, y: 0)))
    }
}
#endif
