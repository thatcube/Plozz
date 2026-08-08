import XCTest
@testable import CoreModels

/// The generic reorder-and-hide model shared by the metadata-provider priority
/// list and the navigation-library arrangement.
final class OrderedVisibilityListTests: XCTestCase {
    private typealias Sections = OrderedVisibilityList.Sections<String>

    // MARK: stepped (the tvOS lift-and-step interaction)

    func testStepUpRaisesPriority() {
        let start = Sections(enabled: ["a", "b", "c"], disabled: [])
        XCTAssertEqual(
            OrderedVisibilityList.stepped("c", up: true, in: start),
            Sections(enabled: ["a", "c", "b"], disabled: [])
        )
    }

    func testStepAtTheVeryTopOrBottomIsANoOp() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        XCTAssertEqual(OrderedVisibilityList.stepped("a", up: true, in: start), start)
        XCTAssertEqual(OrderedVisibilityList.stepped("z", up: false, in: start), start)
    }

    func testSteppingDownAcrossTheDividerDisablesAtTheTopOfDisabled() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        XCTAssertEqual(
            OrderedVisibilityList.stepped("b", up: false, in: start),
            Sections(enabled: ["a"], disabled: ["b", "z"])
        )
    }

    func testSteppingUpAcrossTheDividerEnablesAtTheBottomOfEnabled() {
        let start = Sections(enabled: ["a"], disabled: ["z", "y"])
        XCTAssertEqual(
            OrderedVisibilityList.stepped("z", up: true, in: start),
            Sections(enabled: ["a", "z"], disabled: ["y"])
        )
    }

    func testSteppingAnUnknownElementIsANoOp() {
        let start = Sections(enabled: ["a"], disabled: [])
        XCTAssertEqual(OrderedVisibilityList.stepped("nope", up: true, in: start), start)
    }

    // MARK: moving (the iOS drag interaction)

    func testDraggingAcrossTheDividerDisables() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        // Flattened: [a, b, divider, z]; drop "a" at the end.
        let moved = OrderedVisibilityList.moving(fromOffsets: [0], toOffset: 4, in: start)
        XCTAssertEqual(moved, Sections(enabled: ["b"], disabled: ["z", "a"]))
    }

    func testDraggingTheDividerItselfIsRejected() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        XCTAssertEqual(OrderedVisibilityList.moving(fromOffsets: [2], toOffset: 0, in: start), start)
    }

    func testDraggingIntoTheEmptyDisabledPlaceholderDisables() {
        let start = Sections(enabled: ["a", "b"], disabled: [])
        // Flattened: [a, b, divider, placeholder]; drop "b" at the very end.
        let moved = OrderedVisibilityList.moving(fromOffsets: [1], toOffset: 4, in: start)
        XCTAssertEqual(moved, Sections(enabled: ["a"], disabled: ["b"]))
    }

    // MARK: resolving

    func testResolvingAppendsUnknownElementsEnabledAndDropsStaleOnes() {
        let resolved = OrderedVisibilityList.resolving(
            available: ["a", "b", "c"],
            order: ["c", "gone", "a"],
            hidden: ["b", "alsoGone"]
        )
        XCTAssertEqual(resolved.enabled, ["c", "a"])
        XCTAssertEqual(resolved.disabled, ["b"])
    }

    func testResolvingIgnoresDuplicatesInThePersistedOrder() {
        let resolved = OrderedVisibilityList.resolving(
            available: ["a", "b"],
            order: ["b", "b", "a"],
            hidden: []
        )
        XCTAssertEqual(resolved.enabled, ["b", "a"])
    }

    // MARK: listItems

    func testListItemsInsertAPlaceholderOnlyWhenNothingIsDisabled() {
        XCTAssertEqual(
            OrderedVisibilityList.listItems(for: Sections(enabled: ["a"], disabled: [])),
            [.element("a"), .divider, .disabledPlaceholder]
        )
        XCTAssertEqual(
            OrderedVisibilityList.listItems(for: Sections(enabled: ["a"], disabled: ["z"])),
            [.element("a"), .divider, .element("z")]
        )
    }
}
