import Foundation
import SwiftUI
import CoreModels

/// Spoiler-safe, decision-first text and state for the series episode browser.
/// Hidden episode text is replaced before it reaches accessibility or debug output.
public struct EpisodeColumnPresentation: Equatable, Sendable, CustomDebugStringConvertible {
    public enum ArtworkTreatment: Equatable, Sendable {
        case visible
        case blurred
        case placeholder
    }

    public enum OverviewTreatment: Equatable, Sendable {
        case visible
        case blurred
        case placeholder
        case missing
    }

    public static let hiddenOverviewLabel = "Overview hidden to avoid spoilers"

    /// The title row shown on the card. `Text`, not `String`: the spoiler-hidden
    /// case composes `SpoilerSettings.maskedTitle` (copy) while the normal case
    /// keeps the pre-existing, unmigrated plain-title/"E# ·" composition
    /// verbatim (unchanged behaviour — out of scope for this pass).
    public let titleLine: Text
    /// A plain-string mirror of `titleLine`'s wording, used only by the flat,
    /// already-unlocalized `accessibilityLabel`/`debugDescription` strings below
    /// (pre-existing gap, not part of this pass — computed independently here
    /// rather than by eagerly resolving `titleLine`'s resource, so it can't drift
    /// out of sync with the real (English) wording without both call sites
    /// changing together).
    private let titleLinePlain: String
    public let metadataText: String?
    public let progress: Double?
    public let isWatched: Bool
    public let artworkTreatment: ArtworkTreatment
    public let overviewTreatment: OverviewTreatment
    public let visibleOverview: String?
    public let accessibilityLabel: String
    /// Whether this entry is a not-yet-aired episode, which the card renders dimmed
    /// so it reads as unavailable rather than merely unwatched.
    public let isUpcoming: Bool

    public init(item: MediaItem, spoilerSettings: SpoilerSettings) {
        isUpcoming = item.isUpcomingUnaired
        let hidesText = spoilerSettings.shouldHideText(for: item)
        let hidesArtwork = spoilerSettings.shouldHideThumbnail(for: item)
        let trimmedOverview = item.overview?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        if hidesText {
            titleLine = Text(spoilerSettings.maskedTitle(for: item))
            // Inlined (not a separate `-> String` helper) to match the existing,
            // pre-existing, out-of-scope shape of the non-masked branch below —
            // this mirrors `SpoilerSettings.maskedTitle`'s English wording for
            // `titleLinePlain`'s already-unlocalized accessibility/debug pipeline.
            if let number = item.episodeNumber {
                titleLinePlain = "Episode \(number)"
            } else {
                titleLinePlain = "Episode"
            }
        } else {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain: String
            if let number = item.episodeNumber {
                plain = title.isEmpty ? "Episode \(number)" : "E\(number) · \(title)"
            } else {
                plain = title.isEmpty ? "Episode" : title
            }
            titleLinePlain = plain
            titleLine = Text(verbatim: plain)
        }

        if let runtime = item.cardRuntimeText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !runtime.isEmpty {
            // `cardRuntimeText` is bare ("20m"); this struct is a plain String-based
            // presentation model (not a View), so the "left" suffix is composed
            // here as plain interpolation, matching this file's existing
            // not-yet-localized `String`-based accessibility text below.
            metadataText = item.cardRuntimeIsRemaining ? "\(runtime) left" : runtime
        } else {
            metadataText = nil
        }
        progress = item.resumeProgressFraction
        isWatched = item.isPlayed && progress == nil

        if hidesArtwork {
            artworkTreatment = spoilerSettings.mode == .blur ? .blurred : .placeholder
        } else {
            artworkTreatment = .visible
        }

        if let trimmedOverview {
            if hidesText {
                overviewTreatment = spoilerSettings.mode == .blur ? .blurred : .placeholder
                visibleOverview = nil
            } else {
                overviewTreatment = .visible
                visibleOverview = trimmedOverview
            }
        } else {
            overviewTreatment = .missing
            visibleOverview = nil
        }

        var accessibilityParts = [titleLinePlain]
        if let metadataText { accessibilityParts.append(metadataText) }
        if let progress {
            accessibilityParts.append("\(Int((progress * 100).rounded())) percent watched")
        } else if isWatched {
            accessibilityParts.append("Watched")
        } else {
            accessibilityParts.append("Unwatched")
        }
        switch overviewTreatment {
        case .visible:
            if let visibleOverview { accessibilityParts.append(visibleOverview) }
        case .blurred, .placeholder:
            accessibilityParts.append(Self.hiddenOverviewLabel)
        case .missing:
            break
        }
        accessibilityLabel = accessibilityParts.joined(separator: ", ")
    }

    public var debugDescription: String {   // l10n:content — debug description
        "EpisodeColumnPresentation(titleLine: \(titleLinePlain.debugDescription), metadataText: \(metadataText.debugDescription), progress: \(progress.debugDescription), isWatched: \(isWatched), artworkTreatment: \(artworkTreatment), overviewTreatment: \(overviewTreatment), visibleOverview: \(visibleOverview.debugDescription), accessibilityLabel: \(accessibilityLabel.debugDescription))"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
