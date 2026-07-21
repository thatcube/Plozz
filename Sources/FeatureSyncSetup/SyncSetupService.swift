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
        public init(accounts: [Account], profiles: [Profile]) {
            self.accounts = accounts
            self.profiles = profiles
        }
    }

    private let flag: SyncSetupFeatureFlag
    private let beaconStore: PresenceBeaconStoring
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
        deviceID: @escaping @MainActor () -> String,
        deviceName: @escaping @MainActor () -> String,
        isConfigured: @escaping @MainActor () -> Bool,
        configProvider: @escaping @MainActor () -> LocalConfig,
        secretsProvider: @escaping @MainActor () -> SyncSecretsBundle = { SyncSecretsBundle() }
    ) {
        self.flag = flag
        self.beaconStore = beaconStore
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isConfigured = isConfigured
        self.configProvider = configProvider
        self.secretsProvider = secretsProvider
        self.isEnabled = flag.isEnabled
    }

    // MARK: Opt-in

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

    /// Create a fresh identity + QR invite this device shows to be set up.
    public func makeInvite(serviceName: String = "Plozz-\(Int.random(in: 1000...9999))",
                           ttlSeconds: Int = 120) -> (invite: SyncPairingInvite, identity: SyncPairingIdentity) {
        let identity = SyncPairingIdentity()
        let invite = SyncPairingInvite(
            serviceName: serviceName,
            publicKeyData: identity.publicKeyData,
            context: SyncPairingContext(ttlSeconds: ttlSeconds)
        )
        return (invite, identity)
    }

    /// Everything a target device needs to persist a received setup: the config
    /// (descriptors + profiles), any transferred credentials, and the computed
    /// application (which accounts are authorized vs still pending sign-in).
    public struct ReceivedSetup: Sendable, Equatable {
        public let config: SyncConfigSnapshot
        public let secrets: SyncSecretsBundle?
        public let application: SyncSetupCoordinator.Application
    }

    /// Receive a setup bundle over a channel and compute what to persist. Accounts
    /// whose credentials arrived are marked authorized (no sign-in needed); the
    /// rest are pending for native sign-in. The caller persists profiles, creates
    /// accounts from `config` + `secrets`, and stores credentials in the Keychain.
    public func receiveSetup(
        identity: SyncPairingIdentity,
        over channel: PairingReceiving,
        existingAuthorizations: [String: LocalAuthorization] = [:]
    ) async throws -> ReceivedSetup {
        let bundle = try await SyncPairingSession.receiveSetup(with: identity, over: channel)
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

    /// Seal this device's config — and, unless `configOnly`, its credentials so the
    /// target signs in with no taps — to a scanned invite and send it.
    public func sendSetup(
        to invite: SyncPairingInvite,
        over channel: PairingSending,
        configOnly: Bool = false
    ) async throws {
        let cfg = configProvider()
        let snapshot = coordinator.exportSnapshot(accounts: cfg.accounts, profiles: cfg.profiles)
        let secrets = configOnly ? nil : secretsProvider()
        let bundle = SyncTransferBundle(config: snapshot, secrets: (secrets?.isEmpty ?? true) ? nil : secrets)
        try await SyncPairingSession.sendSetup(bundle, to: invite, over: channel)
    }
}
