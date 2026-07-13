import CoreModels
import Foundation
import MediaTransportCore

public typealias TransportRole = MediaTransportRole
public typealias TransportSessionKey = MediaTransportSessionKey

public extension MediaTransportSessionKey {
    init(
        accountID: String,
        credentialRevision: UUID,
        origin: TransportOrigin,
        trustRevision: UUID,
        role: TransportRole
    ) throws {
        let endpoint = try MediaTransportEndpointIdentity(
            transportIdentifier: origin.scheme,
            host: origin.host,
            port: origin.port
        )
        self.init(
            accountID: accountID,
            credentialRevision: CredentialRevision(rawValue: credentialRevision),
            endpoint: endpoint,
            trustRevision: trustRevision,
            role: role
        )
    }

    var origin: TransportOrigin? {
        TransportOrigin(
            scheme: endpoint.transportIdentifier,
            host: endpoint.host,
            port: endpoint.port ?? TransportOrigin.defaultPort(forScheme: endpoint.transportIdentifier)
        )
    }
}
