import Foundation

/// The *kind* of file a viewer picked, rather than the file itself.
///
/// Remembering `MediaVersion.id` works for a movie — you return to the same item
/// and the same files — but is meaningless for a series: every episode's files
/// have their own provider media-source ids, so a remembered id can never match
/// another episode and silently falls back every time.
///
/// Nobody picks a *file* anyway. The picker row reads "Director's Cut · 2160p ·
/// Dolby Vision · Bluray · 65 GB", and choosing it on episode 3 means "play this
/// show like this". This captures that shape so it can be matched against
/// whatever files the next episode happens to have.
public struct MediaVersionDescriptor: Codable, Hashable, Sendable {
    /// The edition/cut, lowercased (e.g. "director's cut"). A CONTENT choice,
    /// which is why it outranks every technical field in ``score(against:)``.
    public var edition: String?
    /// Pixel height, the field people read as "the 4K one".
    public var height: Int?
    /// HDR range token (`DOVI`, `HDR10`, `SDR`, …).
    public var videoRange: String?
    /// Source tier (Bluray, WEB-DL, …), lowercased.
    public var sourceQuality: String?
    /// Video codec token (`av1`, `hevc`, `h264`).
    public var videoCodec: String?
    /// Audio profile (e.g. "Dolby Atmos"), lowercased.
    public var audioProfile: String?

    public init(
        edition: String? = nil,
        height: Int? = nil,
        videoRange: String? = nil,
        sourceQuality: String? = nil,
        videoCodec: String? = nil,
        audioProfile: String? = nil
    ) {
        self.edition = Self.normalized(edition)
        self.height = height
        self.videoRange = Self.normalized(videoRange)
        self.sourceQuality = Self.normalized(sourceQuality)
        self.videoCodec = Self.normalized(videoCodec)
        self.audioProfile = Self.normalized(audioProfile)
    }

    public init(version: MediaVersion) {
        self.init(
            edition: Self.normalized(version.editionLabel),
            height: version.height,
            videoRange: Self.normalized(version.videoRange),
            sourceQuality: Self.normalized(version.sourceQualityLabel),
            videoCodec: Self.normalized(version.videoCodec),
            audioProfile: Self.normalizedAudioProfile(version)
        )
    }

    /// Nothing to match on — every field the viewer might have meant is unknown,
    /// so remembering it would be indistinguishable from remembering nothing.
    public var isEmpty: Bool {
        edition == nil
            && height == nil
            && videoRange == nil
            && sourceQuality == nil
            && videoCodec == nil
            && audioProfile == nil
    }

    /// How well `version` matches what the viewer asked for.
    ///
    /// Weighted by how much each field would upset someone if it were wrong.
    /// Edition dominates: a Theatrical cut standing in for a Director's Cut is
    /// the wrong *content*, which is worse than any resolution mismatch. Height
    /// is scored on proximity rather than equality, so a show whose 2160p run
    /// drops to 1080p for one episode still lands on the best available file
    /// instead of falling back to the server default.
    ///
    /// Unknown fields on either side score zero — absent information is not
    /// evidence of a mismatch.
    public func score(against version: MediaVersion) -> Int {
        evaluation(against: version).score
    }

    fileprivate func evaluation(against version: MediaVersion) -> MatchEvaluation {
        var score = 0
        var technicalScore = 0
        var comparableWeight = 0
        var editionMatched = false
        var editionMismatched = false

        if let edition {
            let candidate = Self.normalized(version.editionLabel)
            if candidate == nil {
                // An unlabelled candidate is unknown, not evidence that it is a
                // different cut. Technical facts may still identify it.
            } else if candidate == edition {
                score += 1000
                editionMatched = true
            } else {
                // An explicit edition that disagrees is disqualifying on its own.
                score -= 1000
                editionMismatched = true
            }
        }

        if let height, let candidateHeight = version.height, height > 0, candidateHeight > 0 {
            // PROPORTIONAL, not absolute. Scored on the ratio of the smaller
            // height to the larger, so "how close is this to what they asked
            // for" means the same thing at every tier: 1440p is a reasonable
            // stand-in for 2160p (0.67), while 480p plainly is not (0.22), and
            // the evidence threshold in `bestMatch` sits between them. An absolute
            // pixel delta can't express that — the same 720px gap separates
            // 2160/1440 and 1080/360.
            let ratio = Double(min(candidateHeight, height)) / Double(max(candidateHeight, height))
            let contribution = Int((400.0 * ratio).rounded())
            score += contribution
            technicalScore += contribution
            comparableWeight += 400
        }

        func compare(_ expected: String?, _ candidate: String?, weight: Int) {
            guard let expected, let candidate else { return }
            comparableWeight += weight
            if candidate == expected {
                score += weight
                technicalScore += weight
            } else {
                // Known disagreement must separate candidates that otherwise tie.
                // Without this, 2160p HDR and 1080p SDR scored equally for a
                // 2160p SDR preference, then the quality tiebreak chose HDR.
                score -= weight
            }
        }

        compare(videoRange, Self.normalized(version.videoRange), weight: 200)
        compare(sourceQuality, Self.normalized(version.sourceQualityLabel), weight: 120)
        compare(videoCodec, Self.normalized(version.videoCodec), weight: 80)
        compare(audioProfile, Self.normalizedAudioProfile(version), weight: 40)

        return MatchEvaluation(
            score: score,
            technicalScore: technicalScore,
            comparableWeight: comparableWeight,
            editionMatched: editionMatched,
            editionMismatched: editionMismatched
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedAudioProfile(_ version: MediaVersion) -> String? {
        if let profile = normalized(version.audioProfile) {
            return profile.contains("atmos") ? "atmos" : profile
        }
        return normalized(version.audioLabel)
    }

    fileprivate struct MatchEvaluation {
        let score: Int
        let technicalScore: Int
        let comparableWeight: Int
        let editionMatched: Bool
        let editionMismatched: Bool

        var isAcceptable: Bool {
            if editionMismatched { return false }
            if editionMatched { return true }
            guard comparableWeight > 0 else { return false }
            // Half the comparable evidence must agree. This accepts a 1080p
            // substitute for a 2160p preference, but not 720p, and lets a lone
            // exact fact such as Atmos carry intent without arbitrary point floors.
            return technicalScore * 2 >= comparableWeight
        }
    }
}

public extension Collection where Element == MediaVersion {
    /// The version best matching a remembered choice, or `nil` when none is close
    /// enough to be what the viewer meant.
    ///
    /// Acceptance uses the proportion of comparable evidence, not an absolute
    /// point floor. That keeps low-weight but exact facts such as Atmos meaningful
    /// while rejecting a candidate that shares only a weak resolution resemblance.
    func bestMatch(for descriptor: MediaVersionDescriptor) -> MediaVersion? {
        guard !descriptor.isEmpty, !isEmpty else { return nil }
        let scored = compactMap { version -> (version: MediaVersion, score: Int)? in
            let evaluation = descriptor.evaluation(against: version)
            guard evaluation.isAcceptable else { return nil }
            return (version, evaluation.score)
        }
        guard let best = scored.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            // Deterministic tiebreak so the same library always resolves the same
            // way: better file first, then a stable id.
            if lhs.version.qualityScore != rhs.version.qualityScore {
                return lhs.version.qualityScore < rhs.version.qualityScore
            }
            return lhs.version.id > rhs.version.id
        }) else { return nil }
        return best.version
    }
}
