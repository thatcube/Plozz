import XCTest
import CoreModels
@testable import FeatureAuthCore

final class CredentialMutationJournalTests: XCTestCase {
    private let oldRevision = CredentialRevision(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    private let newRevision = CredentialRevision(
        rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )
    private let mutationID = UUID(
        uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    )!

    func testPrepareAtomicallySwitchesActiveRevisionAndSurvivesRelaunch() throws {
        let durable = try makeDurableStore()
        let journal = try CredentialMutationJournal(store: durable)
        try journal.seedActiveRevision(oldRevision, accountID: "account")
        let staged = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID
        )

        XCTAssertEqual(staged.phase, .staged)
        XCTAssertEqual(try journal.activeRevision(accountID: "account"), oldRevision)

        let prepared = try journal.markPrepared(mutationID)
        XCTAssertEqual(prepared.phase, .prepared)
        XCTAssertEqual(try journal.activeRevision(accountID: "account"), newRevision)

        let relaunched = try CredentialMutationJournal(store: durable)
        XCTAssertEqual(try relaunched.activeRevision(accountID: "account"), newRevision)
        XCTAssertEqual(try relaunched.mutations().first?.phase, .prepared)
    }

    func testCommittedMutationFinishesOnlyAfterExplicitCleanupBoundary() throws {
        let journal = try seededJournal()
        _ = try journal.begin(
            kind: .trustReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID
        )
        _ = try journal.markPrepared(mutationID)
        let committed = try journal.markCommitted(mutationID)

        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(try journal.mutations().count, 1)
        try journal.finishCommitted(mutationID)
        XCTAssertTrue(try journal.mutations().isEmpty)
        XCTAssertEqual(try journal.activeRevision(accountID: "account"), newRevision)
    }

    func testStagedMutationCanRollbackWithoutMovingPointer() throws {
        let journal = try seededJournal()
        _ = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID
        )

        let rolledBack = try journal.rollbackStaged(mutationID)

