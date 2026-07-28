import CoreModels
import SwiftUI

/// Pure construction of the audio / subtitle / secondary-subtitle picker menus
/// shown in `PlayerControls`, plus the small selection/eligibility decisions
/// that feed them.
///
/// This is deliberately a value-only, side-effect-free collaborator: given the
/// engine's demuxed tracks, the provider's probe, the current selection, and the
/// viewer's preferred languages, it returns the `PlayerTrackOption` arrays and
/// the derived facts (which audio id is selected, which tracks are eligible as a
/// second subtitle line, whether the primary is an un-positionable bitmap). The
/// `PlayerViewModel` keeps ownership of the mutable state and all engine/overlay
/// side effects; it simply asks this builder what the menus should contain. That
/// split makes the fiddly labelling/sort/pinning rules directly unit-testable
/// without standing up an engine.
enum TrackMenuBuilder {

    /// The "selected audio" indicator must reflect the track the engine is
    /// *actually* decoding, not a re-derived default-flag guess (those can
    /// disagree: e.g. a dual-audio anime whose container defaults to Japanese
    /// while the engine starts English per the viewer's preference). Priority:
    /// an in-flight pick (optimistic) → the engine's resolved active track
    /// (ground truth) → the default-flag heuristic only before either is known.
    ///
    /// Returns the id to mark selected and whether the caller should clear its
    /// `pendingAudioTrackID` (an optimistic pick is only cleared once the engine
    /// confirms it, or when we fall through to the engine's own active track).
    static func resolveSelectedAudioTrackID(
        current: Int?,
        pending: Int?,
        engineActive: Int?,
        tracks: [MediaTrack]
    ) -> (selected: Int?, clearPending: Bool) {
        if let pending, tracks.contains(where: { $0.id == pending }) {
            return (pending, engineActive == pending)
        }
        if let active = engineActive, tracks.contains(where: { $0.id == active }) {
            return (active, true)
        }
        if current == nil {
            return (tracks.first(where: { $0.isDefault })?.id ?? tracks.first?.id, false)
        }
        return (current, false)
    }

    /// Audio picker rows, preferred-language-first.
    static func audioOptions(
        tracks: [MediaTrack],
        selectedID: Int?,
        preferred: [String?],
        locale: Locale = .current
    ) -> [PlayerTrackOption] {
        tracks.sortedByPreferredLanguage(preferred).map { track in
            PlayerTrackOption(
                id: track.id,
                title: text(for: TrackLabeling.audioLabel(
                    displayTitle: track.displayTitle,
                    language: track.language,
                    codec: track.codec,
                    channels: track.channels,
                    isAtmos: track.isAtmos,
                    isCommentary: track.isCommentary,
                    trackID: track.id,
                    locale: locale
                )),
                isSelected: track.id == selectedID
            )
        }
    }

