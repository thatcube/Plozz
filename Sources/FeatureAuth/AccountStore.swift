import Foundation
import CoreModels
import CoreNetworking

/// Persists household accounts while keeping all credential bytes in the
/// user-independent Keychain.
public protocol AccountPersisting: Sendable {
    func deviceID() -> String
    func loadAccounts() -> [Account]
    func activeAccountIDs() -> [String]
    func setActiveAccountIDs(_ ids: [String])
    func token(for accountID: String) -> String?
    func mediaShareCredential(for accountID: String) throws -> MediaShareCredentialEnvelope
    func mediaShareCredential(
        for accountID: String,
        revision: CredentialRevision
    ) throws -> MediaShareCredentialEnvelope
    func add(_ account: Account, token: String) throws
    func addMediaShare(
        _ account: Account,
        credential: MediaShareCredentialEnvelope,
        generatedPrivateKey: String?
    ) throws
    func remove(id: String) throws
    func clearAll() throws
    func recoverCredentialMutations() throws
}

public enum AccountStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
    case invalidMediaShareAccount
    case generatedKeyReuse
    case generatedPrivateKeyRequired
    case mediaShareCredentialInfrastructureUnavailable
    case mediaShareCredentialInvariantViolation
}

/// Household account persistence and the commit boundary for media-share
/// credentials.
///
/// Managed-provider bearer tokens retain their existing one-item-per-account
/// Keychain layout. Media-share credentials use immutable vault revisions plus
/// a durable active-revision journal. Account metadata is visible only when its
/// revision matches that journal, preventing a crash from exposing a partially
/// committed share.
public final class AccountStore: AccountPersisting, @unchecked Sendable {
    private let secureStore: SecureStore
    private let mediaCredentialVault: MediaCredentialVault?
    private let credentialJournal: CredentialMutationJournal?
    private let lock = NSLock()
    /// Account metadata is one shared JSON value. Serialize complete mutations
    /// across AccountStore instances so two successful transactions cannot replace
    /// that value from stale snapshots and silently drop each other's accounts.
    private static let processMutationLock = NSLock()

    // This is intentionally a new, migration-free schema. The app is still in
    // tester-only distribution, so old account records are ignored and users
    // re-enter credentials instead of carrying upgrade code indefinitely.
    private let accountsKey = "com.plozz.accounts.v2"
    private let activeIDsKey = "com.plozz.accounts.activeIDs.v2"
    private let deviceIDKey = "com.plozz.session.deviceID"
    private let tokenAccountPrefix = "com.plozz.account.token."

    #if canImport(Security)
    public init(
        secureStore: SecureStore = KeychainStore(),
        mediaCredentialVault: MediaCredentialVault? = nil,
        credentialJournal: CredentialMutationJournal? = nil
    ) {
        self.secureStore = secureStore
        self.mediaCredentialVault = mediaCredentialVault
        self.credentialJournal = credentialJournal
    }
    #else
    public init(
        secureStore: SecureStore,
        mediaCredentialVault: MediaCredentialVault? = nil,
        credentialJournal: CredentialMutationJournal? = nil
    ) {
        self.secureStore = secureStore
        self.mediaCredentialVault = mediaCredentialVault
        self.credentialJournal = credentialJournal
    }
    #endif

    public func deviceID() -> String {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        if let existing = secureStore.string(for: deviceIDKey) {
            return existing
        }
        let generated = UUID().uuidString
        do {
            try secureStore.setString(generated, for: deviceIDKey)
        } catch {
            PlozzLog.auth.error("Unable to persist device identifier")
        }
        return generated
    }

    public func loadAccounts() -> [Account] {
        lock.lock()
        defer { lock.unlock() }
        return visibleAccountsLocked()
    }

