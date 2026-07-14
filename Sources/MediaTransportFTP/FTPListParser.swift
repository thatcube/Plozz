import CoreModels
import Foundation
import MediaTransportCore

/// One parsed directory entry from an FTP listing. `size`/`modifiedAt` are
/// best-effort here — the transport re-derives the authoritative size + mtime
/// for a *file* via `SIZE`/`MDTM` at stat/open time, so listing-date parsing
/// quirks never affect the change-detection identity used for playback.
public struct FTPListing: Equatable, Sendable {
    public let name: String
    public let kind: RemoteFileEntryKind
    public let size: Int64?
    public let modifiedAt: Date?

    public init(name: String, kind: RemoteFileEntryKind, size: Int64?, modifiedAt: Date?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Pure parsers for FTP directory listings: machine-readable `MLSD` (RFC 3659,
/// preferred) with fallbacks for the two common `LIST` dialects (Unix `ls -l`
/// and DOS/IIS). Socket-free so every dialect is unit-testable.
public enum FTPListParser {
    // MARK: MLSD (RFC 3659)

    /// Parses an `MLSD` payload: each line is `*(fact ";") SP pathname`.
    /// `cdir`/`pdir` (`.`/`..`) and unknown types are dropped.
    public static func parseMLSD(_ text: String) -> [FTPListing] {
        lines(of: text).compactMap { parseMLSDLine($0) }
    }

    static func parseMLSDLine(_ line: String) -> FTPListing? {
        // Facts contain no spaces; the first space separates facts from the
        // (possibly space-containing) pathname.
        guard let spaceIndex = line.firstIndex(of: " ") else { return nil }
        let factsPart = line[..<spaceIndex]
        let name = String(line[line.index(after: spaceIndex)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var facts: [String: String] = [:]
        for fact in factsPart.split(separator: ";") {
            let pair = fact.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            facts[pair[0].lowercased()] = String(pair[1])
        }

        let type = facts["type"]?.lowercased() ?? ""
        let kind: RemoteFileEntryKind
        switch type {
        case "file":
            kind = .file
        case "dir":
            kind = .directory
        case "cdir", "pdir":
            return nil // current/parent directory markers
        default:
            // e.g. `os.unix=slink:/target` — skip symlinks/devices for scanning.
            return nil
        }

        let size = facts["size"].flatMap { Int64($0) }
        let modifiedAt = facts["modify"].flatMap { parseMLSDTimestamp($0) }
        return FTPListing(
            name: name,
            kind: kind,
            size: kind == .directory ? nil : size,
            modifiedAt: modifiedAt
        )
    }

    /// Parses an RFC 3659 timestamp (`YYYYMMDDHHMMSS` with optional `.sss`),
    /// interpreted as UTC. Shared with `MDTM` responses.
    public static func parseMLSDTimestamp(_ value: String) -> Date? {
        let digits = value.split(separator: ".").first.map(String.init) ?? value
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        var components = DateComponents()
        func intAt(_ start: Int, _ len: Int) -> Int? {
            let s = digits.index(digits.startIndex, offsetBy: start)
            let e = digits.index(s, offsetBy: len)
            return Int(digits[s..<e])
        }
        components.year = intAt(0, 4)
        components.month = intAt(4, 2)
        components.day = intAt(6, 2)
        components.hour = intAt(8, 2)
        components.minute = intAt(10, 2)
        components.second = intAt(12, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    // MARK: LIST fallbacks

    /// Parses a `LIST` payload, auto-detecting Unix `ls -l` vs DOS/IIS format
    /// per line. Dates are best-effort (see ``FTPListing`` doc).
    public static func parseLIST(_ text: String) -> [FTPListing] {
        lines(of: text).compactMap { line in
            parseUnixLine(line) ?? parseDOSLine(line)
        }
    }

    static func parseUnixLine(_ line: String) -> FTPListing? {
        guard let first = line.first, "-dl".contains(first) else { return nil }
        // -rw-r--r-- 1 owner group 1234 Jan 01 12:00 name
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9 else { return nil }
        let kind: RemoteFileEntryKind
        switch first {
        case "d": kind = .directory
        case "l": return nil // symlink — skip for scanning
        default: kind = .file
        }
        // Rejoin the name (index 8 onward), preserving internal spaces.
        let nameFields = fields[8...]
        var name = nameFields.joined(separator: " ")
        if kind == .directory {
            // Defensive: never let `.`/`..` through.
            if name == "." || name == ".." { return nil }
        }
        // A symlink `name -> target` shouldn't appear (we skip `l`), but guard.
        if let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let size = kind == .file ? Int64(fields[4]) : nil
        return FTPListing(name: name, kind: kind, size: size, modifiedAt: nil)
    }

    static func parseDOSLine(_ line: String) -> FTPListing? {
        // 01-01-23  12:00PM       <DIR>          name
        // 01-01-23  12:00PM             1234 name
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        // fields[0] date, fields[1] time, fields[2] <DIR> or size, then name.
        let isDir = fields[2].uppercased() == "<DIR>"
        let size = isDir ? nil : Int64(fields[2])
        guard isDir || size != nil else { return nil }
        let nameStartIndex = 3
        let name = fields[nameStartIndex...].joined(separator: " ")
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return FTPListing(
            name: name,
            kind: isDir ? .directory : .file,
            size: size,
            modifiedAt: nil
        )
    }

    private static func lines(of text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
