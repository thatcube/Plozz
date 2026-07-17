import CoreModels

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
        preferred: [String?]
    ) -> [PlayerTrackOption] {
        tracks.sortedByPreferredLanguage(preferred).map { track in
            PlayerTrackOption(
                id: track.id,
                title: TrackLabeling.audioLabel(
                    displayTitle: track.displayTitle,
                    language: track.language,
                    codec: track.codec,
                    channels: track.channels,
                    isAtmos: track.isAtmos,
                    isCommentary: track.isCommentary,
                    trackID: track.id
                ),
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
        detectedLanguages: [Int: String]
    ) -> [PlayerTrackOption] {
        guard !tracks.isEmpty else { return [] }
        var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: "Off", isSelected: selectedID == nil)]
        options.append(contentsOf: tracks.sortedByPreferredLanguage(preferred).map { track in
            PlayerTrackOption(
                id: track.id,
                title: subtitleLabel(track, detectedLanguages: detectedLanguages),
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
        detectedLanguages: [Int: String]
    ) -> [PlayerTrackOption] {
        guard !eligible.isEmpty else { return [] }
        var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: "Off", isSelected: selectedID == nil)]
        options.append(contentsOf: eligible.sortedByPreferredLanguage(preferred).map { track in
            PlayerTrackOption(
                id: track.id,
                title: subtitleLabel(track, detectedLanguages: detectedLanguages),
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

    private static func subtitleLabel(_ track: MediaTrack, detectedLanguages: [Int: String]) -> String {
        TrackLabeling.subtitleLabel(
            displayTitle: track.displayTitle,
            language: track.language,
            codec: track.codec,
            isForced: track.isForced,
            isImageBased: track.isImageBasedSubtitle,
            isHearingImpaired: track.isHearingImpaired,
            isCommentary: track.isCommentary,
            detectedLanguage: detectedLanguages[track.id],
            trackID: track.id
        )
    }
}
