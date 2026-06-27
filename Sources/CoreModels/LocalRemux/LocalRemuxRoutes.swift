import Foundation

/// The URL/path shape for the in-process localhost HLS server.
///
/// Pure, dependency-free routing so both the playlist generator and the HTTP
/// server agree on paths, and so the parsing can be unit-tested. Every running
/// remux session gets a unique session id, keeping concurrent titles isolated:
///
///   * playlist:      `/<session>/index.m3u8`
///   * init segment:  `/<session>/init.mp4`
///   * media segment: `/<session>/seg<index>.m4s`
public enum LocalRemuxRoutes {
    public static let playlistName = "index.m3u8"
    public static let initName = "init.mp4"
    public static let segmentPrefix = "seg"
    public static let segmentExtension = "m4s"

    /// A parsed request path.
    public enum Route: Equatable {
        case playlist(session: String)
        case initSegment(session: String)
        case mediaSegment(session: String, index: Int)
    }

    public static func playlistPath(session: String) -> String {
        "/\(session)/\(playlistName)"
    }

    public static func initPath(session: String) -> String {
        "/\(session)/\(initName)"
    }

    public static func segmentPath(session: String, index: Int) -> String {
        "/\(session)/\(segmentPrefix)\(index).\(segmentExtension)"
    }

    /// The relative URI used inside the playlist for the init segment (resolved
    /// by the player against the playlist URL).
    public static var initSegmentURI: String { initName }

    /// The relative URI used inside the playlist for media segment `index`.
    public static func segmentURI(index: Int) -> String {
        "\(segmentPrefix)\(index).\(segmentExtension)"
    }

    /// Parses a request path (query string ignored) into a `Route`.
    public static func parse(path rawPath: String) -> Route? {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 2 else { return nil }
        let session = components[0]
        guard !session.isEmpty else { return nil }
        let leaf = components[1]

        if leaf == playlistName {
            return .playlist(session: session)
        }
        if leaf == initName {
            return .initSegment(session: session)
        }
        if leaf.hasPrefix(segmentPrefix), leaf.hasSuffix(".\(segmentExtension)") {
            let start = leaf.index(leaf.startIndex, offsetBy: segmentPrefix.count)
            let end = leaf.index(leaf.endIndex, offsetBy: -(segmentExtension.count + 1))
            guard start <= end, let index = Int(leaf[start..<end]) else { return nil }
            return .mediaSegment(session: session, index: index)
        }
        return nil
    }
}
