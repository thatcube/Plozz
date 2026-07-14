import CryptoKit
import Foundation
import Network
import Security

/// Builds `NWParameters` for an FTP connection, applying the security policy
/// (plaintext vs TLS-from-connect) and the trust policy (system vs pinned
/// leaf). Leaf pinning mirrors the WebDAV adapter: a self-signed FTPS server is
/// trusted iff its leaf certificate's SHA-256 matches the pinned value —
/// independent of system trust — so pinning a self-signed cert works.
enum FTPTLSParameters {
    private static let verifyQueue = DispatchQueue(label: "com.plozz.ftp.tls-verify")

    static func make(security: FTPSecurity, trustPolicy: FTPTrustPolicy) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 20

        guard security.usesTLS else {
            return NWParameters(tls: nil, tcp: tcpOptions)
        }

        let tlsOptions = NWProtocolTLS.Options()
        if case let .pinnedLeaf(sha256, _) = trustPolicy {
            let expected = Data(sha256)
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    guard let leaf = leafCertificate(of: trust) else {
                        complete(false)
                        return
                    }
                    let der = SecCertificateCopyData(leaf) as Data
                    let digest = Data(SHA256.hash(data: der))
                    complete(digest == expected)
                },
                verifyQueue
            )
        }
        return NWParameters(tls: tlsOptions, tcp: tcpOptions)
    }

    private static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        if #available(tvOS 15.0, iOS 15.0, macOS 12.0, *) {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
                return nil
            }
            return chain.first
        } else {
            guard SecTrustGetCertificateCount(trust) > 0 else { return nil }
            return SecTrustGetCertificateAtIndex(trust, 0)
        }
    }
}
