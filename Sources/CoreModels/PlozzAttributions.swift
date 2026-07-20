public struct PlozzAttributionLicense: Hashable, Identifiable, Sendable {
    public enum Family: Hashable, Sendable {
        case gpl
        case lgpl
        case mit
        case apache
        case bsd
        case cc0
        case isc
        case ofl
        case api
    }

    public let label: String
    public let family: Family

    public init(_ label: String, family: Family) {
        self.label = label
        self.family = family
    }

    public var id: String { label }
}

public struct PlozzAttribution: Identifiable, Sendable {
    public let title: String
    public let detail: String
    public let licenses: [PlozzAttributionLicense]

    public init(
        title: String,
        detail: String,
        licenses: [PlozzAttributionLicense] = []
    ) {
        self.title = title
        self.detail = detail
        self.licenses = licenses
    }

    public var id: String { title }
}

public enum PlozzAttributions {
    public static let introduction =
        "Plozz is free and open source under the GPL-3.0 license with an App Store "
        + "exception. It is not affiliated with, endorsed, or certified by any of "
        + "the projects or services listed below."

    public static let entries: [PlozzAttribution] = [
        PlozzAttribution(
            title: "Media Servers",
            detail:
                "Jellyfin is a free software media system; Plozz is an unofficial "
                + "client and is not affiliated with the Jellyfin project. Plex is "
                + "a trademark of Plex, Inc.; Plozz is an unofficial client and is "
                + "not endorsed by Plex, Inc."
        ),
        PlozzAttribution(
            title: "Brand Marks",
            detail:
                "The Plex and Jellyfin logos are used nominatively to identify which "
                + "server type an account connects to. They are unmodified and are "
                + "not used as Plozz branding."
        ),
        PlozzAttribution(
            title: "AetherEngine",
            detail:
                "Plozzigen playback is powered by AetherEngine by Vincent Herbst. "
                + "Source: github.com/superuser404notfound/AetherEngine",
            licenses: [.init("LGPL-3.0", family: .lgpl)]
        ),
        PlozzAttribution(
            title: "FFmpeg",
            detail:
                "Audio/video decoding uses FFmpeg libraries (libavcodec, libavformat, "
                + "libavutil, libswresample, libswscale, libavfilter, libavdevice). "
                + "ffmpeg.org",
            licenses: [.init("LGPL-2.1+", family: .lgpl)]
        ),
        PlozzAttribution(
            title: "libdovi",
            detail: "Dolby Vision metadata parsing uses libdovi.",
            licenses: [.init("MIT", family: .mit)]
        ),
        PlozzAttribution(
            title: "libass & Text Rendering",
            detail:
                "Subtitle rendering uses libass, FreeType, HarfBuzz, Fribidi, and "
                + "Unibreak.",
            licenses: [
                .init("ISC", family: .isc),
                .init("LGPL-2.1", family: .lgpl),
                .init("MIT", family: .mit),
            ]
        ),
        PlozzAttribution(
            title: "dav1d",
            detail: "AV1 video decoding uses dav1d by VideoLAN.",
            licenses: [.init("BSD-2", family: .bsd)]
        ),
        PlozzAttribution(
            title: "libplacebo & MoltenVK",
            detail:
                "GPU-accelerated video rendering uses libplacebo and MoltenVK for "
                + "Vulkan-to-Metal translation.",
            licenses: [
                .init("LGPL-2.1", family: .lgpl),
                .init("Apache-2.0", family: .apache),
            ]
        ),
        PlozzAttribution(
            title: "GnuTLS & Networking",
            detail:
                "TLS and network transport use GnuTLS, Nettle, GMP, AMSMB2, and OpenSSL.",
            licenses: [
                .init("LGPL-2.1", family: .lgpl),
                .init("LGPL-3.0", family: .lgpl),
                .init("Apache-2.0", family: .apache),
            ]
        ),
        PlozzAttribution(
            title: "libbluray",
            detail: "Blu-ray disc structure parsing uses libbluray.",
            licenses: [.init("LGPL-2.1", family: .lgpl)]
        ),
        PlozzAttribution(
            title: "TMDB",
            detail:
                "This product uses the TMDB API but is not endorsed or certified by "
                + "TMDB. Artwork and metadata are provided by TMDB (themoviedb.org).",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "TheTVDB",
            detail:
                "Metadata and artwork are provided by TheTVDB. Please consider adding "
                + "missing information or subscribing at thetvdb.com. Plozz uses the "
                + "TheTVDB API but is not endorsed or certified by TheTVDB.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "OMDb & AniList",
            detail:
                "Additional ratings are sourced from the OMDb API (omdbapi.com) and "
                + "AniList (anilist.co). Neither endorses or is affiliated with Plozz.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Watch Tracking",
            detail:
                "Watch-history sync integrations — Trakt (trakt.tv), Simkl (simkl.com), "
                + "AniList (anilist.co), and MyAnimeList (myanimelist.net) — use their "
                + "respective public APIs. None endorses or is affiliated with Plozz.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Wikidata",
            detail:
                "Fallback artwork lookup uses the Wikidata Query Service (wikidata.org).",
            licenses: [.init("CC0", family: .cc0)]
        ),
        PlozzAttribution(
            title: "Fonts",
            detail:
                "The default subtitle typeface is Atkinson Hyperlegible, © 2020 "
                + "Braille Institute of America, Inc., chosen for its legibility from "
                + "a distance. UI accent type uses Bungee by David Jonathan Ross. "
                + "Both are used under the SIL Open Font License 1.1.",
            licenses: [.init("OFL-1.1", family: .ofl)]
        ),
        PlozzAttribution(
            title: "YouTubeKit",
            detail: "Trailer playback uses YouTubeKit by Alexander Eichhorn.",
            licenses: [.init("MIT", family: .mit)]
        ),
    ]
}
