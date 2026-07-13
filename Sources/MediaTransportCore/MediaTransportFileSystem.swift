import CoreModels
import Foundation

public enum MediaTransportRangeBehavior: String, Hashable, Sendable {
    case unsupported
    case bounded
    case randomAccess
}

public enum MediaTransportConsistencyBehavior: String, Hashable, Sendable {
    case none
    case changeDetecting
    case representationBound
}

public struct MediaTransportCapabilities: Hashable, Sendable {
    public let supportsList: Bool
    public let supportsStat: Bool
    public let supportsBoundedWholeFileRead: Bool
    public let byteRangeBehavior: MediaTransportRangeBehavior
    public let maximumBoundedWholeFileReadBytes: Int?
    public let consistency: MediaTransportConsistencyBehavior

    public init(
        supportsList: Bool,
        supportsStat: Bool,
        supportsBoundedWholeFileRead: Bool,
        byteRangeBehavior: MediaTransportRangeBehavior,
        maximumBoundedWholeFileReadBytes: Int? = nil,
        consistency: MediaTransportConsistencyBehavior
    ) throws {
        if let maximumBoundedWholeFileReadBytes, maximumBoundedWholeFileReadBytes <= 0 {
            throw MediaTransportError.invalidInput(reason: "bounded read limit must be positive")
        }
        guard supportsBoundedWholeFileRead == (maximumBoundedWholeFileReadBytes != nil) else {
            throw MediaTransportError.invalidInput(reason: "bounded read capability mismatch")
        }
        if byteRangeBehavior != .unsupported, !supportsBoundedWholeFileRead {
            throw MediaTransportError.invalidInput(
                reason: "byte range access requires bounded whole-file reads"
            )
        }
        self.supportsList = supportsList
        self.supportsStat = supportsStat
        self.supportsBoundedWholeFileRead = supportsBoundedWholeFileRead
        self.byteRangeBehavior = byteRangeBehavior
        self.maximumBoundedWholeFileReadBytes = maximumBoundedWholeFileReadBytes
        self.consistency = consistency
    }
}

public struct MediaTransportProbe: Hashable, Sendable {
    public let capabilities: MediaTransportCapabilities
    public let diagnostics: Set<MediaTransportDiagnostic>

    public init(
        capabilities: MediaTransportCapabilities,
        diagnostics: Set<MediaTransportDiagnostic> = []
    ) {
        self.capabilities = capabilities
        self.diagnostics = diagnostics
    }
}

public protocol MediaTransportBrowsing: Sendable {
    func list(relativePath: String) async throws -> [RemoteFileEntry]
    func stat(relativePath: String) async throws -> RemoteFileEntry
}

public protocol MediaTransportFileSystem: MediaTransportBrowsing {
    func validate() async throws
    func probe() async throws -> MediaTransportProbe
    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data
    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease
}
