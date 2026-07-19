import Foundation
import Observation

/// The outcome of a TMDB bring-your-own-key verification (Step 9), in module-neutral
/// terms so `FeatureSettings` can drive the UI without importing `MetadataKit` (where
/// the actual resilient HTTP check lives).
public enum TMDBKeyValidationResult: Equatable, Sendable {
    /// The key authenticated successfully.
    case valid
    /// The service rejected the key (401 / 403) — a wrong or revoked token.
    case invalid
    /// The check couldn't complete (offline / timeout / rate-limited / 5xx); the key
    /// may still be fine, so this is not a verdict against it.
    case unreachable
}

/// Observable state for the Settings "Use your own TMDB key" control (Step 9).
///
/// Encapsulates the enter / verify / save / remove transitions over a
/// ``TMDBUserKeyStoring`` so the flow is unit-testable without a running SwiftUI
/// hierarchy. The actual key validation and the credential-change invalidation are
/// injected closures (the real ones reach into `MetadataKit`'s resilient HTTP + shared
/// runtime from `AppShell`), keeping this leaf model free of those dependencies.
@MainActor
@Observable
public final class TMDBUserKeyModel {
    /// Where the verify affordance is in its lifecycle.
    public enum VerifyState: Equatable, Sendable {
        case idle
        case verifying
        case valid
        case invalid
        case unreachable
    }

    /// The obscured entry field's contents (bound to a `SecureField`). Never persisted
    /// until ``saveDraft()``; cleared once saved or removed.
    public var draftKey: String = ""

    /// Whether a key is currently stored (the opt-in is active).
    public private(set) var isConfigured: Bool

    /// The latest verification lifecycle state.
    public private(set) var verifyState: VerifyState = .idle

    private let store: TMDBUserKeyStoring
    private let validator: @Sendable (String) async -> TMDBKeyValidationResult
    private let onCredentialSuperseded: @Sendable (String) async -> Void

    public init(
        store: TMDBUserKeyStoring,
        validator: @escaping @Sendable (String) async -> TMDBKeyValidationResult = { _ in .unreachable },
        onCredentialSuperseded: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.store = store
        self.validator = validator
        self.onCredentialSuperseded = onCredentialSuperseded
        self.isConfigured = store.load() != nil
    }

    /// The trimmed draft, or `nil` when blank.
    private var trimmedDraft: String? {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the draft holds something savable.
    public var canSaveDraft: Bool { trimmedDraft != nil }

    /// Stores the entered key, replacing any prior one. When it replaces a *different*
    /// existing key, that old credential is superseded (its cached results + breaker
    /// state are cleared) so a stale/bad key can never resurface.
    public func saveDraft() async {
        guard let candidate = trimmedDraft else { return }
        let previous = store.load()
        try? store.save(candidate)
        isConfigured = store.load() != nil
        draftKey = ""
        verifyState = .idle
        if let previous, previous != candidate {
            await onCredentialSuperseded(previous)
        }
    }

    /// Verifies a key against TMDB: the draft when one is entered, otherwise the stored
    /// key. Reports `.invalid` when there's nothing to check.
    public func verify() async {
        guard let candidate = trimmedDraft ?? store.load() else {
            verifyState = .invalid
            return
        }
        verifyState = .verifying
        switch await validator(candidate) {
        case .valid: verifyState = .valid
        case .invalid: verifyState = .invalid
        case .unreachable: verifyState = .unreachable
        }
    }

    /// Removes the stored key (opt out) and supersedes its credential so its cached
    /// results + breaker trip are cleared immediately.
    public func remove() async {
        let previous = store.load()
        try? store.remove()
        isConfigured = false
        draftKey = ""
        verifyState = .idle
        if let previous {
            await onCredentialSuperseded(previous)
        }
    }
}
