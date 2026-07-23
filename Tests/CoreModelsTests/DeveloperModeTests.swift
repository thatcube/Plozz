import XCTest
@testable import CoreModels

@MainActor
final class DeveloperModeTests: XCTestCase {
    private func makeStore() -> DeveloperModeStore {
        let suite = "DeveloperModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DeveloperModeStore(defaults: defaults)
    }

    func testDefaultsOff() {
        let model = DeveloperModeModel(store: makeStore())
        XCTAssertFalse(model.isEnabled)
    }

    func testSevenActivationsUnlock() {
        let model = DeveloperModeModel(store: makeStore())
        let base = Date()
        // The first six report progress and leave it off.
        for i in 1...6 {
            let outcome = model.registerUnlockActivation(now: base.addingTimeInterval(Double(i) * 0.2))
            XCTAssertEqual(outcome, .progress(remaining: DeveloperModeModel.requiredActivations - i))
            XCTAssertFalse(model.isEnabled)
        }
        // The seventh crosses the threshold.
        let outcome = model.registerUnlockActivation(now: base.addingTimeInterval(1.4))
        XCTAssertEqual(outcome, .justEnabled)
        XCTAssertTrue(model.isEnabled)
    }

    func testFurtherActivationsWhenEnabledReportAlreadyEnabled() {
        let model = DeveloperModeModel(store: makeStore())
        for _ in 1...DeveloperModeModel.requiredActivations {
            model.registerUnlockActivation(now: Date())
        }
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.registerUnlockActivation(), .alreadyEnabled)
    }

    func testStaleTapsResetTheStreak() {
        let model = DeveloperModeModel(store: makeStore())
        let base = Date()
        // Six quick taps, then a long pause resets the count.
        for i in 1...6 {
            model.registerUnlockActivation(now: base.addingTimeInterval(Double(i) * 0.2))
        }
        XCTAssertFalse(model.isEnabled)
        // A tap far outside the window restarts at 1, so this alone can't unlock.
        let outcome = model.registerUnlockActivation(now: base.addingTimeInterval(60))
        XCTAssertEqual(outcome, .progress(remaining: DeveloperModeModel.requiredActivations - 1))
        XCTAssertFalse(model.isEnabled)
    }

    func testDisableTurnsOffAndPersists() {
        let store = makeStore()
        let model = DeveloperModeModel(store: store)
        for _ in 1...DeveloperModeModel.requiredActivations {
            model.registerUnlockActivation(now: Date())
        }
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(store.loadIsEnabled())

        model.disable()
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(store.loadIsEnabled())
    }

    func testEnabledStatePersistsAcrossModels() {
        let store = makeStore()
        let first = DeveloperModeModel(store: store)
        for _ in 1...DeveloperModeModel.requiredActivations {
            first.registerUnlockActivation(now: Date())
        }
        XCTAssertTrue(first.isEnabled)

        let second = DeveloperModeModel(store: store)
        XCTAssertTrue(second.isEnabled)
    }
}
