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
        case confirmingSAS(code: String)                              // source awaiting user match-confirm
        case sending                                                   // source in flight
        case sent                                                      // source done
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Nearby devices currently waiting to be set up (for tap-to-pair, no code).
    public private(set) var nearbyDevices: [DiscoveredPairingDevice] = []
    /// When this device is the RECEIVER on a non-QR pairing, the 6-digit SAS to
    /// display for the user to compare against the sending device. nil otherwise.
    public private(set) var hostSASCode: String?

    private let service: SyncSetupService
    private let existingAuthorizations: @MainActor () -> [String: LocalAuthorization]
    private let makeHostLink: @MainActor (SyncSetupService.HostPairing) -> any PairingLinkHosting
    private let makeGuestLink: @MainActor (String) -> any PairingLinkConnecting
    private let makeBrowser: @MainActor () -> any PairingBrowsing
    private var browser: (any PairingBrowsing)?
    private var isReceiving = false
    private var currentHost: (any PairingLinkHosting)?
    /// Monotonic token identifying the active receive run, so a stale run's cleanup
    /// can't null out a newer run's host (the listener-orphan bug).
    private var receiveGeneration = 0
    /// Continuation the sender awaits while the user confirms the SAS match.
    private var sasContinuation: CheckedContinuation<Bool, Never>?

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
    ///
    /// Runs as a re-arm loop: the pairing code stays valid for as long as this
    /// screen is open (a very generous TTL), and if a peer connects but doesn't
    /// complete the handshake (aborted, dropped, or timed out), we tear that
    /// attempt down and show a fresh code again instead of dead-ending on a
    /// spinner. Call `stopReceiving()` when leaving the screen.
    public func startReceiving() async {
        isReceiving = true
        receiveGeneration += 1
        let generation = receiveGeneration
        while isReceiving && generation == receiveGeneration && !Task.isCancelled {
            hostSASCode = nil
            // Generous TTL so the code never silently expires while the screen is
            // shown. The host's ephemeral key only lives as long as this ceremony,
            // so a long window here doesn't weaken the security model.
            let pairing = service.makeHostPairing(ttlSeconds: 24 * 60 * 60)
            phase = .waitingForPeer(code: pairing.code, invite: pairing.invite)
            let host = makeHostLink(pairing)
            currentHost = host
            do {
                let link = try await host.awaitConnection()
                guard isReceiving, generation == receiveGeneration else { link.close(); host.stop(); return }
                phase = .applying
                let received = try await service.receiveSetup(
                    pairing: pairing, over: link,
                    existingAuthorizations: existingAuthorizations(),
                    presentSAS: { [weak self] code in
                        Task { @MainActor in
                            guard let self, self.receiveGeneration == generation else { return }
                            self.hostSASCode = code
                        }
                    }
                )
                link.close()
                host.stop()
                if currentHost === host { currentHost = nil }
                isReceiving = false
                hostSASCode = nil
                phase = .applied(received)
                return
            } catch {
                host.stop()
                // Only clear shared state if it still refers to THIS run's host, so
                // a stale run can't orphan a newer run's live listener.
                if currentHost === host { currentHost = nil }
                if !isReceiving || generation != receiveGeneration || Task.isCancelled { return }
                // A peer connected but didn't finish. Re-arm with a fresh code and
                // keep waiting rather than showing a permanent spinner or error.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Stop advertising / awaiting a setup (call when the receive screen closes) so
    /// the device stops appearing in other devices' "set up another device" lists.
    public func stopReceiving() {
        isReceiving = false
        receiveGeneration += 1
        currentHost?.stop()
        currentHost = nil
        hostSASCode = nil
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

    /// Source role: send using a scanned QR invite string. The in-app camera scan
    /// authenticates the recipient out-of-band, so the host key is pinned and the
    /// numeric SAS check is skipped for a zero-friction transfer.
    public func send(inviteString: String) async {
        guard let invite = SyncPairingInvite.decode(inviteString) else {
            phase = .failed("That doesn't look like a Plozz setup code.")
            return
        }
        await send(serviceName: invite.serviceName, expectedPublicKey: invite.publicKeyData)
    }

    /// Source role: send from a universal-link invite (`https://plozz.app/pair#…`).
    /// Unlike an in-app camera scan, a link can be delivered remotely (e.g. texted),
    /// so it is NOT trusted as in-person proof: we reuse the service name to connect
    /// but force the numeric SAS confirmation, exactly like a typed code.
    public func send(deepLink invite: String) async {
        guard let decoded = SyncPairingInvite.decode(invite) else {
            phase = .failed("That doesn't look like a Plozz setup link.")
            return
        }
        await send(serviceName: decoded.serviceName, expectedPublicKey: nil)
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
            defer { link.close() }   // signal the peer promptly on success OR abort
            phase = .sending
            try await service.sendSetup(
                over: link,
                expectedPublicKey: expectedPublicKey,
                confirmSAS: { [weak self] code in
                    await self?.awaitSASConfirmation(code: code) ?? false
                }
            )
            phase = .sent
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Transition to the SAS-confirmation phase and suspend until the user taps
    /// "Matches" / "Doesn't match" (`confirmSASMatch`). Called from the send task
    /// on the non-QR path only.
    private func awaitSASConfirmation(code: String) async -> Bool {
        // Resolve any prior dangling continuation defensively.
        sasContinuation?.resume(returning: false)
        sasContinuation = nil
        phase = .confirmingSAS(code: code)
        let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            sasContinuation = cont
        }
        if confirmed { phase = .sending }
        return confirmed
    }

    /// The UI calls this when the user confirms whether the two devices' codes match.
    public func confirmSASMatch(_ matches: Bool) {
        guard let cont = sasContinuation else { return }
        sasContinuation = nil
        cont.resume(returning: matches)
    }

    public func reset() {
        sasContinuation?.resume(returning: false)
        sasContinuation = nil
        phase = .idle
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SyncPairingError.expiredContext: return "The setup code expired. Try again."
        case SyncPairingError.notConfirmed: return "Setup was cancelled — the codes didn't match."
        case SyncPairingError.commitmentMismatch, SyncPairingError.decryptionFailed:
            return "Couldn't verify the other device. Try again."
        case BonjourPairingError.connectionFailed, BonjourPairingError.timedOut:
            return "Couldn't reach the other device. Make sure both are on the same Wi-Fi."
        default: return "Setup didn't complete. Please try again."
        }
    }
}

// MARK: - Injectable link factories (so tests can supply in-memory links)

public protocol PairingLinkHosting: AnyObject, Sendable {
    func awaitConnection() async throws -> PairingLink
    func stop()
}
public extension PairingLinkHosting {
    func stop() {}
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
