import Foundation
import Observation
import CoreModels

// MARK: - SyncSetupService (app-facing facade)
//
// Composes the flag, presence beacon, coordinator, and pairing session into the
// small surface the app UI binds to. It stays decoupled from AppState by taking
// closures for the current config / device identity, so it is unit-testable and
// can be wired into both the tvOS `AppState` and the iOS `PlozziOSAppModel`.
//
// v1 moves NON-SECRET config only. Applying an incoming config never signs a
// device in — it yields pending authorizations the app fulfils via native
// provider linking (Quick Connect / Plex link). Manual media-share passwords.

@MainActor
@Observable
public final class SyncSetupService {

    public struct LocalConfig: Sendable {
        public var accounts: [Account]
        public var profiles: [Profile]
        public var profileSettings: [ProfileSettingsSnapshot]
        /// Per-profile explicit server membership (profile id → chosen account-id
        /// subset). Only profiles that made an explicit choice appear; a profile
        /// absent here never chose one (⇒ all servers). See SyncConfigSnapshot.
        public var profileMemberships: [String: [String]]
        public init(
            accounts: [Account],
            profiles: [Profile],
            profileSettings: [ProfileSettingsSnapshot] = [],
            profileMemberships: [String: [String]] = [:]
        ) {
            self.accounts = accounts
            self.profiles = profiles
            self.profileSettings = profileSettings
            self.profileMemberships = profileMemberships
        }
    }

    private let flag: SyncSetupFeatureFlag
    private let beaconStore: PresenceBeaconStoring
    private let rendezvousStore: PairingRendezvousStoring
    private let coordinator = SyncSetupCoordinator()

    private let configProvider: @MainActor () -> LocalConfig
    private let secretsProvider: @MainActor () -> SyncSecretsBundle
    private let deviceID: @MainActor () -> String
    private let deviceName: @MainActor () -> String
    private let isConfigured: @MainActor () -> Bool

    public private(set) var isEnabled: Bool

    public init(
        flag: SyncSetupFeatureFlag = SyncSetupFeatureFlag(),
        beaconStore: PresenceBeaconStoring = UbiquitousPresenceBeaconStore(),
        rendezvousStore: PairingRendezvousStoring = UbiquitousPairingRendezvousStore(),
        deviceID: @escaping @MainActor () -> String,
        deviceName: @escaping @MainActor () -> String,
        isConfigured: @escaping @MainActor () -> Bool,
        configProvider: @escaping @MainActor () -> LocalConfig,
        secretsProvider: @escaping @MainActor () -> SyncSecretsBundle = { SyncSecretsBundle() }
    ) {
        self.flag = flag
        self.beaconStore = beaconStore
        self.rendezvousStore = rendezvousStore
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isConfigured = isConfigured
        self.configProvider = configProvider
        self.secretsProvider = secretsProvider
        self.isEnabled = flag.isEnabled
    }

    // MARK: Opt-in

    /// What the `isEnabled` flag gates — and what it deliberately does NOT.
    ///
    /// The flag is the consent decision for PASSIVE behaviour: publishing the
    /// presence beacon (`publishPresence`) and surfacing the auto "continue here"
    /// offer (`continueOffer`). Both are gated on `isEnabled`, so a device that
    /// hasn't opted in never advertises itself or nudges other devices.
    ///
    /// It intentionally does NOT gate the EXPLICIT, user-initiated pairing
    /// (`makeHostPairing` / `receiveSetup` / `sendSetup`). Those are only reached by
    /// a person tapping "Set up another device" / "Set up this device from another"
    /// in Settings — consent is the tap itself — and a brand-new device must be able
    /// to RECEIVE a setup while its own flag is still off-by-default. Gating the
    /// interactive flow behind a pre-toggle would break exactly the first-run case
    /// the feature exists for. Security on those paths comes from the SAS/QR
    /// authentication in SyncPairingSession, not from this flag.
    ///
    /// Turn cross-device sync on/off (the consent decision). When enabled and this
    /// device is configured, it publishes a presence beacon so other devices can
    /// offer to continue here.
    public func setEnabled(_ on: Bool) {
        var f = flag; f.isEnabled = on
        isEnabled = on
        if on { publishPresence() } else { beaconStore.clear() }
    }