        XCTAssertEqual(rolledBack.phase, .staged)
        XCTAssertTrue(try journal.mutations().isEmpty)
        XCTAssertEqual(try journal.activeRevision(accountID: "account"), oldRevision)
    }

    func testPreparedMutationCannotRollback() throws {
        let journal = try seededJournal()
        _ = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID
        )
        _ = try journal.markPrepared(mutationID)

        XCTAssertThrowsError(try journal.rollbackStaged(mutationID)) { error in
            XCTAssertEqual(
                error as? CredentialMutationJournalError,
                .invalidTransition
            )
        }
    }

    func testRecoveryRollsBackOnlyStagedAndCompletesPreparedOrCommitted() throws {
        let journal = try CredentialMutationJournal(store: makeDurableStore())
        try journal.seedActiveRevision(oldRevision, accountID: "staged-account")
        try journal.seedActiveRevision(oldRevision, accountID: "prepared-account")
        try journal.seedActiveRevision(oldRevision, accountID: "committed-account")
        let stagedID = UUID()
        let preparedID = UUID()
        let committedID = UUID()

        _ = try journal.begin(
            kind: .credentialReplacement,
            accountID: "staged-account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: stagedID
        )
        _ = try journal.begin(
            kind: .credentialReplacement,
            accountID: "prepared-account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: preparedID
        )
        _ = try journal.markPrepared(preparedID)
        _ = try journal.begin(
            kind: .credentialReplacement,
            accountID: "committed-account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: committedID
        )
        _ = try journal.markPrepared(committedID)
        _ = try journal.markCommitted(committedID)

        let actions = try journal.recoveryActions()

        XCTAssertTrue(actions.contains {
            if case .rollbackPending(let entry) = $0 { return entry.id == stagedID }
            return false
        })
        XCTAssertTrue(actions.contains {
            if case .completeCommitted(let entry) = $0 { return entry.id == preparedID }
            return false
        })
        XCTAssertTrue(actions.contains {
            if case .completeCommitted(let entry) = $0 { return entry.id == committedID }
            return false
        })
    }

    func testAccountRemovalPrepareAtomicallyClearsActivePointer() throws {
        let journal = try seededJournal()
        _ = try journal.begin(
            kind: .accountRemoval,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: nil,
            mutationID: mutationID
        )

        _ = try journal.markPrepared(mutationID)

        XCTAssertNil(try journal.activeRevision(accountID: "account"))
    }

    func testGeneratedKeyPromotionRequiresChildItemReference() throws {
        let journal = try seededJournal()

        XCTAssertThrowsError(
            try journal.begin(
                kind: .generatedKeyPromotion,
                accountID: "account",
                previousRevision: oldRevision,
                pendingRevision: newRevision,
                mutationID: mutationID
            )
        ) { error in
            XCTAssertEqual(
                error as? CredentialMutationJournalError,
                .invalidMutation
            )
        }

        let keyID = try CredentialChildItemID(rawValue: "key.account.new")
        let entry = try journal.begin(
            kind: .generatedKeyPromotion,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            pendingChildItemIDs: [keyID],
            mutationID: mutationID
        )
        XCTAssertEqual(entry.pendingChildItemIDs, [keyID])
    }

    func testActiveRevisionConflictAndConcurrentAccountMutationFailClosed() throws {
        let journal = try seededJournal()
        XCTAssertThrowsError(
            try journal.begin(
                kind: .credentialReplacement,
                accountID: "account",
                previousRevision: nil,
                pendingRevision: newRevision
            )
        ) { error in
            XCTAssertEqual(
                error as? CredentialMutationJournalError,
                .activeRevisionConflict
            )
        }

        _ = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID
        )
        XCTAssertThrowsError(
            try journal.begin(
                kind: .trustReplacement,
                accountID: "account",
                previousRevision: oldRevision,
                pendingRevision: CredentialRevision()
            )
        ) { error in
            XCTAssertEqual(
                error as? CredentialMutationJournalError,
                .mutationAlreadyInProgress
            )
        }
    }

    func testBeginIsIdempotentByMutationIdentity() throws {
        let journal = try seededJournal()
        let first = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let retry = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(retry, first)
        XCTAssertEqual(try journal.mutations().count, 1)

        _ = try journal.markPrepared(mutationID)
        let preparedRetry = try journal.begin(
            kind: .credentialReplacement,
            accountID: "account",
            previousRevision: oldRevision,
            pendingRevision: newRevision,
            mutationID: mutationID
        )
        XCTAssertEqual(preparedRetry.phase, .prepared)
    }

    func testSeparateJournalInstancesMergeAgainstLatestPersistedState() throws {
        let durable = try makeDurableStore()
        let first = try CredentialMutationJournal(store: durable)
        let second = try CredentialMutationJournal(store: durable)

        try first.seedActiveRevision(oldRevision, accountID: "account-a")
        try second.seedActiveRevision(newRevision, accountID: "account-b")

        XCTAssertEqual(try first.activeRevision(accountID: "account-a"), oldRevision)
        XCTAssertEqual(try first.activeRevision(accountID: "account-b"), newRevision)
        XCTAssertEqual(try second.activeRevision(accountID: "account-a"), oldRevision)
        XCTAssertEqual(try second.activeRevision(accountID: "account-b"), newRevision)
    }

    func testMutationDescriptionRedactsIdentifiersAndRevisions() throws {
        let journal = try seededJournal()
        let entry = try journal.begin(
            kind: .credentialReplacement,
            accountID: "private-account",
            previousRevision: nil,
            pendingRevision: newRevision,
            mutationID: mutationID
        )

        XCTAssertFalse(entry.description.contains("private-account"))
        XCTAssertFalse(String(reflecting: entry).contains(newRevision.rawValue.uuidString))
    }

    private func seededJournal() throws -> CredentialMutationJournal {
        let journal = try CredentialMutationJournal(store: makeDurableStore())
        try journal.seedActiveRevision(oldRevision, accountID: "account")
        return journal
    }

    private func makeDurableStore() throws -> DurableLocalStateStore {
        try DurableLocalStateStore(secureStore: InMemorySecureStore())
    }
}
