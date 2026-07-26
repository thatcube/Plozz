import XCTest
@testable import ProviderShare

/// The budget policy is the answer to "one constant cannot suit both an Apple TV
/// HD and an M-series iPad". These pin the properties that make it safe on the
/// weak device and useful on the strong one.
final class ShareMetadataBudgetTests: XCTestCase {

    private struct FakeProcessInfo: ProcessInfoReading {
        var thermalState: ProcessInfo.ThermalState = .nominal
        var isLowPowerModeEnabled: Bool = false
        var activeProcessorCount: Int = 8
    }

    // MARK: - Device sizing

    func testMoreCoresEarnALargerSlice() {
        let weak = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(activeProcessorCount: 2)
        )
        let strong = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(activeProcessorCount: 10)
        )
        XCTAssertGreaterThan(strong.itemsPerSlice, weak.itemsPerSlice)
    }

    /// Progress must stay perceptible on the weakest supported hardware — a
    /// budget that rounds to zero would make a large library look stuck.
    func testEvenTheWeakestDeviceKeepsMakingProgress() {
        let budget = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(activeProcessorCount: 1)
        )
        XCTAssertGreaterThanOrEqual(
            budget.itemsPerSlice, ShareMetadataBudget.minimumItemsPerSlice
        )
    }

    /// Past a point the limit is the provider's rate limit and share I/O, not the
    /// CPU — so a very wide device must not scale without bound.
    func testAVeryWideDeviceIsStillCapped() {
        let budget = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(activeProcessorCount: 64)
        )
        XCTAssertLessThanOrEqual(
            budget.itemsPerSlice, ShareMetadataBudget.maximumItemsPerSlice
        )
    }

    // MARK: - Device state overrides capability

    func testThermalPressureOverridesCoreCount() {
        let hot = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(thermalState: .serious, activeProcessorCount: 16)
        )
        let cool = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(activeProcessorCount: 16)
        )
        XCTAssertLessThan(hot.itemsPerSlice, cool.itemsPerSlice)
        XCTAssertGreaterThan(
            hot.delayBetweenSlices, cool.delayBetweenSlices,
            "a hot device must also back off between slices, not just shrink them"
        )
    }

    func testCriticalThermalStateBacksOffHardest() {
        let critical = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(thermalState: .critical, activeProcessorCount: 16)
        )
        let serious = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(thermalState: .serious, activeProcessorCount: 16)
        )
        XCTAssertGreaterThan(critical.delayBetweenSlices, serious.delayBetweenSlices)
    }

    /// Low Power Mode is the user explicitly asking for less work.
    func testLowPowerModeIsRespected() {
        let saving = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(isLowPowerModeEnabled: true, activeProcessorCount: 16)
        )
        let normal = ShareMetadataBudget.forCurrentDevice(
            processInfo: FakeProcessInfo(activeProcessorCount: 16)
        )
        XCTAssertLessThan(saving.itemsPerSlice, normal.itemsPerSlice)
    }

    func testConstrainedReportingMatchesTheOverrides() {
        XCTAssertTrue(ShareMetadataBudget.isConstrained(
            processInfo: FakeProcessInfo(thermalState: .serious)))
        XCTAssertTrue(ShareMetadataBudget.isConstrained(
            processInfo: FakeProcessInfo(thermalState: .critical)))
        XCTAssertTrue(ShareMetadataBudget.isConstrained(
            processInfo: FakeProcessInfo(isLowPowerModeEnabled: true)))
        XCTAssertFalse(ShareMetadataBudget.isConstrained(processInfo: FakeProcessInfo()))
    }

    // MARK: - Feedback

    /// The point of the loop: a device slower than its core count implied is
    /// DISCOVERED, not assumed.
    func testOverrunningTheBudgetShrinksIt() {
        let budget = ShareMetadataBudget(
            itemsPerSlice: 32, sliceDuration: .seconds(2), delayBetweenSlices: .zero
        )
        let next = budget.adjusted(after: .seconds(5), attempted: 32)
        XCTAssertLessThan(next.itemsPerSlice, budget.itemsPerSlice)
    }

    func testComfortablyFinishingAFullSliceGrowsIt() {
        let budget = ShareMetadataBudget(
            itemsPerSlice: 8, sliceDuration: .seconds(2), delayBetweenSlices: .zero
        )
        let next = budget.adjusted(after: .milliseconds(400), attempted: 8)
        XCTAssertGreaterThan(next.itemsPerSlice, budget.itemsPerSlice)
    }

    /// Shrink must outpace growth, or a device near its limit oscillates instead
    /// of settling.
    func testShrinkIsFasterThanGrowth() {
        let start = ShareMetadataBudget(
            itemsPerSlice: 16, sliceDuration: .seconds(2), delayBetweenSlices: .zero
        )
        let grown = start.adjusted(after: .milliseconds(100), attempted: 16).itemsPerSlice - 16
        let shrunk = 16 - start.adjusted(after: .seconds(9), attempted: 16).itemsPerSlice
        XCTAssertGreaterThan(shrunk, grown)
    }

    func testFeedbackNeverGoesBelowTheFloor() {
        var budget = ShareMetadataBudget(
            itemsPerSlice: ShareMetadataBudget.minimumItemsPerSlice,
            sliceDuration: .seconds(2),
            delayBetweenSlices: .zero
        )
        for _ in 0..<10 {
            budget = budget.adjusted(after: .seconds(30), attempted: 4)
        }
        XCTAssertEqual(budget.itemsPerSlice, ShareMetadataBudget.minimumItemsPerSlice)
    }

    func testFeedbackNeverExceedsTheCeiling() {
        var budget = ShareMetadataBudget(
            itemsPerSlice: ShareMetadataBudget.maximumItemsPerSlice,
            sliceDuration: .seconds(2),
            delayBetweenSlices: .zero
        )
        for _ in 0..<10 {
            budget = budget.adjusted(
                after: .milliseconds(1),
                attempted: ShareMetadataBudget.maximumItemsPerSlice
            )
        }
        XCTAssertEqual(budget.itemsPerSlice, ShareMetadataBudget.maximumItemsPerSlice)
    }

    /// A slice that attempted nothing says nothing about capacity — usually it was
    /// blocked rather than slow — so it must not move the budget in either
    /// direction.
    func testAnEmptySliceIsNotEvidence() {
        let budget = ShareMetadataBudget(
            itemsPerSlice: 16, sliceDuration: .seconds(2), delayBetweenSlices: .zero
        )
        XCTAssertEqual(budget.adjusted(after: .seconds(60), attempted: 0), budget)
    }

    /// A partially-filled slice means the QUEUE ran dry, not that the device is
    /// fast — growing on it would inflate the budget on an almost-complete
    /// library and then overrun the moment real work arrived.
    func testAPartialSliceDoesNotGrowTheBudget() {
        let budget = ShareMetadataBudget(
            itemsPerSlice: 16, sliceDuration: .seconds(2), delayBetweenSlices: .zero
        )
        let next = budget.adjusted(after: .milliseconds(50), attempted: 2)
        XCTAssertEqual(next.itemsPerSlice, budget.itemsPerSlice)
    }
}
