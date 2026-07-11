import Foundation
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

    public let titleLine: String
    public let metadataText: String?
    public let progress: Double?
    public let isWatched: Bool
    public let artworkTreatment: ArtworkTreatment
    public let overviewTreatment: OverviewTreatment
    public let visibleOverview: String?
    public let accessibilityLabel: String

    public init(item: MediaItem, spoilerSettings: SpoilerSettings) {
        let hidesText = spoilerSettings.shouldHideText(for: item)
        let hidesArtwork = spoilerSettings.shouldHideThumbnail(for: item)
        let trimmedOverview = item.overview?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        if hidesText {
            titleLine = spoilerSettings.maskedTitle(for: item)
        } else {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = item.episodeNumber {
                titleLine = title.isEmpty ? "Episode \(number)" : "E\(number) · \(title)"
            } else {
                titleLine = title.isEmpty ? "Episode" : title
            }
        }

        metadataText = item.cardRuntimeText
        progress = item.resumeProgressFraction
        isWatched = item.isPlayed && progress == nil

        if hidesArtwork {
            artworkTreatment = spoilerSettings.mode == .blur ? .blurred : .placeholder
        } else {
            artworkTreatment = .visible
        }

        if hidesText {
            overviewTreatment = spoilerSettings.mode == .blur ? .blurred : .placeholder
            visibleOverview = nil
        } else if let trimmedOverview {
            overviewTreatment = .visible
            visibleOverview = trimmedOverview
        } else {
            overviewTreatment = .missing
            visibleOverview = nil
        }

        var accessibilityParts = [titleLine]
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

    public var debugDescription: String {
        "EpisodeColumnPresentation(titleLine: \(titleLine.debugDescription), metadataText: \(metadataText.debugDescription), progress: \(progress.debugDescription), isWatched: \(isWatched), artworkTreatment: \(artworkTreatment), overviewTreatment: \(overviewTreatment), visibleOverview: \(visibleOverview.debugDescription), accessibilityLabel: \(accessibilityLabel.debugDescription))"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
