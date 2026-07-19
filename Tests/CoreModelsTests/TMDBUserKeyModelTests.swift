import XCTest
@testable import CoreModels

/// Step 9 — the Settings BYOK model's enter / verify / save / replace / remove state
/// machine, exercised without SwiftUI. Validation and credential invalidation are
/// injected stubs so the transitions are deterministic.
@MainActor
final class TMDBUserKeyModelTests: XCTestCase {
    private final class InMemorySecureStoringDouble: SecureStoring, @unchecked Sendable {
        private var storage: [String: String] = [:]
        func setString(_ value: String, for key: String) throws { storage[key] = value }
        func string(for key: String) -> String? { storage[key] }
        func readString(for key: String) throws -> String? { storage[key] }
        func removeValue(for key: String) throws { storage[key] = nil }
    }

    private func makeModel(
        result: TMDBKeyValidationResult = .valid,
        superseded: @escaping @Sendable (String) -> Void = { _ in }
    ) -> TMDBUserKeyModel {
        TMDBUserKeyModel(
            store: TMDBUserKeyStore(secureStore: InMemorySecureStoringDouble()),
            validator: { _ in result },
            onCredentialSuperseded: { token in superseded(token) }
        )
    }

    func testStartsUnconfigured() {
        let model = makeModel()
        XCTAssertFalse(model.isConfigured)
        XCTAssertFalse(model.canSaveDraft)
        XCTAssertEqual(model.verifyState, .idle)
    }

    func testSaveDraftConfiguresAndClearsDraft() async {
        let model = makeModel()
        model.draftKey = "  my-token  "
        XCTAssertTrue(model.canSaveDraft)
        await model.saveDraft()
        XCTAssertTrue(model.isConfigured)
        XCTAssertEqual(model.draftKey, "", "The obscured draft is cleared once saved")
    }

    func testVerifyDraftReportsValid() async {
        let model = makeModel(result: .valid)
        model.draftKey = "good"
        await model.verify()
        XCTAssertEqual(model.verifyState, .valid)
    }

    func testVerifyReportsInvalidAndUnreachable() async {
        let invalid = makeModel(result: .invalid)
        invalid.draftKey = "bad"
        await invalid.verify()
        XCTAssertEqual(invalid.verifyState, .invalid)

        let offline = makeModel(result: .unreachable)
        offline.draftKey = "maybe"
        await offline.verify()
        XCTAssertEqual(offline.verifyState, .unreachable)
    }

    func testVerifyWithNothingEnteredOrStoredIsInvalid() async {
        let model = makeModel(result: .valid)
        await model.verify()
        XCTAssertEqual(model.verifyState, .invalid, "Nothing to verify => invalid, no false positive")
    }

    func testReplacingAKeySupersedesTheOldCredential() async {
        var superseded: [String] = []
        let model = makeModel(superseded: { superseded.append($0) })
        model.draftKey = "first"
        await model.saveDraft()
        XCTAssertEqual(superseded, [], "First save has no prior key to supersede")

        model.draftKey = "second"
        await model.saveDraft()
        XCTAssertEqual(superseded, ["first"], "Replacing supersedes exactly the old key")
    }

    func testRemoveClearsAndSupersedes() async {
        var superseded: [String] = []
        let model = makeModel(superseded: { superseded.append($0) })
        model.draftKey = "token"
        await model.saveDraft()

        await model.remove()
        XCTAssertFalse(model.isConfigured)
        XCTAssertEqual(model.verifyState, .idle)
        XCTAssertEqual(superseded, ["token"], "Removal supersedes the removed key's credential")
    }

    func testSavingSameKeyDoesNotSupersede() async {
        var superseded: [String] = []
        let model = makeModel(superseded: { superseded.append($0) })
        model.draftKey = "same"
        await model.saveDraft()
        model.draftKey = "same"
        await model.saveDraft()
        XCTAssertEqual(superseded, [], "Re-saving the identical key isn't a credential change")
    }
}