    public func activeAccountIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let accounts = visibleAccountsLocked()
        let known = Set(accounts.map(\.id))
        guard let ids = decodeIDs(secureStore.string(for: activeIDsKey)) else {
            return accounts.map(\.id)
        }
        return ids.filter { known.contains($0) }
    }

    public func setActiveAccountIDs(_ ids: [String]) {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        let known = Set(visibleAccountsLocked().map(\.id))
        persistActiveLocked(ids.filter { known.contains($0) })
    }

    public func token(for accountID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let account = persistedAccountsLocked().first(where: { $0.id == accountID }) else {
            return nil
        }
        guard account.server.provider == .mediaShare else {
            return secureStore.string(for: tokenKey(accountID))
        }
        guard let credential = try? mediaShareCredentialLocked(for: account) else {
            return nil
        }
        switch credential.authentication {
        case .anonymous, .noCredentials:
            return ""
        case .password(_, let password):
            return password
        case .bearer(let token):
            return token
        case .generatedKey:
            return nil
        }
    }

    public func mediaShareCredential(
        for accountID: String
    ) throws -> MediaShareCredentialEnvelope {
        lock.lock()
        defer { lock.unlock() }
        guard let account = try persistedAccountsLockedThrowing().first(where: { $0.id == accountID }),
              account.server.provider == .mediaShare else {
            throw AccountStoreError.invalidMediaShareAccount
        }
        return try mediaShareCredentialLocked(for: account)
    }

    public func mediaShareCredential(
        for accountID: String,
        revision: CredentialRevision
    ) throws -> MediaShareCredentialEnvelope {
        lock.lock()
        defer { lock.unlock() }
        guard let account = try persistedAccountsLockedThrowing().first(where: { $0.id == accountID }),
              account.server.provider == .mediaShare else {
            throw AccountStoreError.invalidMediaShareAccount
        }
        guard account.credentialRevision == revision else {
            throw AccountStoreError.mediaShareCredentialInvariantViolation
        }
        return try mediaShareCredentialLocked(for: account)
    }

    public func add(_ account: Account, token: String) throws {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        if account.server.provider == .mediaShare {
            let credential = try legacySMBInputCredential(account: account, password: token)
            try addMediaShareLocked(
                account,
                credential: credential,
                generatedPrivateKey: nil
            )
        } else {
            try addManagedAccountLocked(account, token: token)
        }
    }

    public func addMediaShare(
        _ account: Account,
        credential: MediaShareCredentialEnvelope,
        generatedPrivateKey: String? = nil
    ) throws {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try addMediaShareLocked(
            account,
            credential: credential,
            generatedPrivateKey: generatedPrivateKey
        )
    }

    public func remove(id: String) throws {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        try removeLocked(id: id)
    }

    public func clearAll() throws {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        for account in try persistedAccountsLockedThrowing() {
            try removeLocked(id: account.id)
        }
        try secureStore.removeValue(for: accountsKey)
        try secureStore.removeValue(for: activeIDsKey)
        PlozzLog.auth.info("Cleared all accounts")
    }

    public func recoverCredentialMutations() throws {
        Self.processMutationLock.lock()
        defer { Self.processMutationLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        if mediaCredentialVault == nil, credentialJournal == nil {
            return
        }
        try recoverCredentialMutationsLocked()
    }

    private func addManagedAccountLocked(_ account: Account, token: String) throws {
        var accounts = try persistedAccountsLockedThrowing()
        var persistedAccount = account
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let existing = accounts[index]
            let existingToken = secureStore.string(for: tokenKey(account.id))
            persistedAccount.credentialRevision = existingToken == token
                ? existing.credentialRevision
                : CredentialRevision()
            accounts[index] = persistedAccount
        } else {
            accounts.append(persistedAccount)
        }
        try secureStore.setString(token, for: tokenKey(account.id))
        try saveAccountsLocked(accounts)
        addToActiveSetLocked(account.id, within: accounts)
        PlozzLog.auth.info("Added account for user \(account.userName)")
    }

    private func addMediaShareLocked(
        _ account: Account,
        credential: MediaShareCredentialEnvelope,
        generatedPrivateKey: String?
    ) throws {
        guard account.server.provider == .mediaShare else {
            throw AccountStoreError.invalidMediaShareAccount
        }
        let transport = try transportKind(for: account)
        guard credential.transport == transport else {
            throw MediaCredentialError.transportMismatch
        }
        try validateCredentialBinding(credential, account: account)
        let infrastructure = try mediaShareInfrastructure()
        var accounts = try persistedAccountsLockedThrowing()
        var existingIndex = accounts.firstIndex(where: { $0.id == account.id })
        var existing = existingIndex.map { accounts[$0] }
        var previousRevision = existing?.credentialRevision
        var staleIndexToReplace: Int?
        var staleRevisionToRetire: CredentialRevision?
        var staleRevisionRequiresRawDiscard = false
        var reconcileExistingToActiveRevision = false
        var activeRevision = try infrastructure.journal.activeRevision(
            accountID: account.id
        )
        let accountMutations = try infrastructure.journal.mutations().filter {
            $0.accountID == account.id
        }

        if activeRevision != previousRevision,
           activeRevision == nil,
           let staleAccount = existing,
           let staleIndex = existingIndex {
            // The account is already invisible because it has no active journal
            // pointer. This can be left behind if an earlier transaction persisted
            // account metadata but its pointer/recovery state did not survive.
            // Never overwrite an in-progress mutation or a different active pointer.
            guard accountMutations.isEmpty else {
                emitRevisionConflictDiagnostic(
                    reason: "missing-pointer-mutation",
                    activeRevision: activeRevision,
                    previousRevision: previousRevision,
                    mutations: accountMutations
                )
                throw CredentialMutationJournalError.activeRevisionConflict
            }
            guard staleAccount.server.provider == .mediaShare,
                  try transportKind(for: staleAccount) == transport else {
                throw AccountStoreError.invalidMediaShareAccount
            }

            let storedCredential: MediaShareCredentialEnvelope?
            do {
                storedCredential = try infrastructure.vault.credential(
                    accountID: account.id,
                    revision: staleAccount.credentialRevision,
                    expectedTransport: transport
                )
            } catch let error as MediaCredentialError {
                switch error {
                case .credentialNotFound:
                    guard transport != .sftp else { throw error }
                    storedCredential = nil
                    staleRevisionRequiresRawDiscard = true
                case .transportMismatch:
                    // Decode without enforcing the stale account's transport so a
                    // valid generated-key envelope can retire its child key.
                    storedCredential = try infrastructure.vault.credentialMetadata(
                        accountID: account.id,
                        revision: staleAccount.credentialRevision
                    )
                case .malformedEnvelope, .unsupportedVersion,
                     .unversionedCredentialNotSupported, .incompatibleAuthentication,
                     .incompatibleTrust, .invalidFingerprint, .payloadTooLarge,
                     .invalidIdentifier, .revisionAlreadyExists,
                     .childItemAlreadyExists, .childItemRetired:
                    throw error
                }
            } catch {
                // Keychain/storage failures are not evidence that a credential is
                // absent. Abort without changing metadata or vault state.
                throw error
            }
            if let storedCredential,
               storedCredential.transport == transport,
               (try? validateCredentialBinding(
                   storedCredential,
                   account: staleAccount
               )) != nil {
                // Both durable halves still exist; restore the missing pointer and
                // continue through the normal replacement transaction.
                try infrastructure.journal.seedActiveRevision(
                    staleAccount.credentialRevision,
                    accountID: account.id
                )
                activeRevision = staleAccount.credentialRevision
            } else {
                // No credential can make this hidden record usable. Reserve the
                // account through the normal new-credential journal entry below
                // before touching metadata, then replace only this invisible row.
                staleIndexToReplace = staleIndex
                staleRevisionToRetire = staleAccount.credentialRevision
                existingIndex = nil
                existing = nil
                previousRevision = nil
            }
        } else if activeRevision != previousRevision,
                  let authoritativeRevision = activeRevision,
                  let staleAccount = existing {
            guard accountMutations.isEmpty else {
                emitRevisionConflictDiagnostic(
                    reason: "authoritative-pointer-mutation",
                    activeRevision: activeRevision,
                    previousRevision: previousRevision,
                    mutations: accountMutations
                )
                throw CredentialMutationJournalError.activeRevisionConflict
            }
            guard staleAccount.server.provider == .mediaShare,
                  try transportKind(for: staleAccount) == transport else {
                throw AccountStoreError.invalidMediaShareAccount
            }

            do {
                let authoritativeCredential =
                    try infrastructure.vault.credential(
                        accountID: account.id,
                        revision: authoritativeRevision,
                        expectedTransport: transport
                    )
                try validateCredentialBinding(
                    authoritativeCredential,
                    account: staleAccount
                )
            } catch let error as MediaCredentialError
                where error == .credentialNotFound && transport != .sftp {
                // A missing non-generated credential can be replaced by the newly
                // verified connection. Other storage/decoding errors remain closed.
            }

            if staleAccount.credentialRevision != authoritativeRevision {
                do {
                    _ = try infrastructure.vault.credentialMetadata(
                        accountID: account.id,
                        revision: staleAccount.credentialRevision
                    )
                    staleRevisionRequiresRawDiscard = false
                } catch let error as MediaCredentialError
                    where error == .credentialNotFound {
                    staleRevisionRequiresRawDiscard = true
                }
                staleRevisionToRetire = staleAccount.credentialRevision
            }

            var reconciled = staleAccount
            reconciled.credentialRevision = authoritativeRevision
            existing = reconciled
            previousRevision = authoritativeRevision
            reconcileExistingToActiveRevision = true
        } else if previousRevision == nil,
                  existing == nil,
                  let authoritativeRevision = activeRevision {
            guard accountMutations.isEmpty else {
                emitRevisionConflictDiagnostic(
                    reason: "orphan-pointer-mutation",
                    activeRevision: activeRevision,
                    previousRevision: previousRevision,
                    mutations: accountMutations
                )
                throw CredentialMutationJournalError.activeRevisionConflict
            }
            // The journal pointer is durable but its non-secret account metadata is
            // absent. Reconstruct only from the newly verified connection, preserving
            // the authoritative revision as the previous side of replacement.
            var reconstructed = account
            reconstructed.credentialRevision = authoritativeRevision
            existing = reconstructed
            previousRevision = authoritativeRevision
        }

        guard activeRevision == previousRevision else {
            emitRevisionConflictDiagnostic(
                reason: "unhandled-pointer-mismatch",
                activeRevision: activeRevision,
                previousRevision: previousRevision,
                mutations: accountMutations
            )
            throw CredentialMutationJournalError.activeRevisionConflict
        }

        var previousCredentialMetadata: MediaShareCredentialEnvelope?
        var discardPreviousCredentialRaw = false
        let currentCredential: MediaShareCredentialEnvelope?
        if let existing {
            do {
                previousCredentialMetadata = try infrastructure.vault.credentialMetadata(
                    accountID: account.id,
                    revision: existing.credentialRevision,
                    expectedTransport: transport
                )
            } catch let error as MediaCredentialError {
                switch error {
                case .credentialNotFound:
                    guard transport != .sftp else { throw error }
                    previousCredentialMetadata = nil
                    discardPreviousCredentialRaw = true
                case .transportMismatch:
                    previousCredentialMetadata =
                        try infrastructure.vault.credentialMetadata(
                            accountID: account.id,
                            revision: existing.credentialRevision
                        )
                case .malformedEnvelope, .unsupportedVersion,
                     .unversionedCredentialNotSupported, .incompatibleAuthentication,
                     .incompatibleTrust, .invalidFingerprint, .payloadTooLarge,
                     .invalidIdentifier, .revisionAlreadyExists,
                     .childItemAlreadyExists, .childItemRetired:
                    throw error
                }
            }
            if previousCredentialMetadata?.transport == transport {
                do {
                    currentCredential = try infrastructure.vault.credential(
                        accountID: account.id,
                        revision: existing.credentialRevision,
                        expectedTransport: transport
                    )
                } catch let error as MediaCredentialError
                    where error == .credentialNotFound {
                    currentCredential = nil
                }
            } else {
                currentCredential = nil
            }
        } else {
            previousCredentialMetadata = nil
            currentCredential = nil
        }
        if let existing, currentCredential == credential {
            var updated = account
            updated.credentialRevision = existing.credentialRevision
            if let existingIndex {
                accounts[existingIndex] = updated
            } else {
                accounts.append(updated)
            }
            try saveAccountsLocked(accounts)
            addToActiveSetLocked(account.id, within: accounts)
            return
        }

        let pendingChildItemIDs: [CredentialChildItemID]
        let mutationKind: CredentialMutationKind
        if case .generatedKey(_, let keyID) = credential.authentication {
            guard generatedPrivateKey != nil else {
                throw AccountStoreError.generatedPrivateKeyRequired
            }
            try ensureGeneratedKeyIsExclusive(
                keyID,
                accountID: account.id,
                accounts: accounts,
                infrastructure: infrastructure
            )
            if case .generatedKey(_, let currentKeyID)?
                = previousCredentialMetadata?.authentication,
               currentKeyID == keyID {
                throw AccountStoreError.generatedKeyReuse
            }
            pendingChildItemIDs = [keyID]
            mutationKind = .generatedKeyPromotion
        } else {
            guard generatedPrivateKey == nil else {
                throw AccountStoreError.invalidMediaShareAccount
            }
            pendingChildItemIDs = []
            mutationKind = .credentialReplacement
        }

        var persistedAccount = account
        persistedAccount.credentialRevision = existing == nil
            ? account.credentialRevision
            : CredentialRevision()
        let pendingRevision = persistedAccount.credentialRevision
        let entry: CredentialMutationEntry
        do {
            entry = try infrastructure.journal.begin(
                kind: mutationKind,
                accountID: account.id,
                previousRevision: previousRevision,
                pendingRevision: pendingRevision,
                pendingChildItemIDs: pendingChildItemIDs,
                rawCredentialRevisionToDiscard: discardPreviousCredentialRaw
                    ? previousRevision
                    : nil
            )
        } catch let error as CredentialMutationJournalError
            where error == .activeRevisionConflict {
            emitRevisionConflictDiagnostic(
                reason: "begin-pointer-changed",
                activeRevision: try infrastructure.journal.activeRevision(
                    accountID: account.id
                ),
                previousRevision: previousRevision,
                mutations: try infrastructure.journal.mutations().filter {
                    $0.accountID == account.id
                }
            )
            throw error
        }

        do {
            if reconcileExistingToActiveRevision,
               let existingIndex,
               let existing {
                accounts[existingIndex] = existing
                try saveAccountsLocked(accounts)
            }
            if let staleRevisionToRetire {
                // This repair is limited to transports that cannot own generated
                // private-key child items. Discard while the new transaction is
                // still staged so a crash remains recoverable as a clean retry.
                if staleRevisionRequiresRawDiscard {
                    try infrastructure.vault.discardCredential(
                        accountID: account.id,
                        revision: staleRevisionToRetire
                    )
                } else {
                    try infrastructure.vault.retire(
                        accountID: account.id,
                        revision: staleRevisionToRetire
                    )
                }
            }
            if let staleIndexToReplace {
                accounts.remove(at: staleIndexToReplace)
                try saveAccountsLocked(accounts)
            }
            if let generatedPrivateKey,
               case .generatedKey(_, let keyID) = credential.authentication {
                try infrastructure.vault.storePrivateKey(
                    generatedPrivateKey,
                    id: keyID
                )
            }
            try infrastructure.vault.store(
                credential,
                accountID: account.id,
                revision: pendingRevision
            )
            if let existingIndex {
                accounts[existingIndex] = persistedAccount
            } else {
                accounts.append(persistedAccount)
            }
            try saveAccountsLocked(accounts)
            _ = try infrastructure.journal.markPrepared(entry.id)
            _ = try infrastructure.journal.markCommitted(entry.id)
            if let previousRevision {
                if discardPreviousCredentialRaw {
                    try infrastructure.vault.discardCredential(
                        accountID: account.id,
                        revision: previousRevision
                    )
                } else {
                    try infrastructure.vault.retire(
                        accountID: account.id,
                        revision: previousRevision
                    )
                }
            }
            try infrastructure.journal.finishCommitted(entry.id)
            addToActiveSetLocked(account.id, within: accounts)
            PlozzLog.auth.info("Added media-share account")
        } catch {
            let originalError = error
            try recoverCredentialMutationsLocked()
            if try isVisibleMediaShareRevisionLocked(
                accountID: account.id,
                revision: pendingRevision
            ) {
                addToActiveSetLocked(
                    account.id,
                    within: try persistedAccountsLockedThrowing()
                )
                return
            }
            throw originalError
        }
    }

    private func removeLocked(id: String) throws {
        var accounts = try persistedAccountsLockedThrowing()
        guard let account = accounts.first(where: { $0.id == id }) else { return }

        if account.server.provider == .mediaShare {
            let infrastructure = try mediaShareInfrastructure()
            guard try infrastructure.journal.activeRevision(accountID: id)
                    == account.credentialRevision else {
                throw CredentialMutationJournalError.activeRevisionConflict
            }
            let rawDiscard = try rawCredentialRevisionToDiscardIfNeeded(
                account,
                infrastructure: infrastructure
            )
            let entry = try infrastructure.journal.begin(
                kind: .accountRemoval,
                accountID: id,
                previousRevision: account.credentialRevision,
                pendingRevision: nil,
                rawCredentialRevisionToDiscard: rawDiscard
            )
            do {
                _ = try infrastructure.journal.markPrepared(entry.id)
                accounts.removeAll { $0.id == id }
                try saveAccountsLocked(accounts)
                _ = try infrastructure.journal.markCommitted(entry.id)
                if rawDiscard != nil {
                    try infrastructure.vault.discardCredential(
                        accountID: id,
                        revision: account.credentialRevision
                    )
                } else {
                    try infrastructure.vault.retire(
                        accountID: id,
                        revision: account.credentialRevision
                    )
                }
                try infrastructure.journal.finishCommitted(entry.id)
            } catch {
                let originalError = error
                try recoverCredentialMutationsLocked()
                if try infrastructure.journal.activeRevision(accountID: id) == nil,
                   !(try persistedAccountsLockedThrowing()).contains(where: { $0.id == id }) {
                    removeFromActiveSetLocked(
                        id,
                        within: try persistedAccountsLockedThrowing()
                    )
                    return
                }
                throw originalError
            }
        } else {
            accounts.removeAll { $0.id == id }
            try secureStore.removeValue(for: tokenKey(id))
            try saveAccountsLocked(accounts)
        }

        removeFromActiveSetLocked(id, within: accounts)
        PlozzLog.auth.info("Removed account \(id)")
    }

    private func recoverCredentialMutationsLocked() throws {
        let infrastructure = try mediaShareInfrastructure()
        for action in try infrastructure.journal.recoveryActions() {
            switch action {
            case .rollbackPending(let entry):
                try rollbackLocked(entry, infrastructure: infrastructure)
            case .completeCommitted(let entry):
                try completeLocked(entry, infrastructure: infrastructure)
            }
        }
    }

    private func rollbackLocked(
        _ entry: CredentialMutationEntry,
        infrastructure: MediaShareInfrastructure
    ) throws {
        var accounts = try persistedAccountsLockedThrowing()
        if entry.kind != .accountRemoval,
           let pendingRevision = entry.pendingRevision,
           let index = accounts.firstIndex(where: {
               $0.id == entry.accountID && $0.credentialRevision == pendingRevision
           }) {
            if let previousRevision = entry.previousRevision {
                accounts[index].credentialRevision = previousRevision
            } else {
                accounts.remove(at: index)
            }
            try saveAccountsLocked(accounts)
        }

        if let pendingRevision = entry.pendingRevision {
            try infrastructure.vault.retire(
                accountID: entry.accountID,
                revision: pendingRevision
            )
        }
        for childID in entry.pendingChildItemIDs {
            try infrastructure.vault.removePrivateKey(id: childID)
        }
        _ = try infrastructure.journal.rollbackStaged(entry.id)
    }

    private func completeLocked(
        _ entry: CredentialMutationEntry,
        infrastructure: MediaShareInfrastructure
    ) throws {
        var accounts = try persistedAccountsLockedThrowing()

        if entry.kind == .accountRemoval {
            if let account = accounts.first(where: { $0.id == entry.accountID }),
               account.credentialRevision != entry.previousRevision {
                throw AccountStoreError.mediaShareCredentialInvariantViolation
            }
            accounts.removeAll { $0.id == entry.accountID }
            try saveAccountsLocked(accounts)
        } else {
            guard let pendingRevision = entry.pendingRevision,
                  accounts.contains(where: {
                      $0.id == entry.accountID
                          && $0.credentialRevision == pendingRevision
                  }) else {
                throw AccountStoreError.mediaShareCredentialInvariantViolation
            }
        }

        if entry.phase == .prepared {
            _ = try infrastructure.journal.markCommitted(entry.id)
        }
        if let previousRevision = entry.previousRevision {
            if entry.rawCredentialRevisionToDiscard == previousRevision {
                try infrastructure.vault.discardCredential(
                    accountID: entry.accountID,
                    revision: previousRevision
                )
            } else {
                try infrastructure.vault.retire(
                    accountID: entry.accountID,
                    revision: previousRevision
                )
            }
        }
        try infrastructure.journal.finishCommitted(entry.id)
    }

    private func rawCredentialRevisionToDiscardIfNeeded(
        _ account: Account,
        infrastructure: MediaShareInfrastructure
    ) throws -> CredentialRevision? {
        let transport = try transportKind(for: account)
        do {
            _ = try infrastructure.vault.credentialMetadata(
                accountID: account.id,
                revision: account.credentialRevision,
                expectedTransport: transport
            )
            return nil
        } catch let error as MediaCredentialError {
            switch error {
            case .credentialNotFound:
                guard transport != .sftp else { throw error }
                return account.credentialRevision
            case .transportMismatch:
                _ = try infrastructure.vault.credentialMetadata(
                    accountID: account.id,
                    revision: account.credentialRevision
                )
                return nil
            case .malformedEnvelope, .unsupportedVersion,
                 .unversionedCredentialNotSupported, .incompatibleAuthentication,
                 .incompatibleTrust, .invalidFingerprint, .payloadTooLarge,
                 .invalidIdentifier, .revisionAlreadyExists,
                 .childItemAlreadyExists, .childItemRetired:
                throw error
            }
        }
    }

    private func ensureGeneratedKeyIsExclusive(
        _ keyID: CredentialChildItemID,
        accountID: String,
        accounts: [Account],
        infrastructure: MediaShareInfrastructure
    ) throws {
        for mutation in try infrastructure.journal.mutations()
            where mutation.accountID != accountID {
            if mutation.pendingChildItemIDs.contains(keyID) {
                throw AccountStoreError.generatedKeyReuse
            }
            if let previousRevision = mutation.previousRevision {
                do {
                    let previous = try infrastructure.vault.credentialMetadata(
                        accountID: mutation.accountID,
                        revision: previousRevision
                    )
                    if case .generatedKey(_, let previousKeyID)
                        = previous.authentication,
                       previousKeyID == keyID {
                        throw AccountStoreError.generatedKeyReuse
                    }
                } catch let error as MediaCredentialError
                    where error == .credentialNotFound {
                    continue
                }
            }

        }
        for other in accounts where other.id != accountID
            && other.server.provider == .mediaShare {
            let otherTransport = try transportKind(for: other)
            let envelope: MediaShareCredentialEnvelope
            do {
                envelope = try infrastructure.vault.credentialMetadata(
                    accountID: other.id,
                    revision: other.credentialRevision,
                    expectedTransport: otherTransport
                )
            } catch let error as MediaCredentialError
                where error == .credentialNotFound {
                continue
            }
            if case .generatedKey(_, let otherKeyID) = envelope.authentication,
               otherKeyID == keyID {
                throw AccountStoreError.generatedKeyReuse
            }
        }
    }

    private func emitRevisionConflictDiagnostic(
        reason: String,
        activeRevision: CredentialRevision?,
        previousRevision: CredentialRevision?,
        mutations: [CredentialMutationEntry]
    ) {
        let mutationSummary = mutations
            .map { "\($0.kind.rawValue):\($0.phase.rawValue)" }
            .joined(separator: ",")
        BrowseDiagnostics.emit(
            "mediaShareRevisionConflict reason=\(reason) "
                + "activePresent=\(activeRevision != nil) "
                + "previousPresent=\(previousRevision != nil) "
                + "same=\(activeRevision == previousRevision) "
                + "mutations=\(mutationSummary.isEmpty ? "none" : mutationSummary)"
        )
    }

    private func mediaShareCredentialLocked(
        for account: Account
    ) throws -> MediaShareCredentialEnvelope {
        let infrastructure = try mediaShareInfrastructure()
        guard try infrastructure.journal.activeRevision(accountID: account.id)
                == account.credentialRevision else {
            throw AccountStoreError.mediaShareCredentialInvariantViolation
        }
        let credential = try infrastructure.vault.credential(
            accountID: account.id,
            revision: account.credentialRevision,
            expectedTransport: try transportKind(for: account)
        )
        try validateCredentialBinding(credential, account: account)
        return credential
    }

    private func visibleAccountsLocked() -> [Account] {
        persistedAccountsLocked().filter { account in
            guard account.server.provider == .mediaShare else { return true }
            return (try? mediaShareCredentialLocked(for: account)) != nil
        }
    }

    private func isVisibleMediaShareRevisionLocked(
        accountID: String,
        revision: CredentialRevision
    ) throws -> Bool {
        guard let account = try persistedAccountsLockedThrowing().first(where: {
            $0.id == accountID && $0.credentialRevision == revision
        }) else {
            return false
        }
        _ = try mediaShareCredentialLocked(for: account)
        return true
    }

    private func persistedAccountsLocked() -> [Account] {
        do {
            return try persistedAccountsLockedThrowing()
        } catch {
            PlozzLog.auth.error("Account metadata unavailable; preserving stored value")
            return []
        }
    }

    private func persistedAccountsLockedThrowing() throws -> [Account] {
        guard let stored = try secureStore.readString(for: accountsKey) else {
            return []
        }
        guard let data = stored.data(using: .utf8) else {
            throw AccountStoreError.decodingFailed
        }
        let accounts: [Account]
        do {
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            throw AccountStoreError.decodingFailed
        }
        return accounts.sorted { $0.addedAt < $1.addedAt }
    }

    private func saveAccountsLocked(_ accounts: [Account]) throws {
        let data = try JSONEncoder().encode(accounts.sorted { $0.addedAt < $1.addedAt })
        guard let json = String(data: data, encoding: .utf8) else {
            throw AccountStoreError.encodingFailed
        }
        try secureStore.setString(json, for: accountsKey)
    }

    private func mediaShareInfrastructure() throws -> MediaShareInfrastructure {
        guard let mediaCredentialVault, let credentialJournal else {
            throw AccountStoreError.mediaShareCredentialInfrastructureUnavailable
        }
        return MediaShareInfrastructure(
            vault: mediaCredentialVault,
            journal: credentialJournal
        )
    }

    private func legacySMBInputCredential(
        account: Account,
        password: String
    ) throws -> MediaShareCredentialEnvelope {
        guard try transportKind(for: account) == .smb else {
            throw AccountStoreError.invalidMediaShareAccount
        }
        let authentication: MediaShareAuthentication =
            account.userName.isEmpty && password.isEmpty
                ? .anonymous
                : .password(username: account.userName, password: password)
        return try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: authentication
        )
    }

    private func validateCredentialBinding(
        _ credential: MediaShareCredentialEnvelope,
        account: Account
    ) throws {
        switch credential.authentication {
        case .anonymous, .noCredentials, .bearer:
            break
        case .password(let username, _), .generatedKey(let username, _):
            guard username == account.userName else {
                throw AccountStoreError.invalidMediaShareAccount
            }
        }
    }

    private func transportKind(for account: Account) throws -> MediaShareTransportKind {
        guard account.server.provider == .mediaShare,
              let kind = MediaShareTransportKind(mediaShareScheme: account.server.baseURL.scheme) else {
            throw AccountStoreError.invalidMediaShareAccount
        }
        return kind
    }

    private func tokenKey(_ accountID: String) -> String {
        tokenAccountPrefix + accountID
    }

    private func decodeIDs(_ json: String?) -> [String]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private func activeIDsLocked(within accounts: [Account]) -> [String] {
        let known = Set(accounts.map(\.id))
        guard let ids = decodeIDs(secureStore.string(for: activeIDsKey)) else {
            return accounts.map(\.id)
        }
        return ids.filter { known.contains($0) }
    }

    private func addToActiveSetLocked(_ id: String, within accounts: [Account]) {
        var active = activeIDsLocked(within: accounts)
        if !active.contains(id) {
            active.append(id)
        }
        persistActiveLocked(active)
    }

    private func removeFromActiveSetLocked(_ id: String, within accounts: [Account]) {
        var active = activeIDsLocked(within: accounts)
        active.removeAll { $0 == id }
        persistActiveLocked(active)
    }

    private func persistActiveLocked(_ ids: [String]) {
        do {
            let data = try JSONEncoder().encode(ids)
            guard let json = String(data: data, encoding: .utf8) else {
                throw AccountStoreError.encodingFailed
            }
            try secureStore.setString(json, for: activeIDsKey)
        } catch {
            PlozzLog.auth.error("Unable to persist active account selection")
        }
    }
}

private struct MediaShareInfrastructure {
    let vault: MediaCredentialVault
    let journal: CredentialMutationJournal
}
