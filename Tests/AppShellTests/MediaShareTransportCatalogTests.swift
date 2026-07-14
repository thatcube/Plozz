import XCTest
import CoreModels
import FeatureAuth
@testable import AppShell

/// Drift guard: the unified onboarding descriptors (`MediaShareTransportCatalog`)
/// must never claim an auth mode or trust requirement that the credential vault
/// (`MediaCredentialVault`) wouldn't accept. The descriptors restate the vault's
/// `validate()` matrix as UI-facing data; if the two fall out of sync — e.g. the
/// UI offers a token field for a transport the vault rejects — onboarding would
/// collect a credential it can never persist. These tests fail loudly instead.
@MainActor
final class MediaShareTransportCatalogTests: XCTestCase {

    /// Every UI auth mode a descriptor offers must map to a vault authentication
    /// the vault accepts for that transport.
    func testDescriptorAuthModesAreVaultAccepted() throws {
        for descriptor in MediaShareTransportCatalog.all {
            for mode in descriptor.authModes {
                for auth in vaultAuthentications(for: mode, descriptor: descriptor) {
                    XCTAssertNoThrow(
                        try MediaShareCredentialEnvelope(
                            transport: descriptor.kind,
                            authentication: auth,
                            trust: minimalTrust(for: descriptor)
                        ),
                        "\(descriptor.kind) should accept \(auth) for UI mode \(mode)"
                    )
                }
            }
        }
    }

    /// A transport whose descriptor declares NO auth modes must be the one the
    /// vault models as credential-free (NFS → `.noCredentials`).
    func testNoAuthModesMeansNoCredentials() throws {
        for descriptor in MediaShareTransportCatalog.all where descriptor.authModes.isEmpty {
            XCTAssertNoThrow(
                try MediaShareCredentialEnvelope(
                    transport: descriptor.kind,
                    authentication: .noCredentials,
                    trust: minimalTrust(for: descriptor)
                ),
                "\(descriptor.kind) has no UI auth modes but the vault won't take .noCredentials"
            )
        }
    }

    /// The descriptor's trust kind must agree with the vault's pin rules:
    /// SFTP requires an SSH host-key pin; WebDAV permits a TLS leaf pin; SMB/NFS
    /// permit no pin.
    func testTrustKindMatchesVaultPinRules() throws {
        for descriptor in MediaShareTransportCatalog.all {
            switch descriptor.trust {
            case .sshHostKeyRequired:
                // A host-key pin is accepted…
                XCTAssertNoThrow(try envelope(descriptor, sshPinned: true))
                // …and the vault refuses SFTP WITHOUT one.
                XCTAssertThrowsError(try envelope(descriptor, sshPinned: false))
            case .tlsLeafOnUntrusted:
                XCTAssertNoThrow(try envelope(descriptor, tlsPinned: true))
                XCTAssertNoThrow(try envelope(descriptor, tlsPinned: false))
            case .none:
                XCTAssertNoThrow(try envelope(descriptor))
            }
        }
    }

    func testCatalogCoversImplementedTransports() {
        let kinds = Set(MediaShareTransportCatalog.all.map(\.kind))
        XCTAssertTrue(kinds.contains(.smb))
        XCTAssertTrue(kinds.contains(.webDAV))
        // Present (dummy-wired) so discovery/UI light up before backends land.
        XCTAssertTrue(kinds.contains(.nfs))
        XCTAssertTrue(kinds.contains(.sftp))
        XCTAssertTrue(MediaShareTransportCatalog.descriptor(for: .smb)?.isImplemented == true)
        XCTAssertTrue(MediaShareTransportCatalog.descriptor(for: .nfs)?.isImplemented == false)
    }

    func testPreferredKindFavoursNativeFilesystem() {
        XCTAssertEqual(
            MediaShareTransportCatalog.preferredKind(among: [.webDAV, .smb]), .smb
        )
        XCTAssertEqual(
            MediaShareTransportCatalog.preferredKind(among: [.sftp, .nfs]), .nfs
        )
    }

    /// SMB/WebDAV permit a blank (guest/anonymous) login; SFTP does not.
    func testBlankGuestPolicyMatchesVault() {
        XCTAssertEqual(MediaShareTransportCatalog.descriptor(for: .smb)?.allowsBlankGuest, true)
        XCTAssertEqual(MediaShareTransportCatalog.descriptor(for: .webDAV)?.allowsBlankGuest, true)
        XCTAssertEqual(MediaShareTransportCatalog.descriptor(for: .sftp)?.allowsBlankGuest, false)
    }

    // MARK: - Helpers

    private func vaultAuthentications(
        for mode: MediaShareAuthMode,
        descriptor: TransportOnboardingDescriptor
    ) -> [MediaShareAuthentication] {
        switch mode {
        case .usernamePassword:
            var auths: [MediaShareAuthentication] = [.password(username: "u", password: "p")]
            // Blank fields = guest/anonymous, only where the transport permits it.
            if descriptor.allowsBlankGuest { auths.append(.anonymous) }
            return auths
        case .token:
            return [.bearer(token: "t")]
        }
    }

    private func minimalTrust(for descriptor: TransportOnboardingDescriptor) -> MediaShareTrustMaterial {
        switch descriptor.trust {
        case .sshHostKeyRequired:
            return MediaShareTrustMaterial(sshHostKeySHA256: try! fingerprint())
        case .tlsLeafOnUntrusted, .none:
            return MediaShareTrustMaterial()
        }
    }

    private func envelope(
        _ descriptor: TransportOnboardingDescriptor,
        tlsPinned: Bool = false,
        sshPinned: Bool = false
    ) throws -> MediaShareCredentialEnvelope {
        let auth: MediaShareAuthentication = descriptor.authModes.isEmpty
            ? .noCredentials
            : .anonymous
        var trust = MediaShareTrustMaterial()
        if tlsPinned { trust = MediaShareTrustMaterial(tlsLeafCertificateSHA256: try fingerprint()) }
        if sshPinned { trust = MediaShareTrustMaterial(sshHostKeySHA256: try fingerprint()) }
        // SFTP needs password/anonymous-incompatible auth; use password.
        let resolvedAuth: MediaShareAuthentication = descriptor.kind == .sftp
            ? .password(username: "u", password: "p")
            : auth
        return try MediaShareCredentialEnvelope(
            transport: descriptor.kind,
            authentication: resolvedAuth,
            trust: trust
        )
    }

    private func fingerprint() throws -> SHA256Fingerprint {
        try SHA256Fingerprint(bytes: Data(repeating: 0xAB, count: 32))
    }
}
