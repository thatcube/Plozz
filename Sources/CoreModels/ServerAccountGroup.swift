import Foundation

public struct ServerAccountGroup: Sendable {
    public let serverKey: String
    public let serverName: String
    public let providerKind: ProviderKind
    public let accounts: [Account]

    public init(
        serverKey: String,
        serverName: String,
        providerKind: ProviderKind,
        accounts: [Account]
    ) {
        self.serverKey = serverKey
        self.serverName = serverName
        self.providerKind = providerKind
        self.accounts = accounts
    }

    public var transportKind: MediaShareTransportKind? {
        guard providerKind == .mediaShare else { return nil }
        return MediaShareTransportKind(
            mediaShareScheme: accounts.first?.server.baseURL.scheme
        )
    }
}

public func serverGroups(from accounts: [Account]) -> [ServerAccountGroup] {
    var order: [String] = []
    var grouped: [String: ServerAccountGroup] = [:]

    for account in accounts {
        let key = serverKey(for: account)
        if grouped[key] == nil {
            order.append(key)
            grouped[key] = ServerAccountGroup(
                serverKey: key,
                serverName: account.server.name,
                providerKind: account.server.provider,
                accounts: []
            )
        }

        guard let current = grouped[key] else { continue }
        grouped[key] = ServerAccountGroup(
            serverKey: current.serverKey,
            serverName: current.serverName,
            providerKind: current.providerKind,
            accounts: current.accounts + [account]
        )
    }

    return order.compactMap { grouped[$0] }
}

public func serverKey(for account: Account) -> String {
    let url = account.server.baseURL
    let host = url.host?.lowercased() ?? url.absoluteString

    if account.server.provider == .mediaShare {
        let scheme = (url.scheme ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(account.server.provider.rawValue)|\(scheme)://\(host)\(port)\(path)"
    }

    return "\(account.server.provider.rawValue)|\(host)"
}