    // MARK: Presence beacon

    /// Publish a NON-SECRET beacon reflecting the current config, so a fresh
    /// device on the same Apple ID can offer "bring your setup here".
    public func publishPresence() {
        guard isEnabled else { return }
        let cfg = configProvider()
        guard !cfg.accounts.isEmpty || !cfg.profiles.isEmpty else { beaconStore.clear(); return }
        beaconStore.write(SyncPresenceBeacon(
            setupExists: true,
            deviceName: deviceName(),
            serverCount: Set(cfg.accounts.map(\.server.id)).count,
            profileCount: cfg.profiles.count
        ))
    }

    /// Returns the beacon to offer a "continue setup here" prompt, or nil.
    public func continueOffer() -> SyncPresenceBeacon? {
        guard isEnabled else { return nil }
        let beacon = beaconStore.read()
        return PresenceBeaconEvaluator.shouldOfferContinue(beacon: beacon, thisDeviceIsConfigured: isConfigured())
            ? beacon : nil
    }

    // MARK: Pairing — target (this device receives config, e.g. Apple TV)

    /// A prepared target-side pairing: the short code, the QR invite (carrying the
    /// public key), the friendly device name (advertised for discovery), and the
    /// identity used to open the received bundle.
    public struct HostPairing: Sendable {
        public let code: String
        public let invite: SyncPairingInvite
        public let identity: SyncPairingIdentity
        public let displayName: String
    }

    /// Create a fresh code + QR invite + identity this device shows to be set up.
    public func makeHostPairing(ttlSeconds: Int = 180) -> HostPairing {
        let code = SyncPairingCode.generate()
        let identity = SyncPairingIdentity()
        let invite = SyncPairingInvite(
            serviceName: code,
            publicKeyData: identity.publicKeyData,
            context: SyncPairingContext(ttlSeconds: ttlSeconds)
        )
        return HostPairing(code: code, invite: invite, identity: identity, displayName: deviceName())
    }

    // MARK: Same-Apple-ID rendezvous (zero-typing credential auto-skip)

    /// Publish this device's pairing offer to iCloud so a same-Apple-ID device can set
    /// it up WITHOUT a scanned QR or typed code. The offer carries only the Bonjour
    /// service name + the ephemeral PUBLIC key (both non-secret); because only the
    /// user's own devices can read it, a reader that pins this key gets QR-equivalent
    /// authentication and skips the numeric SAS. Call when showing the receive screen.
    public func publishRendezvous(for pairing: HostPairing, ttlSeconds: Int = 24 * 60 * 60) {
        rendezvousStore.publish(SyncPairingRendezvous(
            serviceName: pairing.invite.serviceName,
            publicKeyData: pairing.identity.publicKeyData,
            deviceName: pairing.displayName,
            deviceID: deviceID(),
            ttlSeconds: ttlSeconds
        ))
    }

    /// Remove this device's rendezvous offer (pairing finished or screen closed).
    public func withdrawRendezvous() {
        rendezvousStore.withdraw(deviceID: deviceID())
    }

    /// The best same-Apple-ID device currently asking to be set up (freshest offer,
    /// never this device), or nil. The source uses this to auto-adopt with no typing.
    public func discoverRendezvousTarget(now: Date = Date()) -> SyncPairingRendezvous? {
        PairingRendezvousMatcher.target(from: rendezvousStore.all(), thisDeviceID: deviceID(), now: now)
    }

    /// All same-Apple-ID devices currently asking to be set up (freshest first). Lets
    /// the app skip an offer the user declined and still surface OTHER devices.
    public func discoverRendezvousTargets(now: Date = Date()) -> [SyncPairingRendezvous] {
        PairingRendezvousMatcher.targets(from: rendezvousStore.all(), thisDeviceID: deviceID(), now: now)
    }

    /// The public key of an offer to PIN when connecting — so the source authenticates
    /// the host out-of-band (via iCloud account membership) exactly like a scanned QR,
    /// and no SAS comparison is needed. Exposed for the pairing model's adopt path.
    public func expectedPublicKey(for rendezvous: SyncPairingRendezvous) -> Data {
        rendezvous.publicKeyData
    }

