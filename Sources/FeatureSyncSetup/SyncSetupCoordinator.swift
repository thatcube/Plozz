import Foundation
import CoreModels

// MARK: - Sync & Setup coordinator (pure orchestration)
//
// Ties the pieces together WITHOUT touching networking, iCloud, or the Keychain:
//   • a source device EXPORTS a non-secret SyncConfigSnapshot from its accounts +
//     profiles;
//   • a fresh device APPLIES an incoming snapshot, producing (a) profiles to
//     import and (b) a `LocalAuthorization(.pending)` per account — i.e. "we know
//     which servers/accounts you use, now sign in on this device".
//
// v1 never transfers a secret: applying a snapshot only yields PENDING auths. The
// device then mints its own token via native provider linking (Quick Connect /
// Plex link). Media-share passwords are entered manually. This type is the seam
// the app drives; the live Bonjour transport + real stores plug in around it.

public struct SyncSetupCoordinator: Sendable {
    public init() {}

    /// Build the non-secret snapshot a source device shares. Accounts contribute
    /// token-free descriptors; profiles are wrapped with a version for granular
    /// reconciliation. No token is read or copied (Account has none).
    public func exportSnapshot(
        accounts: [Account],
        profiles: [Profile],
        profileSettings: [ProfileSettingsSnapshot] = [],
        accountVersion: (String) -> Int = { _ in 1 },
        profileVersion: (String) -> Int = { _ in 1 }
    ) -> SyncConfigSnapshot {
        SyncConfigSnapshot(
            accounts: accounts.map { SyncedAccountDescriptor(account: $0, recordVersion: accountVersion($0.id)) },
            profiles: profiles.map { VersionedProfile(profile: $0, recordVersion: profileVersion($0.id)) },
            profileSettings: profileSettings
        )
    }

    /// Result of applying an incoming snapshot on a fresh/target device.
    public struct Application: Equatable, Sendable {
        /// Profiles to import/merge locally.
        public var profiles: [Profile]
        /// One pending authorization per account the device does not yet hold a
        /// credential for — the app should offer native sign-in for each.
        public var pendingAuthorizations: [LocalAuthorization]
        /// Accounts already authorized locally that a synced descriptor tried to
        /// move onto an untrusted origin — must NOT be applied silently; the app
        /// should re-verify. (Guards the endpoint-retarget attack.)
        public var needsReverification: [String]
        /// Accounts that were signed in via a transferred credential (no tap needed).
        public var authorizedAuthorizations: [LocalAuthorization]

        public init(
            profiles: [Profile],
            pendingAuthorizations: [LocalAuthorization],
            needsReverification: [String],
            authorizedAuthorizations: [LocalAuthorization] = []
        ) {
            self.profiles = profiles
            self.pendingAuthorizations = pendingAuthorizations
            self.needsReverification = needsReverification
            self.authorizedAuthorizations = authorizedAuthorizations
        }

        /// Move the given account ids from `pending` to `authorized` because their
        /// credentials arrived over the pairing channel. Each authorized entry
        /// records the trusted origin(s) from `origins[id]`.
        public func markingAuthorized(_ ids: Set<String>, deviceID: String,
                                      origins: [String: Set<String>] = [:]) -> Application {
            guard !ids.isEmpty else { return self }
            var stillPending: [LocalAuthorization] = []
            var nowAuthorized = authorizedAuthorizations
            for auth in pendingAuthorizations {
                if ids.contains(auth.id) {
                    nowAuthorized.append(LocalAuthorization(
                        id: auth.id, state: .authorized, deviceID: deviceID,
                        trustedOrigins: origins[auth.id] ?? []
                    ))
                } else {
                    stillPending.append(auth)
                }
            }
            return Application(
                profiles: profiles,
                pendingAuthorizations: stillPending,
                needsReverification: needsReverification,
                authorizedAuthorizations: nowAuthorized
            )
        }
    }

    /// Apply an incoming snapshot against this device's current authorizations.
    /// - Parameters:
    ///   - snapshot: the received non-secret config.
    ///   - existingAuthorizations: this device's current `LocalAuthorization`s by id.
    ///   - thisDeviceID: the per-install device id to stamp on new pending auths.
    public func apply(
        snapshot: SyncConfigSnapshot,
        existingAuthorizations: [String: LocalAuthorization],
        thisDeviceID: String
    ) -> Application {
        var pending: [LocalAuthorization] = []
        var reverify: [String] = []

        for descriptor in snapshot.accounts {
            if let existing = existingAuthorizations[descriptor.id] {
                switch existing.state {
                case .authorized:
                    // Already signed in here. Only flag if it tries to retarget.
                    if existing.requiresReverification(for: descriptor) {
                        reverify.append(descriptor.id)
                    }
                case .pending, .unavailable:
                    pending.append(existing.state == .pending
                        ? existing
                        : LocalAuthorization(id: descriptor.id, state: .pending, deviceID: thisDeviceID))
                }
            } else {
                // New to this device — needs a fresh native sign-in.
                pending.append(LocalAuthorization(id: descriptor.id, state: .pending, deviceID: thisDeviceID))
            }
        }

        return Application(
            profiles: snapshot.profiles.map(\.profile),
            pendingAuthorizations: pending,
            needsReverification: reverify
        )
    }
}
