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

    /// A store whose save/remove can be made to throw, to prove the model only flips its
    /// opt-in/opt-out state when the write actually persisted.
    private final class FailingKeyStore: TMDBUserKeyStoring, @unchecked Sendable {
        struct Boom: Error {}
        var stored: String?
        var failWrites: Bool
        var supersededCount = 0
        init(stored: String? = nil, failWrites: Bool) {
            self.stored = stored
            self.failWrites = failWrites
        }
        func load() -> String? { stored }
        func save(_ token: String) throws {
            if failWrites { throw Boom() }
            stored = token
        }
        func remove() throws {
            if failWrites { throw Boom() }
            stored = nil
        }
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

    func testSaveFailureDoesNotFlipConfiguredAndSurfacesError() async {
        var superseded = 0
        let store = FailingKeyStore(failWrites: true)
        let model = TMDBUserKeyModel(
            store: store,
            validator: { _ in .valid },
            onCredentialSuperseded: { _ in superseded += 1 }
        )
        model.draftKey = "token"
        await model.saveDraft()
        XCTAssertFalse(model.isConfigured, "A failed Keychain write must not claim the key was saved")
        XCTAssertNil(store.stored, "Nothing persisted")
        XCTAssertNotNil(model.storageErrorMessage, "The failure is surfaced")
        XCTAssertEqual(model.draftKey, "token", "The draft is kept so the user can retry")
        XCTAssertEqual(superseded, 0)
    }

    func testRemoveFailureKeepsConfiguredAndSurfacesError() async {
        var superseded = 0
        // A key is stored, but the delete will fail.
        let store = FailingKeyStore(stored: "token", failWrites: true)
        let model = TMDBUserKeyModel(
            store: store,
            validator: { _ in .valid },
            onCredentialSuperseded: { _ in superseded += 1 }
        )
        XCTAssertTrue(model.isConfigured)
        await model.remove()
        XCTAssertTrue(model.isConfigured, "A failed delete must not claim the key was removed")
        XCTAssertEqual(store.stored, "token", "The key genuinely remains — no silent re-activation")
        XCTAssertNotNil(model.storageErrorMessage)
        XCTAssertEqual(superseded, 0, "No credential change when the removal didn't persist")
    }

    func testSuccessfulWriteClearsAPriorStorageError() async {
        let store = FailingKeyStore(failWrites: true)
        let model = TMDBUserKeyModel(store: store)
        model.draftKey = "token"
        await model.saveDraft()
        XCTAssertNotNil(model.storageErrorMessage)
        // Recover: writes now succeed.
        store.failWrites = false
        model.draftKey = "token"
        await model.saveDraft()
        XCTAssertTrue(model.isConfigured)
        XCTAssertNil(model.storageErrorMessage, "A subsequent successful write clears the error")
    }
}