    /// Everything a target device needs to persist a received setup: the config
    /// (descriptors + profiles), any transferred credentials, and the computed
    /// application (which accounts are authorized vs still pending sign-in).
    public struct ReceivedSetup: Sendable, Equatable {
        public let config: SyncConfigSnapshot
        public let secrets: SyncSecretsBundle?
        public let application: SyncSetupCoordinator.Application
    }

    /// Result of persisting a received setup on this device, so the UI can confirm
    /// success or surface a partial/total failure instead of silently claiming
    /// everything worked. `applyReceivedSetup` returns this from each shell.
    public struct ApplyOutcome: Sendable, Equatable {
        /// Credentialed accounts that arrived with a token/envelope and were meant
        /// to be signed in without a tap.
        public var expectedCredentialed: Int
        /// How many of those actually persisted to the account store.
        public var addedCredentialed: Int
        /// Ids of the credentialed accounts that FAILED to persist (for a re-add hint).
        public var failedAccountIDs: [String]
        public var importedProfiles: Int

        public init(expectedCredentialed: Int, addedCredentialed: Int,
                    failedAccountIDs: [String], importedProfiles: Int) {
            self.expectedCredentialed = expectedCredentialed
            self.addedCredentialed = addedCredentialed
            self.failedAccountIDs = failedAccountIDs
            self.importedProfiles = importedProfiles
        }

        /// At least one credentialed account was expected but NONE persisted — the
        /// device is NOT signed in; the caller must surface an error and must not
        /// mark setup complete.
        public var isTotalCredentialFailure: Bool {
            expectedCredentialed > 0 && addedCredentialed == 0
        }
        /// Some (but not all) credentialed accounts failed — setup is usable but the
        /// UI should tell the user which servers to re-add.
        public var isPartialFailure: Bool {
            !failedAccountIDs.isEmpty && addedCredentialed > 0
        }
    }

    /// Host side: advertise our invite over the link, receive the sealed bundle,
    /// and compute what to persist. Accounts whose credentials arrived are marked
    /// authorized (no sign-in needed); the rest are pending for native sign-in.
    public func receiveSetup(
        pairing: HostPairing,
        over link: PairingLink,
        existingAuthorizations: [String: LocalAuthorization] = [:],
        presentSAS: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ReceivedSetup {
        let bundle = try await SyncPairingSession.hostReceiveSetup(
            identity: pairing.identity, context: pairing.invite.context,
            serviceName: pairing.invite.serviceName, over: link,
            presentSAS: presentSAS
        )
        var application = coordinator.apply(
            snapshot: bundle.config,
            existingAuthorizations: existingAuthorizations,
            thisDeviceID: deviceID()
        )
        if let secrets = bundle.secrets, !secrets.isEmpty {
            var origins: [String: Set<String>] = [:]
            for a in secrets.accounts { origins[a.accountID, default: []].insert(a.trustedOrigin) }
            application = application.markingAuthorized(
                secrets.authorizedAccountIDs, deviceID: deviceID(), origins: origins
            )
        }
        return ReceivedSetup(config: bundle.config, secrets: bundle.secrets, application: application)
    }

    // MARK: Pairing — source (this device sends its config + credentials)

    /// Guest side: over the link, run the authenticated handshake (QR key pinning
    /// when `expectedPublicKey` is set, otherwise a SAS numeric-comparison the user
    /// confirms via `confirmSAS`), then seal + send this device's config and —
    /// unless `configOnly` — its credentials.
    public func sendSetup(
        over link: PairingLink,
        expectedPublicKey: Data?,
        configOnly: Bool = false,
        confirmSAS: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) async throws {
        let cfg = configProvider()
        let snapshot = coordinator.exportSnapshot(
            accounts: cfg.accounts, profiles: cfg.profiles,
            profileSettings: cfg.profileSettings, profileMemberships: cfg.profileMemberships
        )
        let secrets = configOnly ? nil : secretsProvider()
        let bundle = SyncTransferBundle(config: snapshot, secrets: (secrets?.isEmpty ?? true) ? nil : secrets)
        try await SyncPairingSession.guestSendSetup(
            bundle, over: link, expectedPublicKey: expectedPublicKey, confirmSAS: confirmSAS
        )
    }
}
