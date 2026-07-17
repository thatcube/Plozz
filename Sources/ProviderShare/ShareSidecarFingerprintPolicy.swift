import Foundation

struct ShareSidecarFingerprintEvaluation: Sendable, Equatable {
    var fingerprint: String
    var scanGenerationBound: Bool
}

/// Chooses the strongest transport-neutral identity available for one sidecar.
/// Weak transports still get a diagnostic mtime/size fingerprint, but are
/// explicitly generation-bound so a successful scan rereleases them once.
enum ShareSidecarFingerprintPolicy {
    static func evaluate(
        strongETag: String?,
        changeToken: String?,
        stableFileID: String?,
        modifiedAt: Date,
        size: Int64
    ) -> ShareSidecarFingerprintEvaluation {
        if let strongETag, !strongETag.isEmpty {
            return .init(fingerprint: "etag:\(strongETag)", scanGenerationBound: false)
        }
        if let changeToken, !changeToken.isEmpty {
            return .init(fingerprint: "token:\(changeToken)", scanGenerationBound: false)
        }
        if let stableFileID, !stableFileID.isEmpty {
            return .init(
                fingerprint: "id:\(stableFileID):\(Int(modifiedAt.timeIntervalSince1970)):\(size)",
                scanGenerationBound: false
            )
        }
        return .init(
            fingerprint: "mtime:\(Int(modifiedAt.timeIntervalSince1970)):\(size)",
            scanGenerationBound: true
        )
    }
}
