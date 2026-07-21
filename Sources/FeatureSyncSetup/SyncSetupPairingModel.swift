import Foundation
import Observation
import CoreModels

// MARK: - Pairing view model (drives both roles)
//
// The @Observable state machine the pairing UI binds to. Link factories are
// injected (real Bonjour in apps, in-memory in tests) so the flow is unit-testable.
//
// Target role (e.g. Apple TV): `startReceiving()` mints a code + QR invite (shown
// on screen), advertises, awaits the sealed setup, then applies it.
//
// Source role (e.g. phone/tablet/computer): `send(inviteString:)` decodes a scanned
// QR, or `send(code:)` uses a typed short code, connects, verifies, and sends this
// device's config + credentials.

@MainActor
@Observable
public final class SyncSetupPairingModel {

    public enum Phase: Equatable, Sendable {
        case idle
        case waitingForPeer(code: String, invite: SyncPairingInvite)   // target advertising
        case applying                                                  // received, applying
        case applied(SyncSetupService.ReceivedSetup)                   // target done
        case connecting                                                // source connecting
        case sending                                                   // source in flight
        case sent                                                      // source done
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Nearby devices currently waiting to be set up (for tap-to-pair, no code).
    public private(set) var nearbyDevices: [DiscoveredPairingDevice] = []

    private let service: SyncSetupService
    private let existingAuthorizations: @MainActor () -> [String: LocalAuthorization]
    private let makeHostLink: @MainActor (SyncSetupService.HostPairing) -> any PairingLinkHosting
    private let makeGuestLink: @MainActor (String) -> any PairingLinkConnecting
    private let makeBrowser: @MainActor () -> any PairingBrowsing
    private var browser: (any PairingBrowsing)?

    public init(
        service: SyncSetupService,
        existingAuthorizations: @escaping @MainActor () -> [String: LocalAuthorization] = { [:] },
        makeHostLink: @escaping @MainActor (SyncSetupService.HostPairing) -> any PairingLinkHosting = {
            BonjourPairingHost(serviceName: $0.invite.serviceName, displayName: $0.displayName)
        },
        makeGuestLink: @escaping @MainActor (String) -> any PairingLinkConnecting = { BonjourPairingGuest(serviceName: $0) },
        makeBrowser: @escaping @MainActor () -> any PairingBrowsing = { BonjourPairingBrowser() }
    ) {
        self.service = service
        self.existingAuthorizations = existingAuthorizations
        self.makeHostLink = makeHostLink
        self.makeGuestLink = makeGuestLink
        self.makeBrowser = makeBrowser
    }

    /// Target role: show a code + QR, advertise, receive + apply the config.
    public func startReceiving() async {
        let pairing = service.makeHostPairing()
        phase = .waitingForPeer(code: pairing.code, invite: pairing.invite)
        let host = makeHostLink(pairing)
        do {
            let link = try await host.awaitConnection()
            phase = .applying
            let received = try await service.receiveSetup(
                pairing: pairing, over: link,
                existingAuthorizations: existingAuthorizations()
            )
            link.close()
            phase = .applied(received)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    // MARK: Source-side auto-discovery (tap-to-pair, no code)

    /// Begin listing nearby devices waiting to be set up.
    public func startDiscovery() {
        let browser = makeBrowser()
        browser.start { [weak self] devices in
            Task { @MainActor in self?.nearbyDevices = devices }
        }
        self.browser = browser
    }

    public func stopDiscovery() {
        browser?.stop(); browser = nil
        nearbyDevices = []
    }

    /// Pair with a discovered device (no code needed — same Wi-Fi, tap to confirm).
    public func pair(with device: DiscoveredPairingDevice) async {
        stopDiscovery()
        await send(serviceName: device.serviceName, expectedPublicKey: nil)
    }

    /// Source role: send using a scanned QR invite string.
    public func send(inviteString: String) async {
        guard let invite = SyncPairingInvite.decode(inviteString) else {
            phase = .failed("That doesn't look like a Plozz setup code.")
            return
        }
        await send(serviceName: invite.serviceName, expectedPublicKey: invite.publicKeyData)
    }

    /// Source role: send using a typed short code (no out-of-band key to verify).
    public func send(code: String) async {
        let normalized = SyncPairingCode.normalize(code)
        guard normalized.count >= 4 else {
            phase = .failed("Enter the code shown on your other device.")
            return
        }
        await send(serviceName: normalized, expectedPublicKey: nil)
    }

    private func send(serviceName: String, expectedPublicKey: Data?) async {
        phase = .connecting
        let guest = makeGuestLink(serviceName)
        do {
            let link = try await guest.connect()
            phase = .sending
            try await service.sendSetup(over: link, expectedPublicKey: expectedPublicKey)
            link.close()
            phase = .sent
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    public func reset() { phase = .idle }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SyncPairingError.expiredContext: return "The setup code expired. Try again."
        case SyncPairingError.decryptionFailed: return "Couldn't verify the other device. Try again."
        case BonjourPairingError.connectionFailed, BonjourPairingError.timedOut:
            return "Couldn't reach the other device. Make sure both are on the same Wi-Fi."
        default: return "Setup didn't complete. Please try again."
        }
    }
}

// MARK: - Injectable link factories (so tests can supply in-memory links)

public protocol PairingLinkHosting: Sendable {
    func awaitConnection() async throws -> PairingLink
}
public protocol PairingLinkConnecting: Sendable {
    func connect() async throws -> PairingLink
}
public protocol PairingBrowsing: Sendable {
    func start(onChange: @escaping @Sendable ([DiscoveredPairingDevice]) -> Void)
    func stop()
}

extension BonjourPairingHost: PairingLinkHosting {}
extension BonjourPairingGuest: PairingLinkConnecting {}
extension BonjourPairingBrowser: PairingBrowsing {}
