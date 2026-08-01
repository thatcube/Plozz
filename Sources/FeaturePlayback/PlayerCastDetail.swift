#if canImport(SwiftUI)
import Foundation
import CoreModels

/// What the in-player Cast tab can say about one person beyond their face.
///
/// Deliberately a plain value loaded by a closure the app supplies, rather than
/// anything the player resolves itself. Person credits need signed-in accounts,
/// provider sessions and a name-matching ladder across servers — all of which
/// live above `FeaturePlayback`. The player states what it needs and stays
/// ignorant of where it comes from.
public struct PlayerCastDetail: Sendable, Equatable {
    /// Titles in the viewer's OWN library featuring this person, current one
    /// excluded.
    ///
    /// The whole answer to "where else do I know them from", and the reason this
    /// feature needs no third party at all: every entry is a real library item.
    public var credits: [MediaItem]
    /// Who they are, when some source can say. Secondary — at three metres a
    /// viewer reads a couple of lines of this at most, which is why the credits
    /// take the space whenever there are any.
    public var biography: String?
    /// A short factual line — birth year and birthplace — when a source can say.
    ///
    /// Separate from the biography because the two fail independently: a source
    /// routinely knows where someone was born without being able to describe
    /// them, and that line is still worth the space when nothing else lands.
    public var lifeSummary: String?
    /// Whether every source has now answered.
    ///
    /// The difference between "nothing yet" and "nothing at all", which the pane
    /// must not confuse: an empty state shown mid-load tells the viewer there is
    /// nothing about someone who is about to be described.
    public var isComplete: Bool = false

    public init(
        credits: [MediaItem] = [],
        biography: String? = nil,
        lifeSummary: String? = nil,
        isComplete: Bool = false
    ) {
        self.credits = credits
        self.biography = biography
        self.lifeSummary = lifeSummary
        self.isComplete = isComplete
    }

    /// Whether every credit here carries artwork.
    ///
    /// Read by the caller's cache to decide whether an answer is worth replaying.
    /// Artwork arrives from a network pass that can fail transiently, and a
    /// failure that gets remembered is indistinguishable from a title that
    /// genuinely has no poster — except that it never recovers.
    public var artworkIsComplete: Bool {
        credits.allSatisfy { !$0.artworkReferences(for: .poster).isEmpty }
    }

    /// Nothing found. Distinct from "not asked yet", which is `nil` at the call
    /// site — the pane must not show an empty state while a request is in flight.
    public var isEmpty: Bool {
        credits.isEmpty && (biography?.isEmpty ?? true) && (lifeSummary?.isEmpty ?? true)
    }
}

/// Supplied by the app when it builds a player. `nil` simply means the pane
/// shows a name and a face, which is what it did before any of this existed.
///
/// A STREAM, not a single value. The answer is assembled from several sources
/// in sequence — the person's own server, then any other signed-in servers,
/// then a keyless biography lookup — and awaiting one final result made the
/// pane wait for the slowest of them before showing anything at all. The
/// viewer's own server usually answers in milliseconds; a Wikipedia round trip
/// does not, and it was holding the credits hostage.
public typealias PlayerCastDetailLoading =
    @MainActor @Sendable (MediaPerson) -> AsyncStream<PlayerCastDetail>
#endif
