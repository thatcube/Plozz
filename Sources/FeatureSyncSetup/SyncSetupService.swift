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
        configProvider: @escaping @MainActor () -> LocalConfig
    ) {
        self.flag = flag
        self.beaconStore = beaconStore
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.isConfigured = isConfigured
        self.configProvider = configProvider
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

    /// Receive a config snapshot over a channel and compute what to apply. The
    /// caller persists profiles and offers native sign-in for pending accounts.
    public func receiveConfig(
        identity: SyncPairingIdentity,
        over channel: PairingReceiving,
        existingAuthorizations: [String: LocalAuthorization] = [:]
    ) async throws -> SyncSetupCoordinator.Application {
        let snapshot = try await SyncPairingSession.receiveConfig(with: identity, over: channel)
        return coordinator.apply(
            snapshot: snapshot,
            existingAuthorizations: existingAuthorizations,
            thisDeviceID: deviceID()
        )
    }

    // MARK: Pairing — source (this device sends its config, e.g. phone)

    /// Seal this device's NON-SECRET config to a scanned invite and send it.
    public func sendConfig(to invite: SyncPairingInvite, over channel: PairingSending) async throws {
        let cfg = configProvider()
        let snapshot = coordinator.exportSnapshot(accounts: cfg.accounts, profiles: cfg.profiles)
        try await SyncPairingSession.sendConfig(snapshot, to: invite, over: channel)
    }
}
