import Foundation

public extension MediaItem {
    /// Take from `donor` whatever this copy lacks, changing nothing it already has.
    ///
    /// The other half of folding duplicates. ``MediaItemMerger`` decides identity —
    /// which copy is primary, which servers it lives on, the union of its ids — but
    /// deliberately does not reach into presentation. Two descriptions of one title
    /// are rarely complete in the same places: one server has the overview and no
    /// artwork, another the reverse, and a credits provider may have a poster and
    /// nothing else. Showing the first and discarding the rest is how a row ends up
    /// with grey tiles beside copies that had art all along.
    ///
    /// Lived in `HeroCurator` as a private helper, which meant only the hero
    /// benefited; it is a property of merging two `MediaItem`s, so it belongs here
    /// where every fold can use it.
    mutating func fillingMissingPresentation(from donor: MediaItem) {
        if originalTitle?.isEmpty != false { originalTitle = donor.originalTitle }
        if overview?.isEmpty != false { overview = donor.overview }
        if productionYear == nil { productionYear = donor.productionYear }
        if officialRating?.isEmpty != false {
            officialRating = donor.officialRating
        }
        if genres.isEmpty { genres = donor.genres }
        if people.isEmpty { people = donor.people }
        if studios.isEmpty { studios = donor.studios }
        if tags.isEmpty { tags = donor.tags }
        if taglines.isEmpty { taglines = donor.taglines }
        if runtime == nil { runtime = donor.runtime }
        if posterURL == nil { posterURL = donor.posterURL }
        if seriesPosterURL == nil { seriesPosterURL = donor.seriesPosterURL }
        if backdropURL == nil { backdropURL = donor.backdropURL }
        if heroBackdropURL == nil { heroBackdropURL = donor.heroBackdropURL }
        if fallbackArtworkURL == nil {
            fallbackArtworkURL = donor.fallbackArtworkURL
        }
        if logoURL == nil { logoURL = donor.logoURL }
        ratings = ratings.mergedWithAuthoritative(donor.ratings)
        if artworkSelections.isEmpty {
            artworkSelections = donor.artworkSelections
        }
        if availability == nil { availability = donor.availability }
        if downloadProgress == nil { downloadProgress = donor.downloadProgress }
        if mediaInfo == nil { mediaInfo = donor.mediaInfo }
    }
}
