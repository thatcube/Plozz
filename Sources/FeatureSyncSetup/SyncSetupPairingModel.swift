import Foundation
import Observation
import CoreModels

// MARK: - Pairing view model (drives both roles)
//
// The @Observable state machine the pairing UI binds to. Transports are injected
// (real Bonjour in the apps, in-memory in tests) so the flow is unit-testable.
//
// Target role (e.g. Apple TV): `startReceiving()` mints an invite (shown as a QR /
// code), advertises + awaits the sealed non-secret config, then applies it —
// yielding pending accounts the app finishes via native sign-in.
//
// Source role (e.g. phone): `send(inviteString:)` decodes a scanned invite and
// sends this device's non-secret config to it.

@MainActor
@Observable
public final class SyncSetupPairingModel {

    public enum Phase: Equatable, Sendable {
        case idle
        case waitingForPhone(invite: SyncPairingInvite)   // target advertising
        case applying                                     // received, applying
        case applied(SyncSetupService.ReceivedSetup)      // target done
        case sending                                      // source in flight
        case sent                                         // source done
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private let service: SyncSetupService
    private let existingAuthorizations: @MainActor () -> [String: LocalAuthorization]
    private let makeReceiver: @MainActor (String) -> PairingReceiving
    private let makeSender: @MainActor (String) -> PairingSending

    public init(
        service: SyncSetupService,
        existingAuthorizations: @escaping @MainActor () -> [String: LocalAuthorization] = { [:] },
        makeReceiver: @escaping @MainActor (String) -> PairingReceiving = { BonjourPairingResponder(serviceName: $0) },
        makeSender: @escaping @MainActor (String) -> PairingSending = { BonjourPairingInitiator(serviceName: $0) }
    ) {
        self.service = service
        self.existingAuthorizations = existingAuthorizations
        self.makeReceiver = makeReceiver
        self.makeSender = makeSender
    }

    /// Target role: show a QR, advertise, receive + apply the config.
    public func startReceiving() async {
        let (invite, identity) = service.makeInvite()
        phase = .waitingForPhone(invite: invite)
        let receiver = makeReceiver(invite.serviceName)
        do {
            let received = try await service.receiveSetup(
                identity: identity,
                over: receiver,
                existingAuthorizations: existingAuthorizations()
            )
            phase = .applying
            phase = .applied(received)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Source role: send this device's config to a scanned invite string.
    public func send(inviteString: String) async {
        guard let invite = SyncPairingInvite.decode(inviteString) else {
            phase = .failed("That doesn't look like a Plozz setup code.")
            return
        }
        await send(to: invite)
    }

    public func send(to invite: SyncPairingInvite) async {
        phase = .sending
        let sender = makeSender(invite.serviceName)
        do {
            try await service.sendSetup(to: invite, over: sender)
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
        case BonjourPairingError.timedOut: return "Couldn't reach the other device. Make sure both are on the same Wi-Fi."
        default: return "Setup didn't complete. Please try again."
        }
    }
}
