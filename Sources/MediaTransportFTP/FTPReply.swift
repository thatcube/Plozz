import Foundation

/// A completed FTP control-channel reply: a 3-digit status code plus the
/// (possibly multi-line) human-readable text.
public struct FTPReply: Equatable, Sendable {
    public let code: Int
    public let text: String

    public init(code: Int, text: String) {
        self.code = code
        self.text = text
    }

    /// FTP groups replies by the first digit (RFC 959 §4.2):
    /// 1xx positive preliminary, 2xx positive completion, 3xx positive
    /// intermediate, 4xx transient negative, 5xx permanent negative.
    public var isPositivePreliminary: Bool { (100...199).contains(code) }
    public var isPositiveCompletion: Bool { (200...299).contains(code) }
    public var isPositiveIntermediate: Bool { (300...399).contains(code) }
    public var isTransientNegative: Bool { (400...499).contains(code) }
    public var isPermanentNegative: Bool { (500...599).contains(code) }
    public var isNegative: Bool { code >= 400 }
}

/// Incremental parser for FTP control replies. A reply is either a single line
/// `NNN text` or a multi-line block that opens with `NNN-...` and closes with a
/// line beginning `NNN ` (same code + space) per RFC 959 §4.2.
///
/// Pure and socket-free so the exact framing (including a numeric-looking
/// continuation line inside a multi-line reply) is unit-testable.
public struct FTPReplyParser {
    private var lines: [String] = []
    private var multilineCode: Int?

    public init() {}

    /// The status code that opened an in-progress multi-line reply, if any.
    public var pendingCode: Int? { multilineCode }

    /// Feeds one CRLF-stripped line. Returns a completed ``FTPReply`` once the
    /// terminating line is seen, or `nil` while more lines are expected.
    public mutating func consume(line: String) throws -> FTPReply? {
        lines.append(line)

        if let openCode = multilineCode {
            // Inside a multi-line reply: it closes only on `NNN ` (space) with
            // the SAME code that opened it. A line that merely looks numeric
            // (e.g. a continuation whose text starts with digits) does NOT
            // terminate it unless code + space match.
            if let (code, isTerminator) = Self.parsePrefix(line),
               isTerminator, code == openCode {
                let reply = FTPReply(code: openCode, text: joinedText())
                reset()
                return reply
            }
            return nil
        }

        guard let (code, isTerminator) = Self.parsePrefix(line) else {
            throw FTPProtocolError.malformedReply
        }
        if isTerminator {
            let reply = FTPReply(code: code, text: joinedText())
            reset()
            return reply
        }
        // `NNN-` opens a multi-line reply.
        multilineCode = code
        return nil
    }

    private func joinedText() -> String {
        lines
            .map { line in
                // Strip the leading `NNN` + separator from each framed line so
                // `text` is the human-readable content only.
                guard line.count >= 4, let sep = line.dropFirst(3).first,
                      sep == " " || sep == "-",
                      Int(line.prefix(3)) != nil else {
                    return line
                }
                return String(line.dropFirst(4))
            }
            .joined(separator: "\n")
    }

    private mutating func reset() {
        lines.removeAll(keepingCapacity: false)
        multilineCode = nil
    }

    /// Parses the `NNN<sep>` prefix. Returns the code and whether the separator
    /// is a space (terminator) rather than `-` (continuation). `nil` if the
    /// line does not begin with a 3-digit code followed by ` ` or `-`.
    static func parsePrefix(_ line: String) -> (code: Int, isTerminator: Bool)? {
        guard line.count >= 4 else { return nil }
        let codePart = line.prefix(3)
        guard let code = Int(codePart), code >= 100, code <= 599 else { return nil }
        let separator = line[line.index(line.startIndex, offsetBy: 3)]
        switch separator {
        case " ": return (code, true)
        case "-": return (code, false)
        default: return nil
        }
    }
}

public enum FTPProtocolError: Error, Equatable, Sendable {
    case malformedReply
    case unexpectedReply(code: Int)
    case passiveModeUnavailable
    case malformedPassiveResponse
    case malformedListing
    case dataConnectionFailed
    case transferIncomplete
    case tlsRequired
}
