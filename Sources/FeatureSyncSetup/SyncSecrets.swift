import Foundation
import CoreModels

// MARK: - Secret transfer payloads (pairing channel ONLY)
//
// These carry actual credentials so a paired device needs NO sign-in. They travel
// EXCLUSIVELY inside the HPKE-sealed, device-targeted, ceremony-bound pairing
// channel that the user physically confirmed (QR / code) — never in a CloudKit
// record, never via iCloud Keychain to tvOS, never anywhere a server can read them.
// This is a deliberate, consented, device→device E2E transfer.
//
// The app layer fills these from its Keychain / credential vault (source) and
// installs them back into its Keychain / vault (target); FeatureSyncSetup only
// moves them — it never persists a secret itself.

/// A provider account's transferable credential.
public struct AccountSecret: Codable, Hashable, Sendable {
    public var accountID: String
    public var provider: ProviderKind
    /// The bearer token (Plex account/server token, Jellyfin access token).
    public var token: String
    /// The device id the token is bound to. Jellyfin binds a token to its device
    /// id, so the receiving device reuses this to stay signed in; Plex re-derives
    /// its own server tokens from an account token.
    public var deviceID: String
    /// The origin the token is trusted against (`scheme://host[:port]`).
    public var trustedOrigin: String

    public init(accountID: String, provider: ProviderKind, token: String, deviceID: String, trustedOrigin: String) {
        self.accountID = accountID
        self.provider = provider
        self.token = token
        self.deviceID = deviceID
        self.trustedOrigin = trustedOrigin
    }
}

/// A media-share account's transferable credential (the opaque `plozz-share-v1:`
/// envelope the vault already uses).
public struct ShareSecret: Codable, Hashable, Sendable {
    public var accountID: String
    /// The versioned, prefixed credential envelope string (`MediaShareCredentialCodec`).
    public var credentialEnvelope: String

    public init(accountID: String, credentialEnvelope: String) {
        self.accountID = accountID
        self.credentialEnvelope = credentialEnvelope
    }
}

/// The bundle of credentials transferred so the new device is signed in with no taps.
public struct SyncSecretsBundle: Codable, Hashable, Sendable {
    public var accounts: [AccountSecret]
    public var shares: [ShareSecret]

    public init(accounts: [AccountSecret] = [], shares: [ShareSecret] = []) {
        self.accounts = accounts
        self.shares = shares
    }

    public var isEmpty: Bool { accounts.isEmpty && shares.isEmpty }

    /// The set of account ids this bundle can sign in on the target device.
    public var authorizedAccountIDs: Set<String> {
        Set(accounts.map(\.accountID) + shares.map(\.accountID))
    }
}

/// What actually travels through a pairing: NON-SECRET config, plus OPTIONALLY the
/// secrets (present when the user is transferring sign-in for a no-tap setup).
public struct SyncTransferBundle: Codable, Hashable, Sendable {
    public var config: SyncConfigSnapshot
    /// Present only for a credential-carrying pairing (default for "no sign-in on
    /// the TV"); nil for a config-only pairing.
    public var secrets: SyncSecretsBundle?

    public init(config: SyncConfigSnapshot, secrets: SyncSecretsBundle? = nil) {
        self.config = config
        self.secrets = secrets
    }
}