    /// Primary subtitle picker rows: "Off" pinned first, real tracks
    /// preferred-language-first. An empty track list yields an empty menu (no
    /// bare "Off" row).
    static func subtitleOptions(
        tracks: [MediaTrack],
        selectedID: Int?,
        preferred: [String?],
        detectedLanguages: [Int: String],
        locale: Locale = .current
    ) -> [PlayerTrackOption] {
        guard !tracks.isEmpty else { return [] }
        var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: Text(LocalizedStringResource(
        "subtitlePicker.option.off",
        defaultValue: "Off",
        comment: "The row in the subtitle track picker that shows no subtitles. Sits in a list of track names, not next to a switch, so it may need to agree with 'subtitles' rather than read as a generic on/off state."
    )), isSelected: selectedID == nil)]
        options.append(contentsOf: tracks.sortedByPreferredLanguage(preferred).map { track in
            PlayerTrackOption(
                id: track.id,
                title: subtitleLabel(track, detectedLanguages: detectedLanguages, locale: locale),
                isSelected: track.id == selectedID,
                isExternal: track.isExternal
            )
        })
        return options
    }

    /// Second-line (dual) subtitle picker rows: "Off" pinned first, eligible
    /// tracks preferred-language-first. No `isExternal` flag — the secondary line
    /// always renders through Plozz's overlay.
    static func secondaryOptions(
        eligible: [MediaTrack],
        selectedID: Int?,
        preferred: [String?],
        detectedLanguages: [Int: String],
        locale: Locale = .current
    ) -> [PlayerTrackOption] {
        guard !eligible.isEmpty else { return [] }
        var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: Text(LocalizedStringResource(
        "subtitlePicker.option.off",
        defaultValue: "Off",
        comment: "The row in the subtitle track picker that shows no subtitles. Sits in a list of track names, not next to a switch, so it may need to agree with 'subtitles' rather than read as a generic on/off state."
    )), isSelected: selectedID == nil)]
        options.append(contentsOf: eligible.sortedByPreferredLanguage(preferred).map { track in
            PlayerTrackOption(
                id: track.id,
                title: subtitleLabel(track, detectedLanguages: detectedLanguages, locale: locale),
                isSelected: track.id == selectedID
            )
        })
        return options
    }

    /// The tracks a second subtitle line can show.
    ///
    /// Sourced from the PROVIDER's subtitle probe for the sidecar (native) path
    /// and from the ENGINE's own tracks when the engine decodes a second stream
    /// itself (`.dualSubtitleDecode`, e.g. Plozzigen). Bitmap (PGS/DVD/DVB/VOBSUB)
    /// tracks are **never** eligible as a second line (a bitmap cue is drawn at
    /// its own authored position we can't move), and when the **primary** itself
    /// is a bitmap subtitle, dual mode is disabled entirely (no eligible seconds).
    static func eligibleSecondaryTracks(
        selectedPrimaryID: Int?,
        engineTracks: [MediaTrack],
        providerTracks: [MediaTrack],
        engineSupportsDualDecode: Bool
    ) -> [MediaTrack] {
        if bitmapPrimary(selectedPrimaryID: selectedPrimaryID, engineTracks: engineTracks, providerTracks: providerTracks) != nil {
            return []
        }
        // Engine-dual: source from the engine's own tracks (embedded tracks with
        // no fetchable sidecar are selectable — the engine demuxes them).
        if engineSupportsDualDecode {
            return engineTracks.filter { $0.id != selectedPrimaryID && !$0.isBitmapSubtitle }
        }
        // Sidecar (native): only text tracks with a fetchable URL, excluding the
        // primary. (`isBitmapSubtitle` is redundant with the URL requirement here
        // but kept for symmetry / defence in depth.)
        return providerTracks.filter {
            !$0.isBitmapSubtitle && $0.deliverySource != nil && $0.id != selectedPrimaryID
        }
    }

    /// A short format hint ("PGS", "VOBSUB", "Image", …) when the current primary
    /// subtitle is a bitmap track — used to explain why the dual picker is empty
    /// ("Unavailable with PGS subtitles") rather than "None available". `nil` when
    /// the primary is off or a text track.
    static func imagePrimaryFormat(
        selectedPrimaryID: Int?,
        engineTracks: [MediaTrack],
        providerTracks: [MediaTrack]
    ) -> String? {
        guard let primary = bitmapPrimary(
            selectedPrimaryID: selectedPrimaryID,
            engineTracks: engineTracks,
            providerTracks: providerTracks
        ) else { return nil }
        return TrackLabeling.subtitleFormatHint(codec: primary.codec, isImageBased: true) ?? "Image"
    }

    // MARK: - Private

    private static func bitmapPrimary(
        selectedPrimaryID: Int?,
        engineTracks: [MediaTrack],
        providerTracks: [MediaTrack]
    ) -> MediaTrack? {
        guard let primaryID = selectedPrimaryID,
              let primary = engineTracks.first(where: { $0.id == primaryID })
                ?? providerTracks.first(where: { $0.id == primaryID }),
              primary.isBitmapSubtitle
        else { return nil }
        return primary
    }

    private static func subtitleLabel(_ track: MediaTrack, detectedLanguages: [Int: String],
                                      locale: Locale) -> Text {
        text(for: TrackLabeling.subtitleLabel(
            displayTitle: track.displayTitle,
            language: track.language,
            codec: track.codec,
            isForced: track.isForced,
            isImageBased: track.isImageBasedSubtitle,
            isHearingImpaired: track.isHearingImpaired,
            isCommentary: track.isCommentary,
            detectedLanguage: detectedLanguages[track.id],
            trackID: track.id,
            locale: locale
        ))
    }

    /// Composes a structured ``TrackLabel`` (base + qualifiers) into the final
    /// menu-row `Text`: base, then `" ("`, the qualifiers joined with `", "`,
    /// then `")"`. The separators are punctuation, not copy, so they're kept
    /// verbatim; each qualifier is resolved to either a real localized `Text`
    /// (Plozz's own words) or `Text(verbatim:)` (content — a codec/format
    /// token). `base`/qualifiers are never joined into a plain `String` first,
    /// which is exactly what would hide the copy from the catalog.
    private static func text(for label: TrackLabel) -> Text {
        let base: Text
        switch label.base {
        case .content(let value):
            base = Text(verbatim: value)
        case .trackNumber(let number):
            base = Text(
                "Track \(number)",
                comment: "Fallback label for an audio/subtitle track with no resolved language or meaningful provider title, showing its index."
            )
        }
        guard !label.qualifiers.isEmpty else { return base }
        let qualifierTexts = label.qualifiers.map(qualifierText)
        let joined = qualifierTexts.dropFirst().reduce(qualifierTexts[0]) { accumulated, next in
            accumulated + Text(verbatim: ", ") + next
        }
        return base + Text(verbatim: " (") + joined + Text(verbatim: ")")
    }

    private static func qualifierText(_ qualifier: TrackLabel.Qualifier) -> Text {
        switch qualifier {
        case .forced:
            return Text("Forced", comment: "Subtitle track qualifier — the track only shows forced (foreign-language-passage) lines.")
        case .hearingImpaired:
            return Text("SDH", comment: "Subtitle/audio track qualifier for a hearing-impaired (SDH) track.")
        case .commentary:
            return Text("Commentary", comment: "Audio/subtitle track qualifier for a commentary track.")
        case .autoDetected:
            return Text("auto", comment: "Subtitle track qualifier appended when the shown language was guessed from the file's content rather than tagged by the provider.")
        case .format(let value):
            return Text(verbatim: value)
        case .channelCount(let channels):
            return Text(
                "\(channels) channels",
                comment: "Fallback wording for an audio track's channel count when it doesn't match a named layout convention (e.g. Stereo, 5.1, 7.1)."
            )
        }
    }
}
