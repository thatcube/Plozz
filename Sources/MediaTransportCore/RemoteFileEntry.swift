import Foundation

public enum RemoteFileEntryKind: String, Hashable, Sendable {
    case file
    case directory
    case symlink
}

/// Adapter-owned, secret-safe diagnostic identifier. It deliberately carries
/// no free-form server text, URL, header, username, or credential material.
public struct MediaTransportDiagnostic: Hashable, Sendable, CustomStringConvertible {
    public let code: String

    public init(code: String) throws {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !normalized.isEmpty,
              normalized.count <= 64,
              normalized.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MediaTransportError.invalidInput(reason: "invalid diagnostic code")
        }
        self.code = normalized
    }

    public var description: String { code }
}

public struct RemoteFileEntry: Hashable, Sendable {
    public let relativePath: String
    public var name: String { String(relativePath.split(separator: "/").last!) }
    public let kind: RemoteFileEntryKind
    public let size: Int64?
    public let modifiedAt: Date?
    public let createdAt: Date?
    public let stableFileID: String?
    public let strongETag: String?
    public let changeToken: String?
    public let mimeType: String?
    public let diagnostics: Set<MediaTransportDiagnostic>

    public init(
        relativePath: String,
        kind: RemoteFileEntryKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        createdAt: Date? = nil,
        stableFileID: String? = nil,
        strongETag: String? = nil,
        changeToken: String? = nil,
        mimeType: String? = nil,
        diagnostics: Set<MediaTransportDiagnostic> = []
    ) throws {
        self.relativePath = try Self.normalize(relativePath)
        guard size.map({ $0 >= 0 }) ?? true else {
            throw MediaTransportError.invalidInput(reason: "negative file size")
        }
        if kind == .directory, size != nil {
            throw MediaTransportError.invalidInput(reason: "directory size is unsupported")
        }
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.stableFileID = try Self.optionalIdentifier(stableFileID)
        self.strongETag = try Self.strongETag(strongETag)
        self.changeToken = try Self.optionalIdentifier(changeToken)
        self.mimeType = Self.normalizedMIMEType(mimeType)
        self.diagnostics = diagnostics
    }

    private static func normalize(_ value: String) throws -> String {
        let replaced = value.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.hasPrefix("/") else {
            throw MediaTransportError.invalidInput(reason: "path must be relative")
        }
        var components: [String] = []
        for component in replaced.split(separator: "/", omittingEmptySubsequences: true) {
            guard component != ".", component != "..", !component.contains("\0") else {
                throw MediaTransportError.invalidInput(reason: "path traversal")
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "empty relative path")
        }
        return components.joined(separator: "/")
    }

    private static func optionalIdentifier(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), trimmed.count <= 512 else {
            throw MediaTransportError.invalidInput(reason: "invalid identifier")
        }
        return trimmed
    }

    private static func strongETag(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
              !trimmed.lowercased().hasPrefix("w/") else {
            throw MediaTransportError.invalidInput(reason: "ETag is not strong")
        }
        return trimmed
    }

    private static func normalizedMIMEType(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}
