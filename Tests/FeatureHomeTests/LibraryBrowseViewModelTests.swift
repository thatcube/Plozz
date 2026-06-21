import XCTest
import CoreModels
@testable import FeatureHome

@MainActor
final class LibraryBrowseViewModelTests: XCTestCase {
    private func makeVM(itemCount: Int, pageSize: Int = 10) -> (LibraryBrowseViewModel, FakeMediaProvider) {
        let provider = FakeMediaProvider(allItems: makeItems(itemCount))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: pageSize)
        return (vm, provider)
    }

    func testLoadFirstPageLoadsOnlyOnePage() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        XCTAssertEqual(vm.items.count, 10)
        XCTAssertEqual(vm.totalCount, 100)
        XCTAssertTrue(vm.canLoadMore)
        XCTAssertEqual(provider.requestedPages.count, 1)
        XCTAssertEqual(provider.requestedPages.first?.startIndex, 0)
        XCTAssertNotNil(vm.state.value)
    }

    func testLoadMoreAppendsNextPage() async {
        let (vm, _) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        // Focusing the last loaded item should pull the next page.
        await vm.loadMoreIfNeeded(currentItemID: vm.items.last!.id)

        XCTAssertEqual(vm.items.count, 20)
        XCTAssertEqual(vm.items.map(\.id).prefix(11).last, "i10")
        XCTAssertTrue(vm.canLoadMore)
    }

    func testEarlyItemDoesNotTriggerPrefetch() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        await vm.loadMoreIfNeeded(currentItemID: vm.items.first!.id)

        XCTAssertEqual(vm.items.count, 10)
        XCTAssertEqual(provider.requestedPages.count, 1)
    }

    func testPagingStopsAtTotalCount() async {
        let (vm, _) = makeVM(itemCount: 25, pageSize: 10)
        await vm.loadFirstPage()

        // Page until exhausted.
        for _ in 0..<5 {
            await vm.loadMoreIfNeeded(currentItemID: vm.items.last!.id)
        }

        XCTAssertEqual(vm.items.count, 25)
        XCTAssertFalse(vm.canLoadMore)
        // Further requests are no-ops once everything is loaded.
        await vm.loadMoreIfNeeded(currentItemID: vm.items.last!.id)
        XCTAssertEqual(vm.items.count, 25)
    }

    func testEmptyLibraryReportsEmptyState() async {
        let (vm, _) = makeVM(itemCount: 0, pageSize: 10)
        await vm.loadFirstPage()

        if case .empty = vm.state {} else {
            XCTFail("Expected empty state, got \(vm.state)")
        }
        XCTAssertFalse(vm.canLoadMore)
    }

    func testFirstPageFailureSetsFailedState() async {
        let provider = FakeMediaProvider(allItems: makeItems(100))
        provider.failAtStartIndex = 0
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: 10)

        await vm.loadFirstPage()

        if case .failed(.serverUnreachable) = vm.state {} else {
            XCTFail("Expected failed state, got \(vm.state)")
        }
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testNextPageFailureKeepsLoadedItems() async {
        let provider = FakeMediaProvider(allItems: makeItems(100))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: 10)
        await vm.loadFirstPage()

        provider.failAtStartIndex = 10
        await vm.loadMoreIfNeeded(currentItemID: vm.items.last!.id)

        // Existing page survives; error is surfaced separately.
        XCTAssertEqual(vm.items.count, 10)
        XCTAssertEqual(vm.pageError, .serverUnreachable)
        XCTAssertNotNil(vm.state.value)

        // Prefetch is suppressed while an error is pending; retry recovers it.
        await vm.loadMoreIfNeeded(currentItemID: vm.items.last!.id)
        XCTAssertEqual(vm.items.count, 10)

        await vm.retryNextPage()
        XCTAssertEqual(vm.items.count, 20)
        XCTAssertNil(vm.pageError)
    }
}
