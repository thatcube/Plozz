import Foundation

/// The data-channel endpoint negotiated for a passive transfer. Plozz always
/// connects the data channel to the **control-connection host** and uses only
/// the *port* from the server's PASV/EPSV reply — the NAT-hairpin-safe default
/// (a server behind NAT often advertises a private IP in its PASV reply).
public struct FTPPassivePort: Equatable, Sendable {
    /// The advertised IPv4 host from a PASV reply, retained only for tests /
    /// diagnostics. Never used to open the connection (see type doc). `nil` for
    /// EPSV, which omits the host by design.
    public let advertisedIPv4: String?
    public let port: Int

    public init(advertisedIPv4: String?, port: Int) {
        self.advertisedIPv4 = advertisedIPv4
        self.port = port
    }
}

/// Pure parsers for the two passive-mode replies. Socket-free so the (finicky)
/// PASV tuple and EPSV delimiter framing are unit-testable.
public enum FTPPassiveParser {
    /// Parses a `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)` reply.
    /// The port is `p1 * 256 + p2`.
    public static func parsePASV(_ text: String) throws -> FTPPassivePort {
        guard let open = text.firstIndex(of: "("),
              let close = text.firstIndex(of: ")"),
              open < close else {
            throw FTPProtocolError.malformedPassiveResponse
        }
        let inner = text[text.index(after: open)..<close]
        let parts = inner.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 6 else {
            throw FTPProtocolError.malformedPassiveResponse
        }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && (0...255).contains($0!) }),
              let p1 = numbers[4], let p2 = numbers[5] else {
            throw FTPProtocolError.malformedPassiveResponse
        }
        let host = parts[0...3].joined(separator: ".")
        return FTPPassivePort(advertisedIPv4: host, port: p1 * 256 + p2)
    }

    /// Parses a `229 Entering Extended Passive Mode (|||port|)` reply. The three
    /// leading fields (protocol/host) are empty by convention; only the port is
    /// present. The delimiter is whatever single character frames the fields.
    public static func parseEPSV(_ text: String) throws -> FTPPassivePort {
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"),
              open < close else {
            throw FTPProtocolError.malformedPassiveResponse
        }
        let inner = String(text[text.index(after: open)..<close])
        guard let delimiter = inner.first else {
            throw FTPProtocolError.malformedPassiveResponse
        }
        // Format: <d><d><d>port<d>  → splitting on the delimiter yields empty
        // fields for the protocol + host, then the port, then a trailing empty.
        let fields = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        // Find the single non-empty field — the port.
        let nonEmpty = fields.filter { !$0.isEmpty }
        guard nonEmpty.count == 1, let port = Int(nonEmpty[0]),
              (1...65_535).contains(port) else {
            throw FTPProtocolError.malformedPassiveResponse
        }
        return FTPPassivePort(advertisedIPv4: nil, port: port)
    }
}
