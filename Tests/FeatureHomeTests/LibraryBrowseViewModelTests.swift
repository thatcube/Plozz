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

    func testLoadFirstPageSizesGridToTotalAndLoadsOnlyFirstPage() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        XCTAssertEqual(vm.totalCount, 100)
        XCTAssertEqual(vm.loaded.count, 100, "Grid is sized to the whole library up front")
        XCTAssertEqual(vm.loadedCount, 10, "Only the first page is populated")
        XCTAssertEqual(vm.state.value, 100)
        XCTAssertNotNil(vm.item(at: 0))
        XCTAssertNil(vm.item(at: 10), "Later items are placeholders until their page loads")
        XCTAssertEqual(provider.requestedPages.count, 1)
        XCTAssertEqual(provider.requestedPages.first?.startIndex, 0)
    }

    func testItemAppearedLoadsOwningPage() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        // A cell in the third page (indices 20..29) appears.
        await vm.itemAppeared(at: 20)

        XCTAssertNotNil(vm.item(at: 20))
        XCTAssertNotNil(vm.item(at: 29))
        XCTAssertEqual(vm.item(at: 20)?.id, "i20")
        XCTAssertTrue(provider.requestedPages.contains { $0.startIndex == 20 })
    }

    func testBackHalfOfPagePrefetchesNextPage() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        // Index 5 is in the back half of page 0, so page 1 is prefetched.
        await vm.itemAppeared(at: 5)

        XCTAssertTrue(provider.requestedPages.contains { $0.startIndex == 10 })
        XCTAssertNotNil(vm.item(at: 12))
    }

    func testFrontHalfOfPageDoesNotPrefetch() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        // Index 1 is in the front half of page 0; nothing new is fetched
        // (page 0 already loaded).
        await vm.itemAppeared(at: 1)

        XCTAssertEqual(provider.requestedPages.count, 1)
    }

    func testRepeatedAppearLoadsEachPageOnce() async {
        let (vm, provider) = makeVM(itemCount: 100, pageSize: 10)
        await vm.loadFirstPage()

        await vm.itemAppeared(at: 20)
        await vm.itemAppeared(at: 21)
        await vm.itemAppeared(at: 22)

        let page2Requests = provider.requestedPages.filter { $0.startIndex == 20 }
        XCTAssertEqual(page2Requests.count, 1, "A loaded page is never re-requested")
    }

    func testAppearingOutOfRangeIsIgnored() async {
        let (vm, provider) = makeVM(itemCount: 25, pageSize: 10)
        await vm.loadFirstPage()

        await vm.itemAppeared(at: 999)

        XCTAssertEqual(provider.requestedPages.count, 1)
    }

    func testEmptyLibraryReportsEmptyState() async {
        let (vm, _) = makeVM(itemCount: 0, pageSize: 10)
        await vm.loadFirstPage()

        if case .empty = vm.state {} else {
            XCTFail("Expected empty state, got \(vm.state)")
        }
        XCTAssertEqual(vm.totalCount, 0)
        XCTAssertTrue(vm.loaded.isEmpty)
    }

    func testFirstPageFailureSetsFailedState() async {
        let provider = FakeMediaProvider(allItems: makeItems(100))
        provider.failAtStartIndex = 0
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: 10)

        await vm.loadFirstPage()

        if case .failed(.serverUnreachable) = vm.state {} else {
            XCTFail("Expected failed state, got \(vm.state)")
        }
        XCTAssertTrue(vm.loaded.isEmpty)
    }

    func testPageFailureKeepsLoadedItemsAndRetriesOnReappear() async {
        let provider = FakeMediaProvider(allItems: makeItems(100))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: 10)
        await vm.loadFirstPage()

        provider.failAtStartIndex = 20
        await vm.itemAppeared(at: 20)

        // First page survives; the failure is surfaced separately.
        XCTAssertNotNil(vm.item(at: 0))
        XCTAssertNil(vm.item(at: 20))
        XCTAssertEqual(vm.pageError, .serverUnreachable)
        XCTAssertEqual(vm.state.value, 100)

        // The failed page is not marked loaded, so a reappear retries it.
        await vm.itemAppeared(at: 20)
        XCTAssertNotNil(vm.item(at: 20))
        XCTAssertNil(vm.pageError)
    }

    // MARK: Sorting

    private func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "LibraryBrowseSortTests-\(UUID().uuidString)")!
        return defaults
    }

    func testDefaultSortIsNameAscending() {
        let provider = FakeMediaProvider(allItems: makeItems(10))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, defaults: isolatedDefaults())
        XCTAssertEqual(vm.sort, .default)
    }

    func testSetSortReloadsFirstPageWithNewSortAndResetsPaging() async {
        let provider = FakeMediaProvider(allItems: makeItems(100))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: 10, defaults: isolatedDefaults())
        await vm.loadFirstPage()
        await vm.itemAppeared(at: 20) // load a later page so paging state is non-trivial

        let newSort = CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        await vm.setSort(newSort)

        XCTAssertEqual(vm.sort, newSort)
        // Paging restarts: only the first page is loaded again under the new sort.
        XCTAssertEqual(vm.loadedCount, 10)
        XCTAssertNil(vm.item(at: 20), "Previously loaded later pages are cleared on re-sort")
        let lastRequest = provider.requestedPages.last
        XCTAssertEqual(lastRequest?.startIndex, 0, "Re-sort reloads from the first page, not the whole library")
        XCTAssertEqual(lastRequest?.sort, newSort)
    }

    func testSetSortToCurrentValueIsNoOp() async {
        let provider = FakeMediaProvider(allItems: makeItems(50))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, pageSize: 10, defaults: isolatedDefaults())
        await vm.loadFirstPage()
        let requestsBefore = provider.requestedPages.count

        await vm.setSort(.default)

        XCTAssertEqual(provider.requestedPages.count, requestsBefore, "Re-applying the same sort does not reload")
    }

    func testSortPersistsAndIsRestoredPerContainerKind() async {
        let defaults = isolatedDefaults()
        let chosen = CoreModels.SortDescriptor(field: .communityRating, direction: .descending)

        let provider = FakeMediaProvider(allItems: makeItems(10))
        let vm = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, defaults: defaults)
        await vm.setSort(chosen)

        // A fresh VM for the same kind restores the persisted choice.
        let restored = LibraryBrowseViewModel(provider: provider, containerID: "lib1", containerKind: .movie, defaults: defaults)
        XCTAssertEqual(restored.sort, chosen)

        // A different kind keeps its own default.
        let otherKind = LibraryBrowseViewModel(provider: provider, containerID: "lib2", containerKind: .series, defaults: defaults)
        XCTAssertEqual(otherKind.sort, .default)
    }
}
